-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE GENERAL FRAME: a chain no rule writes into fires once per match,
||| whatever the other rules do with their actions. The clocked-network
||| programme's part B'; the frame Rete/NetworkEdges.idr and Rete/NetworkOnce.idr name as
||| what they lack.
|||
||| NORMATIVE COMPANION to Rete/NetworkOnce.idr, which it stands on.
|||
||| WHY. B0, B1 and the once-per-match theorem take an ACTION-FREE program,
||| every rule's action list empty, so that a step is the marking of one
||| activation and nothing else. A real RHS emits and withdraws, and an
||| emit of a kind some chain's alpha admits makes or ends that chain's
||| matches in the middle of a pump. The honest frame is per chain, not per
||| program: a chain is FRAMED when no rule of the program writes a kind the
||| chain's nodes read -- an emit's kind, or the positive kind at a
||| withdrawn position. Under it every firing but the chain's own leaves the
||| chain as it was, and its own firing only marks the activation selected.
||| The framed chain may itself emit and withdraw, as long as it writes
||| other kinds.
|||
||| PROVED.
|||
|||   * THE PATHS SKIP A CHAIN THEIR ALPHA DOES NOT FEED: right-activation
|||     and right-retraction leave every node not on the fed alpha, so a
|||     chain with no node on it is unchanged (`iret_7_7__right_activate_frame`,
|||     `_retract_frame`, `_activate_chain_frame`, `_retract_chain_frame`).
|||   * DISPATCH SKIPS A CHAIN WHOSE ALPHAS ADMIT NONE OF THE FACT
|||     (`iret_6_4__dispatch_assert_frame`, `iret_19_2__dispatch_retract_frame`):
|||     whichever alphas take the fact, the chain has no node on them, and
|||     the alphas' memory updates keep what they admit (`iret_6_4__admits_same`).
|||   * EVERY WORKING-MEMORY OPERATION SKIPS A CHAIN THAT DOES NOT READ THE
|||     FACT'S KIND: insert, retract, assert under any lifecycle, withdraw
|||     (`iret_19_1__insert_frame` .. `lscp_2_1_1__withdraw_frame`).
|||   * THE SHAPES ARE KEPT (`Rlow_4_2_1__shapes_kept`): against the loaded
|||     network, every operation keeps the alphas' schemas and tests, and
|||     every chain's node alphas, negation flags and actions, so a rule's
|||     positive kinds and writes are those it was loaded with. The nodes'
|||     join tests are not compared (`Rlow_4_2_1__same_kinds`): the frame
|||     reads none of them, and a re-timed node keeps its alpha and its flag
|||     while its test changes, which is what lets the frame hold across a
|||     tick that re-times (Rete/NetworkFrameRetime.idr).
|||   * A FIRED MATCH HAS ITS RULE'S KINDS (`rlow_5_1__bound_kinds`): under
|||     the view, the fact at position j of an activation has the chain's
|||     j-th positive kind -- what makes a withdraw's kind known.
|||   * ONE FIRING UNDER THE FRAME (`ltim_2_5_1__step_frame`): the invariant
|||     is kept, and the framed chain is as it was unless it is the rule that
|||     fired, when exactly the activation selected, unfired before, is marked.
|||   * THE RUN UNDER THE FRAME (`ltim_2_5_1__run_frame`), on the traced plain
|||     run (`iret_11_4__run_net_traced`, the plain network's form of
|||     Rete/NetworkTraced.idr's): over any fuel, a framed chain's tuples
|||     never change, its firings in the trace are exactly the activations
|||     that went from unfired to fired, and if the run halts `Quiescent`
|||     every one of them fired. Fuel is not assumed to suffice: the other
|||     rules may loop, and the theorem says what the framed chain did
|||     whatever the halt.
|||   * THE THEOREM (`iret_11_3__framed_fires_once_per_match`): from the
|||     loaded network, after any inputs with no pump between them, a pump
|||     that reaches quiescence fires a framed chain exactly once per match
|||     it held when the pump began -- the once-per-match of
|||     Rete/NetworkOnce.idr with the action-free frame replaced by this one.
|||   * EXECUTED: two rules, A reading kind 0 and emitting kind 1, B reading
|||     kind 1, emitting kind 2 and withdrawing its own fact. A is framed
|||     (`Refl`), B is not (`Refl`: A writes what B reads). Two kind-0 facts,
|||     one pump: the trace is `[0, 0, 1, 1]`, A fires twice for its two
|||     matches while B fires, emits and withdraws between (`ltim_2_5_1__two_rules_trace`),
|||     and the theorem applied at the fixture discharges every hypothesis
|||     by computation (`ltim_2_5_1__two_rules_is_an_instance`).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. The plain network: no
||| dependency table and no clock, so no cascade retracts a logical fact
||| and no sweep expires one; lifting the frame to the clocked engine of
||| Rete/NetworkEdges.idr needs that a cascade's targets are emitted kinds,
||| a later step. The frame is syntactic over the loaded program and the
||| alphas' schemas; a rule whose emit's kind depends on its match is not a
||| DS rule (an emit names its schema). Inputs are not framed: an input of
||| a kind the chain reads is how it gets its matches, and the theorem is
||| about the pump after them, as Rete/NetworkOnce.idr's is.
module Rete.NetworkFrame

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkDispatch
import Rete.NetworkAgree
import Rete.NetworkOrder
import Rete.NetworkOrderKeep
import Rete.NetworkRefraction
import Rete.NetworkTransferAgree
import Rete.NetworkTransfer
import Rete.NetworkEdges
import Rete.NetworkOnce
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Rete.RunFold
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Termination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The frame: what a chain reads, what a rule writes
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
--@spec [IRET.6.1]
||| THE KINDS A CHAIN READS: the schema of each node's alpha, positive and
||| NOT nodes alike. The dangling node's schema is 0, of which it admits
||| nothing.
public export
ltim_2_5_1__reads : List Iret_6_1__alpha -> List Iret_7_4__beta -> List Nat
ltim_2_5_1__reads alphas nodes = map (\b => akind (iret_6_6__alpha_at alphas (balpha b))) nodes

--@spec [LTIM.2.5.1]
||| A kind, or none, in front of a list.
public export
ltim_2_5_1__kind_or : Maybe Nat -> List Nat -> List Nat
ltim_2_5_1__kind_or Nothing rest = rest
ltim_2_5_1__kind_or (Just k) rest = k :: rest

--@spec [LTIM.2.5.1]
--@spec [RARC.5.6.7]
||| THE KINDS A RULE WRITES, from its positive kinds and its actions: an
||| emit's kind; a withdraw's, the positive kind at the withdrawn position.
public export
ltim_2_5_1__writes_of : List Nat -> List Lgra_10_1__action -> List Nat
ltim_2_5_1__writes_of pos [] = []
ltim_2_5_1__writes_of pos (Emit k v :: as) = k :: ltim_2_5_1__writes_of pos as
ltim_2_5_1__writes_of pos (Withdraw i :: as) = ltim_2_5_1__kind_or (rarc_5_6_5__nth i pos) (ltim_2_5_1__writes_of pos as)

--@spec [LTIM.2.5.1]
public export
ltim_2_5_1__writes : List Iret_6_1__alpha -> Rlow_4_2_1__chain -> List Nat
ltim_2_5_1__writes alphas r = ltim_2_5_1__writes_of (rlow_5_1__pos_kinds alphas (cnodes r)) (cactions r)

--@spec [LTIM.2.5.1]
||| A RULE WRITES INTO A CHAIN when some kind it writes is one the chain's
||| nodes read.
public export
ltim_2_5_1__writes_into : List Iret_6_1__alpha -> List Iret_7_4__beta -> Rlow_4_2_1__chain -> Bool
ltim_2_5_1__writes_into alphas nodes r = rarc_5_6_5__any (\k => rarc_5_6_5__elem k (ltim_2_5_1__reads alphas nodes)) (ltim_2_5_1__writes alphas r)

--@spec [LTIM.2.5.1]
||| FRAMED: no rule of the program writes into the chain. A Bool, so that a
||| witness checks it by computation.
public export
ltim_2_5_1__framed : List Iret_6_1__alpha -> List Rlow_4_2_1__chain -> List Iret_7_4__beta -> Bool
ltim_2_5_1__framed alphas chains nodes = not (rarc_5_6_5__any (ltim_2_5_1__writes_into alphas nodes) chains)

-- ---------------------------------------------------------------------
-- Small lemmas
-- ---------------------------------------------------------------------

--@derives [LTIM.2.5.1]
||| A kind in front of a list, or not: a member of the list is a member.
export
ltim_2_5_1__kind_or_elem : (m : Maybe Nat) -> (rest : List Nat) -> (k : Nat) -> Elem k rest -> Elem k (ltim_2_5_1__kind_or m rest)
ltim_2_5_1__kind_or_elem Nothing rest k e = e
ltim_2_5_1__kind_or_elem (Just k') rest k e = There e

--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.7]
||| An emit's kind is among the rule's writes.
export
ltim_2_5_1__writes_emit : (pos : List Nat) -> (as : List Lgra_10_1__action) -> (k : Nat) -> (v : List Lfac_1_7_1__fact -> (Nat, Nat)) ->
                          Elem (Emit k v) as -> Elem k (ltim_2_5_1__writes_of pos as)
ltim_2_5_1__writes_emit pos (Emit _ _ :: as) k v Here = Here
ltim_2_5_1__writes_emit pos (Emit k' v' :: as) k v (There e) = There (ltim_2_5_1__writes_emit pos as k v e)
ltim_2_5_1__writes_emit pos (Withdraw i :: as) k v (There e) = ltim_2_5_1__kind_or_elem (rarc_5_6_5__nth i pos) _ k (ltim_2_5_1__writes_emit pos as k v e)

--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.7]
||| A withdraw's kind, the positive kind at its position, is among the
||| rule's writes.
export
ltim_2_5_1__writes_withdraw : (pos : List Nat) -> (as : List Lgra_10_1__action) -> (i, k : Nat) ->
                              Elem (Withdraw i) as -> rarc_5_6_5__nth i pos = Just k -> Elem k (ltim_2_5_1__writes_of pos as)
ltim_2_5_1__writes_withdraw pos (Withdraw _ :: as) i k Here nk =
  replace {p = \m => Elem k (ltim_2_5_1__kind_or m (ltim_2_5_1__writes_of pos as))} (sym nk) Here
ltim_2_5_1__writes_withdraw pos (Emit k' v :: as) i k (There e) nk = There (ltim_2_5_1__writes_withdraw pos as i k e nk)
ltim_2_5_1__writes_withdraw pos (Withdraw i' :: as) i k (There e) nk = ltim_2_5_1__kind_or_elem (rarc_5_6_5__nth i' pos) _ k (ltim_2_5_1__writes_withdraw pos as i k e nk)

--@derives [LTIM.2.5.1]
||| Under the frame, no kind a rule of the program writes is one the chain
||| reads.
export
ltim_2_5_1__framed_rule : (alphas : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) -> (nodes : List Iret_7_4__beta) -> (r : Rlow_4_2_1__chain) ->
                          ltim_2_5_1__framed alphas chains nodes = True -> Elem r chains ->
                          (k : Nat) -> Elem k (ltim_2_5_1__writes alphas r) -> rarc_5_6_5__elem k (ltim_2_5_1__reads alphas nodes) = False
ltim_2_5_1__framed_rule alphas chains nodes r fr er k ek =
  let noneRule = lcyc_1_1__any_false_all (ltim_2_5_1__writes_into alphas nodes) chains (lcyc_1_1__not_true_is_false _ fr)
      wr = the (ltim_2_5_1__writes_into alphas nodes r = False) (lcyc_1_1__all_lookup noneRule er)
      noneK = lcyc_1_1__any_false_all (\k' => rarc_5_6_5__elem k' (ltim_2_5_1__reads alphas nodes)) (ltim_2_5_1__writes alphas r) wr
  in lcyc_1_1__all_lookup noneK ek

--@derives [LTIM.2.5.1]
--@derives [IRET.6.1]
||| Alphas of one shape read alike.
export
ltim_2_5_1__reads_same : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' -> (nodes : List Iret_7_4__beta) ->
                         ltim_2_5_1__reads alphas' nodes = ltim_2_5_1__reads alphas nodes
ltim_2_5_1__reads_same alphas alphas' sa nodes =
  ldet_5_5__map_all (\b => akind (iret_6_6__alpha_at alphas' (balpha b))) (\b => akind (iret_6_6__alpha_at alphas (balpha b))) nodes
    (lcyc_1_1__all_from_elem nodes (\b, _ => fst (sa (balpha b))))

--@derives [IRET.6.4]
||| A fact of a kind the chain does not read is admitted by none of its
||| nodes' alphas.
export
iret_6_4__reads_admit : (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (f : Lfac_1_7_1__fact) ->
                        rarc_5_6_5__elem (fkind f) (ltim_2_5_1__reads alphas nodes) = False ->
                        All (\b => iret_6_4__admits (iret_6_6__alpha_at alphas (balpha b)) f = False) nodes
iret_6_4__reads_admit alphas nodes f nr =
  lcyc_1_1__all_from_elem nodes (\b, eb =>
    let neq = the ((fkind f == akind (iret_6_6__alpha_at alphas (balpha b))) = False)
                (lcyc_1_1__nat_eq_false _ _ (\eq =>
                   lcyc_1_1__elem_l_false_not (fkind f) (ltim_2_5_1__reads alphas nodes) nr
                     (replace {p = \z => Elem z (ltim_2_5_1__reads alphas nodes)} (sym eq)
                        (lcyc_1_1__elem_map_fwd (\b' => akind (iret_6_6__alpha_at alphas (balpha b'))) eb))))
    in replace {p = \z => (z && atest (iret_6_6__alpha_at alphas (balpha b)) f) = False} (sym neq) Refl)

--@derives [IRET.6.4]
||| A chain none of whose nodes' alphas admit the fact has no node on an
||| alpha that does.
export
iret_6_4__frame_alpha : (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) -> (nodes : List Iret_7_4__beta) ->
                        All (\b => iret_6_4__admits (iret_6_6__alpha_at alphas (balpha b)) f = False) nodes ->
                        iret_6_4__admits (iret_6_6__alpha_at alphas a) f = True -> All (\b => (balpha b == a) = False) nodes
iret_6_4__frame_alpha alphas a f [] [] adm = []
iret_6_4__frame_alpha alphas a f (b :: bs) (p :: ps) adm =
  lcyc_1_1__nat_eq_false (balpha b) a (\eq =>
    lcyc_1_1__bool_not_both _ (replace {p = \z => iret_6_4__admits (iret_6_6__alpha_at alphas z) f = True} (sym eq) adm) p)
  :: iret_6_4__frame_alpha alphas a f bs ps adm

-- ---------------------------------------------------------------------
-- The paths skip a chain their alpha does not feed
-- ---------------------------------------------------------------------

--@derives [IRET.7.7]
||| RIGHT-ACTIVATION leaves every node not on the fed alpha: a chain with
||| no node on it is as it was, memories and activations alike.
export
iret_7_7__right_activate_frame : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) ->
                                 (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                 All (\b => (balpha b == a) = False) nodes ->
                                 iret_7_7__right_activate wm alphas a f nodes acts = (nodes, acts)
iret_7_7__right_activate_frame wm alphas a f [] acts [] = Refl
iret_7_7__right_activate_frame wm alphas a f (b :: rest) acts (p :: ps) with (balpha b == a)
  iret_7_7__right_activate_frame wm alphas a f (b :: rest) acts (p :: ps) | True = absurd p
  iret_7_7__right_activate_frame wm alphas a f (b :: rest) acts (p :: ps) | False =
    cong (\q => (b :: fst q, snd q)) (iret_7_7__right_activate_frame wm alphas a f rest acts ps)

--@derives [IRET.7.7]
||| RIGHT-RETRACTION leaves every node not on the fed alpha.
export
iret_7_7__right_retract_frame : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) ->
                                (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                All (\b => (balpha b == a) = False) nodes ->
                                iret_7_7__right_retract wm alphas a f nodes acts = (nodes, acts)
iret_7_7__right_retract_frame wm alphas a f [] acts [] = Refl
iret_7_7__right_retract_frame wm alphas a f (b :: rest) acts (p :: ps) with (balpha b == a)
  iret_7_7__right_retract_frame wm alphas a f (b :: rest) acts (p :: ps) | True = absurd p
  iret_7_7__right_retract_frame wm alphas a f (b :: rest) acts (p :: ps) | False =
    cong (\q => (b :: fst q, snd q)) (iret_7_7__right_retract_frame wm alphas a f rest acts ps)

--@derives [IRET.7.7]
export
iret_7_7__activate_chain_frame : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) -> (c : Rlow_4_2_1__chain) ->
                                 All (\b => (balpha b == a) = False) (cnodes c) -> iret_7_7__activate_chain wm alphas a f c = c
iret_7_7__activate_chain_frame wm alphas a f (MkChain nodes acts actions) ps =
  cong (\q => MkChain (fst q) (snd q) actions) (iret_7_7__right_activate_frame wm alphas a f nodes acts ps)

--@derives [IRET.7.7]
export
iret_7_7__retract_chain_frame : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) -> (c : Rlow_4_2_1__chain) ->
                                All (\b => (balpha b == a) = False) (cnodes c) -> iret_7_7__retract_chain wm alphas a f c = c
iret_7_7__retract_chain_frame wm alphas a f (MkChain nodes acts actions) ps =
  cong (\q => MkChain (fst q) (snd q) actions) (iret_7_7__right_retract_frame wm alphas a f nodes acts ps)

-- ---------------------------------------------------------------------
-- Dispatch skips a chain whose alphas admit none of the fact
-- ---------------------------------------------------------------------

--@derives [IRET.6.4]
--@derives [IRET.1.7]
||| ALPHA DISPATCH ON ASSERT leaves a chain none of whose nodes' alphas
||| admit the fact: whichever alphas take it, the chain has no node on
||| them, and the memory updates keep what each alpha admits.
export
iret_6_4__dispatch_assert_frame : (wm' : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (is : List Nat) -> (net : Rarc_5_3_1__network) -> (i : Nat) -> (c : Rlow_4_2_1__chain) ->
                                  rarc_5_6_5__nth i (nchains net) = Just c ->
                                  All (\b => iret_6_4__admits (iret_6_6__alpha_at (nalphas net) (balpha b)) f = False) (cnodes c) ->
                                  rarc_5_6_5__nth i (nchains (iret_6_4__dispatch_assert wm' f is net)) = Just c
iret_6_4__dispatch_assert_frame wm' f [] net i c n fr = n
iret_6_4__dispatch_assert_frame wm' f (k :: is) (MkNetwork alphas chains) i c n fr with (iret_6_4__admits (iret_6_6__alpha_at alphas k) f) proof adm
  iret_6_4__dispatch_assert_frame wm' f (k :: is) (MkNetwork alphas chains) i c n fr | False =
    iret_6_4__dispatch_assert_frame wm' f is (MkNetwork alphas chains) i c n fr
  iret_6_4__dispatch_assert_frame wm' f (k :: is) (MkNetwork alphas chains) i c n fr | True =
    iret_6_4__dispatch_assert_frame wm' f is
      (MkNetwork (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) (map (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f) chains)) i c
      (trans (lcyc_1_1__nth_map (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f) i chains)
             (trans (cong (map (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f)) n)
                    (cong Just (iret_7_7__activate_chain_frame wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f c
                                  (iret_6_4__frame_alpha alphas k f (cnodes c) fr adm)))))
      (lcyc_1_1__all_from_elem (cnodes c) (\b, eb =>
         trans (iret_6_4__admits_same alphas (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) (iret_6_5__insert_same_alphas k f alphas) (balpha b) f)
               (lcyc_1_1__all_lookup fr eb)))

--@derives [IRET.19.2]
--@derives [IRET.1.7]
||| ALPHA DISPATCH ON RETRACT leaves a chain none of whose nodes' alphas
||| admit the fact.
export
iret_19_2__dispatch_retract_frame : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (is : List Nat) -> (net : Rarc_5_3_1__network) -> (i : Nat) -> (c : Rlow_4_2_1__chain) ->
                                    rarc_5_6_5__nth i (nchains net) = Just c ->
                                    All (\b => iret_6_4__admits (iret_6_6__alpha_at (nalphas net) (balpha b)) f = False) (cnodes c) ->
                                    rarc_5_6_5__nth i (nchains (iret_19_2__dispatch_retract wm f is net)) = Just c
iret_19_2__dispatch_retract_frame wm f [] net i c n fr = n
iret_19_2__dispatch_retract_frame wm f (k :: is) (MkNetwork alphas chains) i c n fr with (iret_6_4__admits (iret_6_6__alpha_at alphas k) f) proof adm
  iret_19_2__dispatch_retract_frame wm f (k :: is) (MkNetwork alphas chains) i c n fr | False =
    iret_19_2__dispatch_retract_frame wm f is (MkNetwork alphas chains) i c n fr
  iret_19_2__dispatch_retract_frame wm f (k :: is) (MkNetwork alphas chains) i c n fr | True =
    iret_19_2__dispatch_retract_frame wm f is
      (MkNetwork (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f) chains)) i c
      (trans (lcyc_1_1__nth_map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f) i chains)
             (trans (cong (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f)) n)
                    (cong Just (iret_7_7__retract_chain_frame wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f c
                                  (iret_6_4__frame_alpha alphas k f (cnodes c) fr adm)))))
      (lcyc_1_1__all_from_elem (cnodes c) (\b, eb =>
         trans (iret_6_4__admits_same alphas (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) (iret_6_5__remove_same_alphas k f alphas) (balpha b) f)
               (lcyc_1_1__all_lookup fr eb)))

-- ---------------------------------------------------------------------
-- The shapes are kept, against the loaded network
-- ---------------------------------------------------------------------

--@spec [RLOW.4.2.1]
--@spec [IRET.7.4]
||| TWO CHAINS OF ONE KIND: node by node the same alpha and the same flag.
||| The join tests, the memories and the counts may differ. What the frame
||| reads of a chain -- the kinds its nodes read, which are positive and
||| which are NOT nodes -- and nothing a re-time changes:
||| Rete/NetworkTick.idr's re-time gives a node a new test and keeps its
||| alpha and its flag. Weaker than Rete/NetworkTransferAgree.idr's
||| `Rlow_4_2_1__same_shape`, which compares the tests too.
public export
data Rlow_4_2_1__same_kinds : List Iret_7_4__beta -> List Iret_7_4__beta -> Type where
  SKNil  : Rlow_4_2_1__same_kinds [] []
  SKCons : {rest, rest' : List Iret_7_4__beta} -> (b, b' : Iret_7_4__beta) -> balpha b' = balpha b -> bneg b' = bneg b ->
           Rlow_4_2_1__same_kinds rest rest' -> Rlow_4_2_1__same_kinds (b :: rest) (b' :: rest')

--@derives [RLOW.4.2.1]
export
rlow_4_2_1__same_kinds_refl : (nodes : List Iret_7_4__beta) -> Rlow_4_2_1__same_kinds nodes nodes
rlow_4_2_1__same_kinds_refl [] = SKNil
rlow_4_2_1__same_kinds_refl (b :: rest) = SKCons _ _ Refl Refl (rlow_4_2_1__same_kinds_refl rest)

--@derives [RLOW.4.2.1]
export
rlow_4_2_1__same_kinds_trans : (n1, n2, n3 : List Iret_7_4__beta) -> Rlow_4_2_1__same_kinds n1 n2 -> Rlow_4_2_1__same_kinds n2 n3 -> Rlow_4_2_1__same_kinds n1 n3
rlow_4_2_1__same_kinds_trans [] [] [] SKNil SKNil = SKNil
rlow_4_2_1__same_kinds_trans (b1 :: r1) (b2 :: r2) (b3 :: r3) (SKCons _ _ a12 n12 s12) (SKCons _ _ a23 n23 s23) =
  SKCons _ _ (trans a23 a12) (trans n23 n12) (rlow_4_2_1__same_kinds_trans r1 r2 r3 s12 s23)

--@derives [RLOW.4.2.1]
--@derives [IRET.7.4]
||| Chains of one shape are of one kind: the shape compares the tests too.
||| What lets every propagation path's shape lemma serve the kinds.
export
rlow_4_2_1__same_shape_kinds : (nodes, nodes' : List Iret_7_4__beta) -> Rlow_4_2_1__same_shape nodes nodes' -> Rlow_4_2_1__same_kinds nodes nodes'
rlow_4_2_1__same_shape_kinds [] [] SSNil = SKNil
rlow_4_2_1__same_shape_kinds (b :: rest) (b' :: rest') (SSCons _ _ ba bj bn srest) = SKCons _ _ ba bn (rlow_4_2_1__same_shape_kinds rest rest' srest)

--@derives [RLOW.5.1]
--@derives [IRET.7.4]
||| Chains of one kind over alphas of one shape have the same positive
||| kinds: the positive kinds read the alphas and the flags, never a test.
export
rlow_5_1__pos_kinds_same_kinds : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' ->
                                 (nodes, nodes' : List Iret_7_4__beta) -> Rlow_4_2_1__same_kinds nodes nodes' ->
                                 rlow_5_1__pos_kinds alphas' nodes' = rlow_5_1__pos_kinds alphas nodes
rlow_5_1__pos_kinds_same_kinds alphas alphas' sa [] [] SKNil = Refl
rlow_5_1__pos_kinds_same_kinds alphas alphas' sa (MkBeta a j True lm cs :: rest) (MkBeta a' j' n' lm' cs' :: rest') (SKCons _ _ ba bn srest) =
  rewrite ba in rewrite bn in rlow_5_1__pos_kinds_same_kinds alphas alphas' sa rest rest' srest
rlow_5_1__pos_kinds_same_kinds alphas alphas' sa (MkBeta a j False lm cs :: rest) (MkBeta a' j' n' lm' cs' :: rest') (SKCons _ _ ba bn srest) =
  rewrite ba in rewrite bn in cong2 (::) (fst (sa a)) (rlow_5_1__pos_kinds_same_kinds alphas alphas' sa rest rest' srest)

--@spec [RLOW.4.2.1]
--@spec [IRET.6.1]
||| THE SHAPES KEPT, against the loaded alphas and chains: the alphas have
||| the same schemas and tests, there are as many chains, and every chain
||| has the same nodes' kinds and the same actions. Memories, counts,
||| activations and the nodes' join tests may differ: they are what a run,
||| or a tick's re-time, changes.
public export
Rlow_4_2_1__shapes_kept : List Iret_6_1__alpha -> List Rlow_4_2_1__chain -> Iret_19__engine -> Type
Rlow_4_2_1__shapes_kept alphas0 chains0 eng =
  ( Iret_6_1__same_alphas alphas0 (nalphas (enet eng))
  , length (nchains (enet eng)) = length chains0
  , (r : Nat) -> (ch0, ch : Rlow_4_2_1__chain) -> rarc_5_6_5__nth r chains0 = Just ch0 -> rarc_5_6_5__nth r (nchains (enet eng)) = Just ch ->
      (Rlow_4_2_1__same_kinds (cnodes ch0) (cnodes ch), cactions ch = cactions ch0) )

--@derives [RLOW.4.2.1]
||| The loaded network keeps its own shapes.
export
rlow_4_2_1__shapes_kept_refl : (eng : Iret_19__engine) -> Rlow_4_2_1__shapes_kept (nalphas (enet eng)) (nchains (enet eng)) eng
rlow_4_2_1__shapes_kept_refl eng =
  ( iret_6_1__same_alphas_refl (nalphas (enet eng))
  , Refl
  , \r, ch0, ch, n0, n => replace {p = \z => (Rlow_4_2_1__same_kinds (cnodes ch0) (cnodes z), cactions z = cactions ch0)} (iret_11_4__just_inj (trans (sym n0) n))
                            (rlow_4_2_1__same_kinds_refl (cnodes ch0), Refl) )

--@derives [RLOW.4.2.1]
||| A network transformation that keeps the alphas' shape, the chain count
||| and every chain's kinds and actions keeps the shapes kept. The form the
||| re-time of Rete/NetworkFrameRetime.idr needs: its nodes keep their
||| kinds and not their tests.
export
rlow_4_2_1__shapes_kept_through_kinds : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (eng : Iret_19__engine) -> (wm' : Rarc_5_6_4__wm) -> (net' : Rarc_5_3_1__network) ->
                                        Rlow_4_2_1__shapes_kept alphas0 chains0 eng ->
                                        Iret_6_1__same_alphas (nalphas (enet eng)) (nalphas net') ->
                                        length (nchains net') = length (nchains (enet eng)) ->
                                        ((r : Nat) -> (c, c' : Rlow_4_2_1__chain) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just c -> rarc_5_6_5__nth r (nchains net') = Just c' ->
                                           (Rlow_4_2_1__same_kinds (cnodes c) (cnodes c'), cactions c' = cactions c)) ->
                                        Rlow_4_2_1__shapes_kept alphas0 chains0 (MkEngine wm' net')
rlow_4_2_1__shapes_kept_through_kinds alphas0 chains0 eng wm' net' (sa, len, sh) sa' len' sh' =
  ( iret_6_1__same_alphas_trans _ _ _ sa sa'
  , trans len' len
  , \r, ch0, ch', n0, n' =>
      let (ch ** n) = lcyc_1_1__nth_length r (nchains (enet eng)) (nchains net') len' n'
          (s1, a1) = sh r ch0 ch n0 n
          (s2, a2) = sh' r ch ch' n n'
      in (rlow_4_2_1__same_kinds_trans _ _ _ s1 s2, trans a2 a1) )

--@derives [RLOW.4.2.1]
||| A network transformation that keeps the alphas' shape, the chain count
||| and every chain's shape and actions keeps the shapes kept: the form the
||| propagation paths' shape lemmas give.
export
rlow_4_2_1__shapes_kept_through : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (eng : Iret_19__engine) -> (wm' : Rarc_5_6_4__wm) -> (net' : Rarc_5_3_1__network) ->
                                  Rlow_4_2_1__shapes_kept alphas0 chains0 eng ->
                                  Iret_6_1__same_alphas (nalphas (enet eng)) (nalphas net') ->
                                  length (nchains net') = length (nchains (enet eng)) ->
                                  ((r : Nat) -> (c, c' : Rlow_4_2_1__chain) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just c -> rarc_5_6_5__nth r (nchains net') = Just c' ->
                                     (Rlow_4_2_1__same_shape (cnodes c) (cnodes c'), cactions c' = cactions c)) ->
                                  Rlow_4_2_1__shapes_kept alphas0 chains0 (MkEngine wm' net')
rlow_4_2_1__shapes_kept_through alphas0 chains0 eng wm' net' sk sa' len' sh' =
  rlow_4_2_1__shapes_kept_through_kinds alphas0 chains0 eng wm' net' sk sa' len'
    (\r, c, c', n, n' => let (s, a) = sh' r c c' n n' in (rlow_4_2_1__same_shape_kinds _ _ s, a))

--@derives [IRET.19.1]
export
iret_19_1__insert_shapes : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                           Rlow_4_2_1__shapes_kept alphas0 chains0 eng -> Rlow_4_2_1__shapes_kept alphas0 chains0 (iret_19_1__insert f eng)
iret_19_1__insert_shapes alphas0 chains0 f eng sk =
  rlow_4_2_1__shapes_kept_through alphas0 chains0 eng (ewm eng ++ [f]) (iret_6_4__dispatch_assert (ewm eng ++ [f]) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)) sk
    (fst (iret_6_4__dispatch_assert_shape (ewm eng ++ [f]) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)))
    (iret_6_4__dispatch_assert_length (ewm eng ++ [f]) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng))
    (snd (iret_6_4__dispatch_assert_shape (ewm eng ++ [f]) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)))

--@derives [IRET.19.2]
export
iret_19_2__retract_shapes : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                            Rlow_4_2_1__shapes_kept alphas0 chains0 eng -> Rlow_4_2_1__shapes_kept alphas0 chains0 (iret_19_2__retract f eng)
iret_19_2__retract_shapes alphas0 chains0 f eng sk =
  rlow_4_2_1__shapes_kept_through alphas0 chains0 eng (rarc_5_6_4__remove_exact f (ewm eng)) (iret_19_2__dispatch_retract (ewm eng) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)) sk
    (fst (iret_19_2__dispatch_retract_shape (ewm eng) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)))
    (iret_19_2__dispatch_retract_length (ewm eng) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng))
    (snd (iret_19_2__dispatch_retract_shape (ewm eng) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)))

--@derives [IRET.19.1]
--@derives [LFAC.2.5.1]
--@derives [LFAC.2.5.3]
export
iret_19_1__assert_shapes : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) ->
                           Rlow_4_2_1__shapes_kept alphas0 chains0 eng -> Rlow_4_2_1__shapes_kept alphas0 chains0 (iret_19_1__assert life avoid k key pay eng)
iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk with (life k)
  iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk | Explicit = iret_19_1__insert_shapes alphas0 chains0 _ eng sk
  iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk | Relation with (iret_19_1__find_relation k key pay (ewm eng))
    iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk | Relation | (Just old) = sk
    iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk | Relation | Nothing = iret_19_1__insert_shapes alphas0 chains0 _ eng sk
  iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk | Entity with (iret_19_1__find_entity k key (ewm eng))
    iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk | Entity | Nothing = iret_19_1__insert_shapes alphas0 chains0 _ eng sk
    iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk | Entity | (Just old) with (fpay old == pay)
      iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk | Entity | (Just old) | True = sk
      iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk | Entity | (Just old) | False =
        iret_19_1__insert_shapes alphas0 chains0 _ (iret_19_2__retract old eng) (iret_19_2__retract_shapes alphas0 chains0 old eng sk)

--@derives [LSCP.2.1.1]
export
lscp_2_1_1__withdraw_shapes : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                              Rlow_4_2_1__shapes_kept alphas0 chains0 eng -> Rlow_4_2_1__shapes_kept alphas0 chains0 (lscp_2_1_1__withdraw f eng)
lscp_2_1_1__withdraw_shapes alphas0 chains0 f eng sk with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng))
  lscp_2_1_1__withdraw_shapes alphas0 chains0 f eng sk | True = iret_19_2__retract_shapes alphas0 chains0 f eng sk
  lscp_2_1_1__withdraw_shapes alphas0 chains0 f eng sk | False = sk

--@derives [IDAT.6.2.2]
||| Marking an activation fired keeps a chain's nodes and actions.
export
idat_6_2_2__mark_chain_shape : (j : Nat) -> (c : Rlow_4_2_1__chain) -> (cnodes (idat_6_2_2__mark_chain j c) = cnodes c, cactions (idat_6_2_2__mark_chain j c) = cactions c)
idat_6_2_2__mark_chain_shape j (MkChain nodes acts actions) = (Refl, Refl)

--@derives [IDAT.6.2.2]
export
idat_6_2_2__mark_net_shapes : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (r, j : Nat) -> (eng : Iret_19__engine) ->
                              Rlow_4_2_1__shapes_kept alphas0 chains0 eng -> Rlow_4_2_1__shapes_kept alphas0 chains0 (idat_6_2_2__mark_net r j eng)
idat_6_2_2__mark_net_shapes alphas0 chains0 r j eng (sa, len, sh) =
  ( sa
  , trans (lcyc_1_1__length_set_at r (idat_6_2_2__mark_chain j) (nchains (enet eng))) len
  , \r', ch0, ch', n0, n' => case decEq r r' of
      Yes e =>
        let n'' = the (rarc_5_6_5__nth r (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) (nchains (enet eng))) = Just ch')
                    (replace {p = \z => rarc_5_6_5__nth z (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) (nchains (enet eng))) = Just ch'} (sym e) n')
            n0' = the (rarc_5_6_5__nth r chains0 = Just ch0) (replace {p = \z => rarc_5_6_5__nth z chains0 = Just ch0} (sym e) n0)
            (ch ** (n, eqc)) = iret_11_4__map_just (idat_6_2_2__mark_chain j) (rarc_5_6_5__nth r (nchains (enet eng))) ch'
                                 (trans (sym (lcyc_1_1__nth_set_at_eq r (idat_6_2_2__mark_chain j) (nchains (enet eng)))) n'')
            (s, a) = sh r ch0 ch n0' n
            (ns, as) = idat_6_2_2__mark_chain_shape j ch
        in ( replace {p = \z => Rlow_4_2_1__same_kinds (cnodes ch0) (cnodes z)} (sym eqc) (replace {p = \z => Rlow_4_2_1__same_kinds (cnodes ch0) z} (sym ns) s)
           , trans (cong cactions eqc) (trans as a) )
      No ne => sh r' ch0 ch' n0 (trans (sym (lcyc_1_1__nth_set_at_neq r r' ne (idat_6_2_2__mark_chain j) (nchains (enet eng)))) n') )

-- ---------------------------------------------------------------------
-- The frame invariant through a pump
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
||| THE FRAME INVARIANT: the view, and the shapes kept against the loaded
||| network. Every working-memory operation and every firing keeps it.
public export
Ltim_2_5_1__frame_inv : List Iret_6_1__alpha -> List Rlow_4_2_1__chain -> Iret_19__engine -> Type
Ltim_2_5_1__frame_inv alphas0 chains0 eng = (Iret_19__view eng, Rlow_4_2_1__shapes_kept alphas0 chains0 eng)

--@derives [IRET.19.1]
export
iret_19_1__assert_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) ->
                        Ltim_2_5_1__frame_inv alphas0 chains0 eng -> Ltim_2_5_1__frame_inv alphas0 chains0 (iret_19_1__assert life avoid k key pay eng)
iret_19_1__assert_inv alphas0 chains0 life avoid k key pay eng (v, sk) =
  (iret_19_1__assert_view life avoid k key pay eng v, iret_19_1__assert_shapes alphas0 chains0 life avoid k key pay eng sk)

--@derives [LSCP.2.1.1]
export
lscp_2_1_1__withdraw_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                           Ltim_2_5_1__frame_inv alphas0 chains0 eng -> Ltim_2_5_1__frame_inv alphas0 chains0 (lscp_2_1_1__withdraw f eng)
lscp_2_1_1__withdraw_inv alphas0 chains0 f eng (v, sk) = (lscp_2_1_1__withdraw_view f eng v, lscp_2_1_1__withdraw_shapes alphas0 chains0 f eng sk)

--@derives [IRET.19.2]
export
iret_19_2__retract_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Elem f (ewm eng) ->
                         Ltim_2_5_1__frame_inv alphas0 chains0 eng -> Ltim_2_5_1__frame_inv alphas0 chains0 (iret_19_2__retract f eng)
iret_19_2__retract_inv alphas0 chains0 f eng ef (v, sk) = (iret_19_2__retract_view f eng ef v, iret_19_2__retract_shapes alphas0 chains0 f eng sk)

--@derives [IDAT.6.2.2]
export
idat_6_2_2__mark_net_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (r, j : Nat) -> (eng : Iret_19__engine) ->
                           Ltim_2_5_1__frame_inv alphas0 chains0 eng -> Ltim_2_5_1__frame_inv alphas0 chains0 (idat_6_2_2__mark_net r j eng)
idat_6_2_2__mark_net_inv alphas0 chains0 r j eng (v, sk) = (idat_6_2_2__mark_net_view r j eng v, idat_6_2_2__mark_net_shapes alphas0 chains0 r j eng sk)

--@derives [RARC.5.6.4]
||| An input keeps the invariant: inputs are not framed, and need not be.
export
rarc_5_6_4__apply_net_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (life : Nat -> Lscp_1_3__lifecycle) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                            Ltim_2_5_1__frame_inv alphas0 chains0 eng -> Ltim_2_5_1__frame_inv alphas0 chains0 (rarc_5_6_4__apply_net life ev eng)
rarc_5_6_4__apply_net_inv alphas0 chains0 life (Assert k key pay) eng inv = iret_19_1__assert_inv alphas0 chains0 life [] k key pay eng inv
rarc_5_6_4__apply_net_inv alphas0 chains0 life (Retract i) eng inv with (rarc_5_6_4__lookup_fact i (ewm eng)) proof lk
  rarc_5_6_4__apply_net_inv alphas0 chains0 life (Retract i) eng inv | Nothing = inv
  rarc_5_6_4__apply_net_inv alphas0 chains0 life (Retract i) eng inv | (Just f) =
    iret_19_2__retract_inv alphas0 chains0 f eng (fst (rarc_5_6_4__lookup_elem i (ewm eng) f lk)) inv

--@derives [RARC.5.6.4]
export
rarc_5_6_4__applied_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (life : Nat -> Lscp_1_3__lifecycle) -> (evs : List Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                          Ltim_2_5_1__frame_inv alphas0 chains0 eng -> Ltim_2_5_1__frame_inv alphas0 chains0 (rarc_5_6_4__applied life evs eng)
rarc_5_6_4__applied_inv alphas0 chains0 life [] eng inv = inv
rarc_5_6_4__applied_inv alphas0 chains0 life (ev :: evs) eng inv =
  rarc_5_6_4__applied_inv alphas0 chains0 life evs (rarc_5_6_4__apply_net life ev eng) (rarc_5_6_4__apply_net_inv alphas0 chains0 life ev eng inv)

-- ---------------------------------------------------------------------
-- Every working-memory operation skips a chain that does not read the kind
-- ---------------------------------------------------------------------

--@derives [IRET.19.1]
||| INSERTING A FACT of a kind the chain does not read leaves the chain.
export
iret_19_1__insert_frame : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> (i : Nat) -> (c : Rlow_4_2_1__chain) ->
                          rarc_5_6_5__nth i (nchains (enet eng)) = Just c ->
                          rarc_5_6_5__elem (fkind f) (ltim_2_5_1__reads (nalphas (enet eng)) (cnodes c)) = False ->
                          rarc_5_6_5__nth i (nchains (enet (iret_19_1__insert f eng))) = Just c
iret_19_1__insert_frame f eng i c n nr =
  iret_6_4__dispatch_assert_frame (ewm eng ++ [f]) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng) i c n
    (iret_6_4__reads_admit (nalphas (enet eng)) (cnodes c) f nr)

--@derives [IRET.19.2]
||| RETRACTING A FACT of a kind the chain does not read leaves the chain.
export
iret_19_2__retract_frame : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> (i : Nat) -> (c : Rlow_4_2_1__chain) ->
                           rarc_5_6_5__nth i (nchains (enet eng)) = Just c ->
                           rarc_5_6_5__elem (fkind f) (ltim_2_5_1__reads (nalphas (enet eng)) (cnodes c)) = False ->
                           rarc_5_6_5__nth i (nchains (enet (iret_19_2__retract f eng))) = Just c
iret_19_2__retract_frame f eng i c n nr =
  iret_19_2__dispatch_retract_frame (ewm eng) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng) i c n
    (iret_6_4__reads_admit (nalphas (enet eng)) (cnodes c) f nr)

--@derives [IRET.19.1]
--@derives [LFAC.2.5.1]
--@derives [LFAC.2.5.3]
||| ASSERT of a kind the chain does not read leaves the chain, under any
||| lifecycle: the minted fact has that kind, and so does the entity a
||| replace retracts.
export
iret_19_1__assert_frame : (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) -> (i : Nat) -> (c : Rlow_4_2_1__chain) ->
                          rarc_5_6_5__nth i (nchains (enet eng)) = Just c ->
                          rarc_5_6_5__elem k (ltim_2_5_1__reads (nalphas (enet eng)) (cnodes c)) = False ->
                          rarc_5_6_5__nth i (nchains (enet (iret_19_1__assert life avoid k key pay eng))) = Just c
iret_19_1__assert_frame life avoid k key pay eng i c n nr with (life k)
  iret_19_1__assert_frame life avoid k key pay eng i c n nr | Explicit =
    iret_19_1__insert_frame (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng i c n nr
  iret_19_1__assert_frame life avoid k key pay eng i c n nr | Relation with (iret_19_1__find_relation k key pay (ewm eng))
    iret_19_1__assert_frame life avoid k key pay eng i c n nr | Relation | (Just old) = n
    iret_19_1__assert_frame life avoid k key pay eng i c n nr | Relation | Nothing =
      iret_19_1__insert_frame (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng i c n nr
  iret_19_1__assert_frame life avoid k key pay eng i c n nr | Entity with (iret_19_1__find_entity k key (ewm eng)) proof fe
    iret_19_1__assert_frame life avoid k key pay eng i c n nr | Entity | Nothing =
      iret_19_1__insert_frame (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng i c n nr
    iret_19_1__assert_frame life avoid k key pay eng i c n nr | Entity | (Just old) with (fpay old == pay)
      iret_19_1__assert_frame life avoid k key pay eng i c n nr | Entity | (Just old) | True = n
      iret_19_1__assert_frame life avoid k key pay eng i c n nr | Entity | (Just old) | False =
        let oldK = the (fkind old = k)
                     (lcyc_1_1__nat_eq_true _ _ (lcyc_1_1__and_true_l _ _ (fst (lcyc_1_1__find_just _ (ewm eng) fe))))
            nrOld = the (rarc_5_6_5__elem (fkind old) (ltim_2_5_1__reads (nalphas (enet eng)) (cnodes c)) = False)
                      (replace {p = \z => rarc_5_6_5__elem z (ltim_2_5_1__reads (nalphas (enet eng)) (cnodes c)) = False} (sym oldK) nr)
            sa = the (Iret_6_1__same_alphas (nalphas (enet eng)) (nalphas (enet (iret_19_2__retract old eng))))
                   (fst (iret_19_2__dispatch_retract_shape (ewm eng) old (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)))
            nr2 = the (rarc_5_6_5__elem k (ltim_2_5_1__reads (nalphas (enet (iret_19_2__retract old eng))) (cnodes c)) = False)
                    (replace {p = \z => rarc_5_6_5__elem k z = False} (sym (ltim_2_5_1__reads_same _ _ sa (cnodes c))) nr)
        in iret_19_1__insert_frame (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) (iret_19_2__retract old eng) i c
             (iret_19_2__retract_frame old eng i c n nrOld) nr2

--@derives [LSCP.2.1.1]
||| WITHDRAW of a fact of a kind the chain does not read leaves the chain.
export
lscp_2_1_1__withdraw_frame : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> (i : Nat) -> (c : Rlow_4_2_1__chain) ->
                             rarc_5_6_5__nth i (nchains (enet eng)) = Just c ->
                             rarc_5_6_5__elem (fkind f) (ltim_2_5_1__reads (nalphas (enet eng)) (cnodes c)) = False ->
                             rarc_5_6_5__nth i (nchains (enet (lscp_2_1_1__withdraw f eng))) = Just c
lscp_2_1_1__withdraw_frame f eng i c n nr with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng))
  lscp_2_1_1__withdraw_frame f eng i c n nr | True = iret_19_2__retract_frame f eng i c n nr
  lscp_2_1_1__withdraw_frame f eng i c n nr | False = n

-- ---------------------------------------------------------------------
-- A fired match has its rule's kinds
-- ---------------------------------------------------------------------

--@derives [RLOW.5.1]
--@derives [IRET.7.4]
||| THE KINDS OF A MATCH: under the view, the fact at position j of a
||| chain's activation has the chain's j-th positive kind -- read against
||| the loaded alphas and chain, whose shapes the engine keeps. What makes
||| a withdraw's kind known before the withdraw runs.
export
rlow_5_1__bound_kinds : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (eng : Iret_19__engine) -> Ltim_2_5_1__frame_inv alphas0 chains0 eng ->
                        (r : Nat) -> (ch0, ch : Rlow_4_2_1__chain) -> rarc_5_6_5__nth r chains0 = Just ch0 -> rarc_5_6_5__nth r (nchains (enet eng)) = Just ch ->
                        (a : Iret_8_1__act) -> Elem a (cacts ch) ->
                        (j : Nat) -> (f : Lfac_1_7_1__fact) -> rarc_5_6_5__nth j (atuple a) = Just f ->
                        rarc_5_6_5__nth j (rlow_5_1__pos_kinds alphas0 (cnodes ch0)) = Just (fkind f)
rlow_5_1__bound_kinds alphas0 chains0 eng (v, (sa, len, sh)) r ch0 ch n0 n a ea j f nf =
  let (ss, _) = snd (rarc_5_6_5__view_recomputed eng v) ch (lcyc_1_1__nth_elem r (nchains (enet eng)) n)
      ev = the (Elem (atuple a) (iret_7_7__view (nalphas (enet eng)) (ewm eng) (cnodes ch) [[]]))
             (fst (ss (atuple a)) (lcyc_1_1__elem_map_fwd atuple ea))
      (u ** (s ** (eu, es, teq, _, _))) = rlow_4_2_1__view_from_front (nalphas (enet eng)) (ewm eng) (cnodes ch) 0 [[]] (Refl :: Nil) (atuple a) ev
      uNil = the (u = []) (iret_12__elem_singleton eu)
      tokS = the (atuple a = s) (trans teq (cong (\z => z ++ s) uNil))
      ks = the (lcyc_3_2_2__kinds_of s = rlow_5_1__pos_kinds (nalphas (enet eng)) (cnodes ch))
             (lcyc_1_1__all_lookup (iret_7_4__tuples_kinds (rlow_5_1__pos_kinds (nalphas (enet eng)) (cnodes ch)) (ewm eng)) es)
      (sh1, _) = sh r ch0 ch n0 n
      pk = the (rlow_5_1__pos_kinds (nalphas (enet eng)) (cnodes ch) = rlow_5_1__pos_kinds alphas0 (cnodes ch0))
             (rlow_5_1__pos_kinds_same_kinds alphas0 (nalphas (enet eng)) sa (cnodes ch0) (cnodes ch) sh1)
      nfs = the (rarc_5_6_5__nth j s = Just f) (replace {p = \z => rarc_5_6_5__nth j z = Just f} tokS nf)
  in trans (cong (rarc_5_6_5__nth j) (sym (trans ks pk)))
           (trans (lcyc_1_1__nth_map fkind j s) (cong (map fkind) nfs))

-- ---------------------------------------------------------------------
-- The RHS skips a framed chain
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.7]
--@derives [LTIM.2.5.1]
||| ONE ACTION of a rule that does not write into the chain leaves the
||| chain, and keeps the invariant: an emit asserts its kind, a withdraw
||| retracts a fact of the rule's positive kind at that position, and
||| neither kind is one the chain reads.
export
rarc_5_6_7__do_action_frame : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (life : Nat -> Lscp_1_3__lifecycle) ->
                              (bound : List Lfac_1_7_1__fact) -> (ch0 : Rlow_4_2_1__chain) ->
                              ((jj : Nat) -> (f : Lfac_1_7_1__fact) -> rarc_5_6_5__nth jj bound = Just f -> rarc_5_6_5__nth jj (rlow_5_1__pos_kinds alphas0 (cnodes ch0)) = Just (fkind f)) ->
                              (act : Lgra_10_1__action) -> Elem act (cactions ch0) ->
                              (eng : Iret_19__engine) -> Ltim_2_5_1__frame_inv alphas0 chains0 eng ->
                              (i : Nat) -> (c : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i (nchains (enet eng)) = Just c ->
                              ((k : Nat) -> Elem k (ltim_2_5_1__writes alphas0 ch0) -> rarc_5_6_5__elem k (ltim_2_5_1__reads alphas0 (cnodes c)) = False) ->
                              ( Ltim_2_5_1__frame_inv alphas0 chains0 (rarc_5_6_7__do_action_net life bound act eng)
                              , rarc_5_6_5__nth i (nchains (enet (rarc_5_6_7__do_action_net life bound act eng))) = Just c )
rarc_5_6_7__do_action_frame alphas0 chains0 life bound ch0 bk (Emit k value) ea eng inv i c n nw =
  let nr0 = the (rarc_5_6_5__elem k (ltim_2_5_1__reads alphas0 (cnodes c)) = False)
              (nw k (ltim_2_5_1__writes_emit (rlow_5_1__pos_kinds alphas0 (cnodes ch0)) (cactions ch0) k value ea))
      nr = the (rarc_5_6_5__elem k (ltim_2_5_1__reads (nalphas (enet eng)) (cnodes c)) = False)
             (replace {p = \z => rarc_5_6_5__elem k z = False} (sym (ltim_2_5_1__reads_same alphas0 (nalphas (enet eng)) (fst (snd inv)) (cnodes c))) nr0)
  in ( iret_19_1__assert_inv alphas0 chains0 life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) eng inv
     , iret_19_1__assert_frame life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) eng i c n nr )
rarc_5_6_7__do_action_frame alphas0 chains0 life bound ch0 bk (Withdraw jj) ea eng inv i c n nw with (rarc_5_6_5__nth jj bound) proof nb
  rarc_5_6_7__do_action_frame alphas0 chains0 life bound ch0 bk (Withdraw jj) ea eng inv i c n nw | Nothing = (inv, n)
  rarc_5_6_7__do_action_frame alphas0 chains0 life bound ch0 bk (Withdraw jj) ea eng inv i c n nw | (Just f) =
    let nr0 = the (rarc_5_6_5__elem (fkind f) (ltim_2_5_1__reads alphas0 (cnodes c)) = False)
                (nw (fkind f) (ltim_2_5_1__writes_withdraw (rlow_5_1__pos_kinds alphas0 (cnodes ch0)) (cactions ch0) jj (fkind f) ea (bk jj f nb)))
        nr = the (rarc_5_6_5__elem (fkind f) (ltim_2_5_1__reads (nalphas (enet eng)) (cnodes c)) = False)
               (replace {p = \z => rarc_5_6_5__elem (fkind f) z = False} (sym (ltim_2_5_1__reads_same alphas0 (nalphas (enet eng)) (fst (snd inv)) (cnodes c))) nr0)
    in ( lscp_2_1_1__withdraw_inv alphas0 chains0 f eng inv
       , lscp_2_1_1__withdraw_frame f eng i c n nr )

--@derives [RARC.5.6.7]
--@derives [LTIM.2.5.1]
||| THE RHS of a rule that does not write into the chain leaves the chain,
||| action by action.
export
rarc_5_6_7__do_actions_frame : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (life : Nat -> Lscp_1_3__lifecycle) ->
                               (bound : List Lfac_1_7_1__fact) -> (ch0 : Rlow_4_2_1__chain) ->
                               ((jj : Nat) -> (f : Lfac_1_7_1__fact) -> rarc_5_6_5__nth jj bound = Just f -> rarc_5_6_5__nth jj (rlow_5_1__pos_kinds alphas0 (cnodes ch0)) = Just (fkind f)) ->
                               (as : List Lgra_10_1__action) -> ((act : Lgra_10_1__action) -> Elem act as -> Elem act (cactions ch0)) ->
                               (eng : Iret_19__engine) -> Ltim_2_5_1__frame_inv alphas0 chains0 eng ->
                               (i : Nat) -> (c : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i (nchains (enet eng)) = Just c ->
                               ((k : Nat) -> Elem k (ltim_2_5_1__writes alphas0 ch0) -> rarc_5_6_5__elem k (ltim_2_5_1__reads alphas0 (cnodes c)) = False) ->
                               ( Ltim_2_5_1__frame_inv alphas0 chains0 (rarc_5_6_7__do_actions_net life bound as eng)
                               , rarc_5_6_5__nth i (nchains (enet (rarc_5_6_7__do_actions_net life bound as eng))) = Just c )
rarc_5_6_7__do_actions_frame alphas0 chains0 life bound ch0 bk [] sub eng inv i c n nw = (inv, n)
rarc_5_6_7__do_actions_frame alphas0 chains0 life bound ch0 bk (act :: as) sub eng inv i c n nw =
  let (inv1, n1) = rarc_5_6_7__do_action_frame alphas0 chains0 life bound ch0 bk act (sub act Here) eng inv i c n nw
  in rarc_5_6_7__do_actions_frame alphas0 chains0 life bound ch0 bk as (\a', e => sub a' (There e)) (rarc_5_6_7__do_action_net life bound act eng) inv1 i c n1 nw

-- ---------------------------------------------------------------------
-- The plain run, traced
-- ---------------------------------------------------------------------

--@spec [IRET.11.4]
||| One firing, naming the ordinal that fired, with the engine after it:
||| the plain network's form of Rete/NetworkTraced.idr's `iret_11_4__fire_tms_net`.
public export
iret_11_4__fire_net : (Nat -> Lscp_1_3__lifecycle) -> Iret_19__engine -> Maybe (Nat, Iret_19__engine)
iret_11_4__fire_net life eng = case iret_11_1__select (nchains (enet eng)) of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (nchains (enet eng)) of
    Nothing => Nothing
    Just c => case rarc_5_6_5__nth j (cacts c) of
      Nothing => Nothing
      Just a  => Just (r, rarc_5_6_7__do_actions_net life (atuple a) (cactions c) (idat_6_2_2__mark_net r j eng))

--@derives [IRET.11.4]
||| The named firing is the firing.
export
iret_11_4__fire_net_step : (life : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) ->
                           map snd (iret_11_4__fire_net life eng) = iret_11_4__step_net life eng
iret_11_4__fire_net_step life eng with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__fire_net_step life eng | Nothing = Refl
  iret_11_4__fire_net_step life eng | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng)))
    iret_11_4__fire_net_step life eng | (Just (r, j)) | Nothing = Refl
    iret_11_4__fire_net_step life eng | (Just (r, j)) | (Just c) with (rarc_5_6_5__nth j (cacts c))
      iret_11_4__fire_net_step life eng | (Just (r, j)) | (Just c) | Nothing = Refl
      iret_11_4__fire_net_step life eng | (Just (r, j)) | (Just c) | (Just a) = Refl

--@derives [IRET.11.4]
||| What a named firing is: the selection, the chain and activation
||| selected, and the engine after the mark and the RHS.
export
iret_11_4__fire_net_just : (life : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) -> (r : Nat) -> (eng' : Iret_19__engine) ->
                           iret_11_4__fire_net life eng = Just (r, eng') ->
                           (j ** ch ** a ** ( iret_11_1__select (nchains (enet eng)) = Just (r, j)
                                            , rarc_5_6_5__nth r (nchains (enet eng)) = Just ch
                                            , rarc_5_6_5__nth j (cacts ch) = Just a
                                            , eng' = rarc_5_6_7__do_actions_net life (atuple a) (cactions ch) (idat_6_2_2__mark_net r j eng) ))
iret_11_4__fire_net_just life eng r eng' eq with (iret_11_1__select (nchains (enet eng))) proof sel
  iret_11_4__fire_net_just life eng r eng' eq | Nothing = absurd eq
  iret_11_4__fire_net_just life eng r eng' eq | (Just (r0, j)) with (rarc_5_6_5__nth r0 (nchains (enet eng))) proof nr
    iret_11_4__fire_net_just life eng r eng' eq | (Just (r0, j)) | Nothing = absurd eq
    iret_11_4__fire_net_just life eng r eng' eq | (Just (r0, j)) | (Just c) with (rarc_5_6_5__nth j (cacts c)) proof nj
      iret_11_4__fire_net_just life eng r eng' eq | (Just (r0, j)) | (Just c) | Nothing = absurd eq
      iret_11_4__fire_net_just life eng r eng' eq | (Just (r0, j)) | (Just c) | (Just a) =
        let pe = the ((r0, rarc_5_6_7__do_actions_net life (atuple a) (cactions c) (idat_6_2_2__mark_net r0 j eng)) = (r, eng')) (iret_11_4__just_inj eq)
            re = the (r0 = r) (cong fst pe)
        in (j ** c ** a ** ( cong (\z => Just (z, j)) re
                           , replace {p = \z => rarc_5_6_5__nth z (nchains (enet eng)) = Just c} re nr
                           , nj
                           , trans (sym (cong snd pe)) (cong (\z => rarc_5_6_7__do_actions_net life (atuple a) (cactions c) (idat_6_2_2__mark_net z j eng)) re) ))

--@spec [IRET.11.4]
--@spec [IRET.11.5]
||| The plain run, traced: the ordinals that fired, in order, with the
||| engine and the halt.
public export
iret_11_4__run_net_traced : (Nat -> Lscp_1_3__lifecycle) -> Nat -> Iret_19__engine -> (Iret_19__engine, Iret_11_4__halt, List Nat)
iret_11_4__run_net_traced life Z eng = (eng, FuelOut, [])
iret_11_4__run_net_traced life (S fuel) eng = case iret_11_4__fire_net life eng of
  Nothing => (eng, Quiescent, [])
  Just (r, eng') => let (t, h, tr) = iret_11_4__run_net_traced life fuel eng' in (t, h, r :: tr)

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE TRACED RUN IS THE ONE TRACED FOLD at its named firing
||| (Rete/RunFold.idr's `iret_11_4__trace_by`), by induction on the fuel.
export
iret_11_4__run_net_traced_by : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) ->
                               iret_11_4__run_net_traced life fuel eng = iret_11_4__trace_by (iret_11_4__fire_net life) fuel eng
iret_11_4__run_net_traced_by life Z eng = Refl
iret_11_4__run_net_traced_by life (S fuel) eng with (iret_11_4__fire_net life eng)
  iret_11_4__run_net_traced_by life (S fuel) eng | Nothing = Refl
  iret_11_4__run_net_traced_by life (S fuel) eng | (Just (r, eng')) with (iret_11_4__trace_by (iret_11_4__fire_net life) fuel eng') proof rr
    iret_11_4__run_net_traced_by life (S fuel) eng | (Just (r, eng')) | (t, h, tr) = rewrite trans (iret_11_4__run_net_traced_by life fuel eng') rr in Refl

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE TRACE IS THE RUN'S: the same engine, the same halt, as many
||| firings as the run counted. RunFold's `iret_11_4__trace_by_core` at the
||| named firing, through the two bridges.
export
iret_11_4__run_net_traced_core : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) ->
                                 (t ** h ** tr ** ( iret_11_4__run_net_traced life fuel eng = (t, h, tr)
                                                  , iret_11_4__run_net life fuel eng = (t, h, length tr) ))
iret_11_4__run_net_traced_core life fuel eng =
  let (t ** (h ** (tr ** (tE, rE)))) = iret_11_4__trace_by_core (iret_11_4__fire_net life) (iret_11_4__step_net life) (iret_11_4__fire_net_step life) fuel eng
  in (t ** h ** tr ** ( trans (iret_11_4__run_net_traced_by life fuel eng) tE
                      , trans (iret_11_4__run_net_by life fuel eng) rE ))

--@spec [LTIM.2.5.1]
||| One more when the ordinal is the one counted. By pattern matching, so
||| that a proof reduces it by rewriting the test alone.
public export
ltim_2_5_1__count_step : Bool -> Nat -> Nat
ltim_2_5_1__count_step True c = S c
ltim_2_5_1__count_step False c = c

--@spec [LTIM.2.5.1]
||| HOW OFTEN AN ORDINAL FIRED in a trace.
public export
ltim_2_5_1__count : Nat -> List Nat -> Nat
ltim_2_5_1__count i [] = 0
ltim_2_5_1__count i (r :: rs) = ltim_2_5_1__count_step (r == i) (ltim_2_5_1__count i rs)

--@derives [LTIM.2.5.1]
export
ltim_2_5_1__count_hit : (i, r : Nat) -> (rs : List Nat) -> (r == i) = True -> ltim_2_5_1__count i (r :: rs) = S (ltim_2_5_1__count i rs)
ltim_2_5_1__count_hit i r rs eq = cong (\z => ltim_2_5_1__count_step z (ltim_2_5_1__count i rs)) eq

--@derives [LTIM.2.5.1]
export
ltim_2_5_1__count_miss : (i, r : Nat) -> (rs : List Nat) -> (r == i) = False -> ltim_2_5_1__count i (r :: rs) = ltim_2_5_1__count i rs
ltim_2_5_1__count_miss i r rs eq = cong (\z => ltim_2_5_1__count_step z (ltim_2_5_1__count i rs)) eq

-- ---------------------------------------------------------------------
-- Selection against the count, one chain
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
||| A firing with nothing to fire selected nothing.
export
iret_11_4__step_net_nothing_select : (life : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) -> iret_11_4__step_net life eng = Nothing ->
                                     iret_11_1__select (nchains (enet eng)) = Nothing
iret_11_4__step_net_nothing_select life eng sn = case iret_11_1__select_cases (nchains (enet eng)) of
  Left z => z
  Right (r ** j ** sel) =>
    let (ch ** a ** (nt, nj, nf)) = iret_11_1__select_just (nchains (enet eng)) r j sel
    in absurd (trans (sym (iret_11_4__step_net_fires life eng r j ch a sel nt nj)) sn)

--@derives [IRET.11.1]
||| When nothing is unfired anywhere, nothing is unfired in any one chain.
export
iret_11_1__unfired_count_zero_at : (chains : List Rlow_4_2_1__chain) -> iret_11_4__unfired_count chains = 0 ->
                                   (i : Nat) -> (ch : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i chains = Just ch -> iret_11_4__unfired (cacts ch) = 0
iret_11_1__unfired_count_zero_at [] z i ch n = absurd n
iret_11_1__unfired_count_zero_at (c :: cs) z Z ch n =
  replace {p = \x => iret_11_4__unfired (cacts x) = 0} (iret_11_4__just_inj n) (fst (iret_11_4__plus_zero (iret_11_4__unfired (cacts c)) (iret_11_4__unfired_count cs) z))
iret_11_1__unfired_count_zero_at (c :: cs) z (S i) ch n =
  iret_11_1__unfired_count_zero_at cs (snd (iret_11_4__plus_zero (iret_11_4__unfired (cacts c)) (iret_11_4__unfired_count cs) z)) i ch n

-- ---------------------------------------------------------------------
-- One firing under the frame
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
--@derives [LTIM.2.5.1]
--@derives [IDAT.6.2.2]
||| ONE FIRING UNDER THE FRAME: the invariant is kept, and the framed chain
||| is as it was unless it is the rule that fired, when exactly the
||| activation selected, unfired before, is marked and nothing else of the
||| chain moves.
export
ltim_2_5_1__step_frame : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (life : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) ->
                         Ltim_2_5_1__frame_inv alphas0 chains0 eng ->
                         (i : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                         ltim_2_5_1__framed alphas0 chains0 nodes = True ->
                         rarc_5_6_5__nth i (nchains (enet eng)) = Just (MkChain nodes acts actions) ->
                         (r : Nat) -> (eng' : Iret_19__engine) -> iret_11_4__fire_net life eng = Just (r, eng') ->
                         ( Ltim_2_5_1__frame_inv alphas0 chains0 eng'
                         , Either ( (r == i) = False, rarc_5_6_5__nth i (nchains (enet eng')) = Just (MkChain nodes acts actions) )
                                  ( (r == i) = True, (j ** a ** ( rarc_5_6_5__nth j acts = Just a, afired a = False
                                                                , rarc_5_6_5__nth i (nchains (enet eng')) = Just (MkChain nodes (idat_6_2_2__mark_acts j acts) actions) )) ) )
ltim_2_5_1__step_frame alphas0 chains0 life eng inv i nodes acts actions fr n r eng' fe =
  let (j ** ch ** a ** (sel, nr, nj, eq)) = iret_11_4__fire_net_just life eng r eng' fe
      (ch0 ** n0) = lcyc_1_1__nth_length r chains0 (nchains (enet eng)) (fst (snd (snd inv))) nr
      (_, acEq) = snd (snd (snd inv)) r ch0 ch n0 nr
      sub = the ((act : Lgra_10_1__action) -> Elem act (cactions ch) -> Elem act (cactions ch0))
              (\act, e => replace {p = \z => Elem act z} acEq e)
      bk = rlow_5_1__bound_kinds alphas0 chains0 eng inv r ch0 ch n0 nr a (lcyc_1_1__nth_elem j (cacts ch) nj)
      nw = the ((k : Nat) -> Elem k (ltim_2_5_1__writes alphas0 ch0) -> rarc_5_6_5__elem k (ltim_2_5_1__reads alphas0 nodes) = False)
             (\k, ek => ltim_2_5_1__framed_rule alphas0 chains0 nodes ch0 fr (lcyc_1_1__nth_elem r chains0 n0) k ek)
      inv1 = idat_6_2_2__mark_net_inv alphas0 chains0 r j eng inv
  in case decEq r i of
       No ne =>
         let n1 = the (rarc_5_6_5__nth i (nchains (enet (idat_6_2_2__mark_net r j eng))) = Just (MkChain nodes acts actions))
                    (trans (lcyc_1_1__nth_set_at_neq r i ne (idat_6_2_2__mark_chain j) (nchains (enet eng))) n)
             (inv2, n2) = rarc_5_6_7__do_actions_frame alphas0 chains0 life (atuple a) ch0 bk (cactions ch) sub (idat_6_2_2__mark_net r j eng) inv1 i (MkChain nodes acts actions) n1 nw
         in ( replace {p = Ltim_2_5_1__frame_inv alphas0 chains0} (sym eq) inv2
            , Left (lcyc_1_1__nat_eq_false r i ne, replace {p = \z => rarc_5_6_5__nth i (nchains (enet z)) = Just (MkChain nodes acts actions)} (sym eq) n2) )
       Yes e =>
         let nri = the (rarc_5_6_5__nth i (nchains (enet eng)) = Just ch) (replace {p = \z => rarc_5_6_5__nth z (nchains (enet eng)) = Just ch} e nr)
             chEq = the (ch = MkChain nodes acts actions) (iret_11_4__just_inj (trans (sym nri) n))
             (ch' ** a' ** (nr', nj', nf')) = iret_11_1__select_just (nchains (enet eng)) r j sel
             chEq' = the (ch' = ch) (iret_11_4__just_inj (trans (sym nr') nr))
             nj'' = the (rarc_5_6_5__nth j (cacts ch) = Just a') (replace {p = \z => rarc_5_6_5__nth j (cacts z) = Just a'} chEq' nj')
             aEq = the (a' = a) (iret_11_4__just_inj (trans (sym nj'') nj))
             nja = the (rarc_5_6_5__nth j acts = Just a) (replace {p = \z => rarc_5_6_5__nth j (cacts z) = Just a} chEq nj)
             nfa = the (afired a = False) (replace {p = \z => afired z = False} aEq nf')
             n1 = the (rarc_5_6_5__nth i (nchains (enet (idat_6_2_2__mark_net r j eng))) = Just (MkChain nodes (idat_6_2_2__mark_acts j acts) actions))
                    (trans (replace {p = \z => rarc_5_6_5__nth z (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) (nchains (enet eng))) = map (idat_6_2_2__mark_chain j) (rarc_5_6_5__nth z (nchains (enet eng)))} e
                              (lcyc_1_1__nth_set_at_eq r (idat_6_2_2__mark_chain j) (nchains (enet eng))))
                           (cong (map (idat_6_2_2__mark_chain j)) n))
             (inv2, n2) = rarc_5_6_7__do_actions_frame alphas0 chains0 life (atuple a) ch0 bk (cactions ch) sub (idat_6_2_2__mark_net r j eng) inv1 i (MkChain nodes (idat_6_2_2__mark_acts j acts) actions) n1 nw
         in ( replace {p = Ltim_2_5_1__frame_inv alphas0 chains0} (sym eq) inv2
            , Right ( replace {p = \z => (z == i) = True} (sym e) (lcyc_1_1__nat_eq_refl i)
                    , (j ** a ** (nja, nfa, replace {p = \z => rarc_5_6_5__nth i (nchains (enet z)) = Just (MkChain nodes (idat_6_2_2__mark_acts j acts) actions)} (sym eq) n2)) ) )

-- ---------------------------------------------------------------------
-- The run under the frame
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
--@derives [IRET.11.5]
--@derives [LTIM.2.5.1]
--@derives [LDET.5.3]
||| THE RUN UNDER THE FRAME: over any fuel, from any state with the
||| invariant, a framed chain's tuples never change, its firings in the
||| trace are exactly its activations that went from unfired to fired, and
||| if the run halts `Quiescent` every one of them fired. Whatever the
||| other rules do, however the run halts.
export
ltim_2_5_1__run_frame : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) ->
                        Ltim_2_5_1__frame_inv alphas0 chains0 eng ->
                        (i : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                        ltim_2_5_1__framed alphas0 chains0 nodes = True ->
                        rarc_5_6_5__nth i (nchains (enet eng)) = Just (MkChain nodes acts actions) ->
                        (eng' ** h ** tr ** acts' ** ( iret_11_4__run_net_traced life fuel eng = (eng', h, tr)
                                                     , Ltim_2_5_1__frame_inv alphas0 chains0 eng'
                                                     , rarc_5_6_5__nth i (nchains (enet eng')) = Just (MkChain nodes acts' actions)
                                                     , iret_8_1__tuples acts' = iret_8_1__tuples acts
                                                     , iret_11_4__unfired acts' + ltim_2_5_1__count i tr = iret_11_4__unfired acts
                                                     , h = Quiescent -> iret_11_4__unfired acts' = 0 ))
ltim_2_5_1__run_frame alphas0 chains0 life Z eng inv i nodes acts actions fr n =
  (eng ** FuelOut ** [] ** acts ** (Refl, inv, n, Refl, plusZeroRightNeutral _, \q => absurd q))
ltim_2_5_1__run_frame alphas0 chains0 life (S fuel) eng inv i nodes acts actions fr n with (iret_11_4__fire_net life eng) proof fe
  ltim_2_5_1__run_frame alphas0 chains0 life (S fuel) eng inv i nodes acts actions fr n | Nothing =
    let stepNothing = the (iret_11_4__step_net life eng = Nothing) (trans (sym (iret_11_4__fire_net_step life eng)) (cong (map snd) fe))
        z = iret_11_1__unfired_count_zero_at (nchains (enet eng))
              (iret_11_1__select_nothing (nchains (enet eng)) (iret_11_4__step_net_nothing_select life eng stepNothing)) i (MkChain nodes acts actions) n
    in (eng ** Quiescent ** [] ** acts ** (Refl, inv, n, Refl, plusZeroRightNeutral _, \_ => z))
  ltim_2_5_1__run_frame alphas0 chains0 life (S fuel) eng inv i nodes acts actions fr n | (Just (r, eng1)) =
    case ltim_2_5_1__step_frame alphas0 chains0 life eng inv i nodes acts actions fr n r eng1 fe of
      (inv1, Left (rneq, n1)) =>
        let (eng' ** h ** tr ** acts' ** (rt, inv', n', tu, cnt, qz)) = ltim_2_5_1__run_frame alphas0 chains0 life fuel eng1 inv1 i nodes acts actions fr n1
        in (eng' ** h ** (r :: tr) ** acts' **
             ( rewrite rt in Refl
             , inv', n', tu
             , replace {p = \z => iret_11_4__unfired acts' + z = iret_11_4__unfired acts} (sym (ltim_2_5_1__count_miss i r tr rneq)) cnt
             , qz ))
      (inv1, Right (req, (j ** a ** (nj, nf, n1)))) =>
        let (eng' ** h ** tr ** acts' ** (rt, inv', n', tu, cnt, qz)) = ltim_2_5_1__run_frame alphas0 chains0 life fuel eng1 inv1 i nodes (idat_6_2_2__mark_acts j acts) actions fr n1
            mc = the (S (iret_11_4__unfired (idat_6_2_2__mark_acts j acts)) = iret_11_4__unfired acts) (idat_6_2_2__mark_acts_count j acts a nj nf)
        in (eng' ** h ** (r :: tr) ** acts' **
             ( rewrite rt in Refl
             , inv', n'
             , trans tu (idat_6_2_2__mark_tuples j acts)
             , trans (cong (iret_11_4__unfired acts' +) (ltim_2_5_1__count_hit i r tr req))
                     (trans (sym (plusSuccRightSucc (iret_11_4__unfired acts') (ltim_2_5_1__count i tr)))
                            (trans (cong S cnt) mc))
             , qz ))

-- ---------------------------------------------------------------------
-- THE THEOREM
-- ---------------------------------------------------------------------

--@derives [IRET.11.3]
--@derives [IRET.7.7]
--@derives [IRET.11.1]
--@derives [LDET.5.3]
--@derives [LTIM.2.5.1]
--@derives [RDSC.4a.5]
||| ONCE PER MATCH UNDER THE GENERAL FRAME. From the loaded network, after
||| any inputs applied with no pump between them, a pump that reaches
||| quiescence fires a framed chain exactly as many times as it has
||| matches when the pump begins: its activations are its distinct
||| matches ([IRET.7.7], [IRET.11.1], in the view), each fires once and
||| none twice ([IRET.11.3], [LDET.5.3], in the run), whatever the other
||| rules emit and withdraw meanwhile. Rete/NetworkOnce.idr's theorem with
||| the action-free frame replaced by this one.
export
iret_11_3__framed_fires_once_per_match : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                         (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                         (i : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                         ltim_2_5_1__framed (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) nodes = True ->
                                         rarc_5_6_5__nth i (nchains (enet (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)))) = Just (MkChain nodes acts actions) ->
                                         (eng' : Iret_19__engine) -> (h : Iret_11_4__halt) -> (tr : List Nat) ->
                                         iret_11_4__run_net_traced life fuel (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)) = (eng', h, tr) ->
                                         h = Quiescent ->
                                         ltim_2_5_1__count i tr
                                           = length (iret_7_7__view (nalphas (enet (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules))))
                                                                    (ewm (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules))) nodes [[]])
iret_11_3__framed_fires_once_per_match life fuel evs alphas rules i nodes acts actions fr n eng' h tr rt hq =
  let inv0 = the (Ltim_2_5_1__frame_inv (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)))
               (rarc_5_6_4__applied_inv _ _ life evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_view alphas rules, rlow_4_2_1__shapes_kept_refl (rdsc_4a_5__load alphas rules)))
      v = the (Iret_19__view (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules))) (fst inv0)
      (e1 ** h1 ** tr1 ** acts' ** (rt1, _, _, _, cnt, qz)) = ltim_2_5_1__run_frame _ _ life fuel (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)) inv0 i nodes acts actions fr n
      same = the ((e1, h1, tr1) = (eng', h, tr)) (trans (sym rt1) rt)
      trEq = the (tr1 = tr) (cong (\z => snd (snd z)) same)
      hEq = the (h1 = h) (cong (\z => fst (snd z)) same)
      zero = the (iret_11_4__unfired acts' = 0) (qz (trans hEq hq))
      cntTr = the (ltim_2_5_1__count i tr = iret_11_4__unfired acts)
                (trans (cong (ltim_2_5_1__count i) (sym trEq)) (trans (sym (plusZeroLeftNeutral _)) (trans (cong (\z => z + ltim_2_5_1__count i tr1) (sym zero)) cnt)))
      allUnfired = the ((a : Iret_8_1__act) -> Elem a acts -> afired a = False)
                     (lcyc_1_1__all_lookup (iret_11_3__applied_unfired life evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_view alphas rules) (rdsc_4a_5__load_unfired alphas rules))
                        (lcyc_1_1__nth_elem i (nchains (enet (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)))) n))
      (ss, dt) = snd (rarc_5_6_5__view_recomputed (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)) v) (MkChain nodes acts actions)
                   (lcyc_1_1__nth_elem i (nchains (enet (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)))) n)
      lenView = the (length (iret_8_1__tuples acts) = length (iret_7_7__view (nalphas (enet (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)))) (ewm (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules))) nodes [[]]))
                  (iret_11_3__distinct_same_set_length _ _ dt
                     (rarc_5_6_5__view_distinct _ _ (fst v) nodes [[]] (DCons (\e => absurd e) DNil)) ss)
  in trans cntTr (trans (iret_11_4__unfired_is_length acts allUnfired) (trans (sym (lengthMap acts)) lenView))

-- ---------------------------------------------------------------------
-- Executed: two rules, one framed and one not
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
||| A's RHS: emit a kind-1 fact.
public export
ltim_2_5_1__emit_one : List Lgra_10_1__action
ltim_2_5_1__emit_one = [Emit 1 (\b => (0, 0))]

--@spec [LTIM.2.5.1]
||| B's RHS: emit a kind-2 fact and withdraw its own kind-1 fact.
public export
ltim_2_5_1__emit_two_withdraw : List Lgra_10_1__action
ltim_2_5_1__emit_two_withdraw = [Emit 2 (\b => (0, 0)), Withdraw 0]

--@spec [LTIM.2.5.1]
||| THE PROGRAM: three schemas; rule A reads kind 0 and emits kind 1; rule
||| B reads kind 1, emits kind 2 and withdraws its own fact. A is framed:
||| nothing writes kind 0. B is not: A writes what B reads.
public export
ltim_2_5_1__two_rules : Iret_19__engine
ltim_2_5_1__two_rules =
  rdsc_4a_5__load [(0, \_ => True), (1, \_ => True), (2, \_ => True)]
    [ ([(0, iret_7_7__row, False)], ltim_2_5_1__emit_one)
    , ([(1, iret_7_7__row, False)], ltim_2_5_1__emit_two_withdraw) ]

--@spec [LTIM.2.5.1]
||| THE INPUTS: two kind-0 facts, with no pump between them.
public export
ltim_2_5_1__two_inputs : List Rarc_5_6_1__event
ltim_2_5_1__two_inputs = [Assert 0 1 0, Assert 0 2 0]

--@spec [IRET.11.4]
||| What a traced run shows: its trace and its halt.
public export
iret_11_4__trace_of : (Iret_19__engine, Iret_11_4__halt, List Nat) -> (List Nat, Iret_11_4__halt)
iret_11_4__trace_of (e, h, tr) = (tr, h)

--@derives [LTIM.2.5.1]
||| A IS FRAMED: computed.
export
ltim_2_5_1__a_is_framed : ltim_2_5_1__framed (nalphas (enet ltim_2_5_1__two_rules)) (nchains (enet ltim_2_5_1__two_rules)) [MkBeta 0 iret_7_7__row False [[]] []] = True
ltim_2_5_1__a_is_framed = Refl

--@derives [LTIM.2.5.1]
||| B IS NOT: A writes kind 1, which B reads. Computed.
export
ltim_2_5_1__b_is_not_framed : ltim_2_5_1__framed (nalphas (enet ltim_2_5_1__two_rules)) (nchains (enet ltim_2_5_1__two_rules)) [MkBeta 1 iret_7_7__row False [[]] []] = False
ltim_2_5_1__b_is_not_framed = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
--@derives [IRET.11.4]
||| THE TRACE: A fires for its first match, emitting a kind-1 fact that
||| gives B a match; A fires for its second; then B fires twice, each time
||| emitting and withdrawing its own fact. `[0, 0, 1, 1]`, quiescent. A
||| fired twice for its two matches while B's RHS wrote between. Executed.
export
ltim_2_5_1__two_rules_trace :
  iret_11_4__trace_of (iret_11_4__run_net_traced (\_ => Explicit) 10 (rarc_5_6_4__applied (\_ => Explicit) ltim_2_5_1__two_inputs ltim_2_5_1__two_rules))
    = ([0, 0, 1, 1], Quiescent)
ltim_2_5_1__two_rules_trace = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
||| THE THEOREM AT THE FIXTURE: every hypothesis discharged by computation
||| -- the frame, the chain as the inputs left it, the run, the halt -- and
||| the count of A's firings is the number of its matches, 2. Executed.
export
ltim_2_5_1__two_rules_is_an_instance :
  ltim_2_5_1__count 0 [0, 0, 1, 1]
    = length (iret_7_7__view (nalphas (enet (rarc_5_6_4__applied (\_ => Explicit) ltim_2_5_1__two_inputs ltim_2_5_1__two_rules)))
                             (ewm (rarc_5_6_4__applied (\_ => Explicit) ltim_2_5_1__two_inputs ltim_2_5_1__two_rules))
                             [MkBeta 0 iret_7_7__row False [[]] []] [[]])
ltim_2_5_1__two_rules_is_an_instance =
  iret_11_3__framed_fires_once_per_match (\_ => Explicit) 10 ltim_2_5_1__two_inputs
    [(0, \_ => True), (1, \_ => True), (2, \_ => True)]
    [ ([(0, iret_7_7__row, False)], ltim_2_5_1__emit_one), ([(1, iret_7_7__row, False)], ltim_2_5_1__emit_two_withdraw) ]
    0 [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] False, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one
    Refl Refl _ _ _ Refl Refl

--@derives [LTIM.2.5.1]
||| And the number is two: A had two matches when the pump began and fired
||| twice. Computed.
export
ltim_2_5_1__two_rules_fires_twice :
  ( ltim_2_5_1__count 0 [0, 0, 1, 1]
  , length (iret_7_7__view (nalphas (enet (rarc_5_6_4__applied (\_ => Explicit) ltim_2_5_1__two_inputs ltim_2_5_1__two_rules)))
                           (ewm (rarc_5_6_4__applied (\_ => Explicit) ltim_2_5_1__two_inputs ltim_2_5_1__two_rules))
                           [MkBeta 0 iret_7_7__row False [[]] []] [[]]) ) = (2, 2)
ltim_2_5_1__two_rules_fires_twice = Refl

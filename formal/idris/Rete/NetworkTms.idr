-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| TRUTH MAINTENANCE ON THE NETWORK. The dependency table of [IRET.12.4]
||| and the justification bookkeeping of [IRET.12.1] / [IRET.12.2],
||| layered on the network engine of Rete/Network.idr exactly as
||| Rete/FireLoopTms.idr layers them on Rete/FireLoop.idr: a row per
||| (rule, token identity, logical fact); an activation live while its
||| terminal holds it, fired ([IRET.7.8]; a terminal holds unblocked
||| matches only, so a `no` pattern broken ends it, [LLOG.11.5]); a phase
||| that drops the rows of ended activations, retracts the facts they
||| alone supported, and propagates -- here one fact at a time through
||| alpha dispatch ([IRET.19.2]), as the reference engine does -- iterated
||| to its fixpoint.
|||
||| WHAT IS PROVED HERE: the row-level agreement. Under the agreement of
||| Rete/NetworkTransferAgree.idr an activation is live on the network
||| exactly when it is live on FireLoop, so the two sides end, keep and
||| zero the same rows; retracting the zeroed ids one at a time on the
||| network and once on FireLoop keeps the agreement
||| (Rete/NetworkTmsCascade.idr); so one phase agrees, and the cascade.
||| Rete/NetworkTmsTransfer.idr carries this through actions, firings,
||| runs, inputs and histories.
module Rete.NetworkTms

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
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
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.List.Elem
import Data.List.Quantifiers

%default total

-- ---------------------------------------------------------------------
-- The network engine with truth maintenance
-- ---------------------------------------------------------------------

--@spec [IRET.12]
--@spec [IRET.12.4]
||| The network engine and the dependency table.
public export
record Iret_12__net_state where
  constructor MkTmsNet
  ncore : Iret_19__engine
  ndeps : Iret_12_4__table

--@spec [IRET.11]
||| The activations of the chain at an ordinal; none past the chains.
public export
iret_11__chain_acts_at : Nat -> List Rlow_4_2_1__chain -> List Iret_8_1__act
iret_11__chain_acts_at _     []        = []
iret_11__chain_acts_at Z     (c :: cs) = cacts c
iret_11__chain_acts_at (S r) (c :: cs) = iret_11__chain_acts_at r cs

--@spec [IRET.7.8]
--@spec [LLOG.11.5]
||| An activation is live on the network while its rule's terminal holds
||| an activation of its identity that has fired. The terminal holds
||| unblocked matches only, so a match a `no` pattern now blocks has
||| ended, as on FireLoop's side.
public export
iret_7_8__activation_live_net : List Rlow_4_2_1__chain -> Iret_12_4__row -> Bool
iret_7_8__activation_live_net cs row =
  rarc_5_6_5__any (\a => (iret_11_3__fact_ids (atuple a) == rids row) && afired a) (iret_11__chain_acts_at (rrule row) cs)

--@spec [IRET.12.2]
||| The rows whose activation has ended, or whose target is no longer
||| live.
public export
iret_12_2__ended_net : Iret_19__engine -> Iret_12_4__table -> Iret_12_4__table
iret_12_2__ended_net eng =
  filter (\row => not (iret_7_8__activation_live_net (nchains (enet eng)) row && rarc_5_6_4__is_live (rtarget row) (ewm eng)))

--@spec [IRET.12.2]
public export
iret_12_2__kept_net : Iret_19__engine -> Iret_12_4__table -> Iret_12_4__table
iret_12_2__kept_net eng =
  filter (\row => iret_7_8__activation_live_net (nchains (enet eng)) row && rarc_5_6_4__is_live (rtarget row) (ewm eng))

--@spec [IRET.12.2]
--@spec [IRET.19.2]
||| Retract the facts with those ids, one at a time through alpha
||| dispatch; an id no live fact carries is skipped.
public export
iret_12_2__retract_ids_net : List Nat -> Iret_19__engine -> Iret_19__engine
iret_12_2__retract_ids_net [] eng = eng
iret_12_2__retract_ids_net (i :: is) eng = case rarc_5_6_4__lookup_fact i (ewm eng) of
  Nothing => iret_12_2__retract_ids_net is eng
  Just f  => iret_12_2__retract_ids_net is (iret_19_2__retract f eng)

--@spec [IRET.12.2]
||| One phase: drop the rows of ended activations, retract what they
||| alone supported. A phase that ends nothing touches nothing.
public export
iret_12_2__phase_step_net : Lcyc_3_2_1__program -> Iret_12__net_state -> Iret_12__net_state
iret_12_2__phase_step_net pg (MkTmsNet eng rows) =
  case iret_12_2__ended_net eng rows of
    [] => MkTmsNet eng rows
    ended => MkTmsNet (iret_12_2__retract_ids_net (iret_12_2__zeroed ended (iret_12_2__kept_net eng rows)) eng) (iret_12_2__kept_net eng rows)

--@spec [IRET.12.2]
public export
iret_12_2__phase_n_net : Nat -> Lcyc_3_2_1__program -> Iret_12__net_state -> Iret_12__net_state
iret_12_2__phase_n_net Z pg s = s
iret_12_2__phase_n_net (S n) pg s = case iret_12_2__phase_step_net pg s of
  MkTmsNet eng rows => iret_12_2__phase_n_net n pg (MkTmsNet eng rows)

--@spec [IRET.12.2]
||| The cascade to its fixpoint, with FireLoop's fuel: one more than the
||| number of rows.
public export
iret_12_2__phase_net : Lcyc_3_2_1__program -> Iret_12__net_state -> Iret_12__net_state
iret_12_2__phase_net pg s = iret_12_2__phase_n_net (S (length (ndeps s))) pg s

-- ---------------------------------------------------------------------
-- Liveness agrees
-- ---------------------------------------------------------------------

--@derives [RLOW.4.2.1]
--@derives [IRET.11]
||| Under the tables' agreement, the unblocked tokens of the table at an
||| ordinal are the activations of the chain at it.
export
rlow_4_2_1__tables_agree_at : (tss : List (List Iret_11__tok)) -> (cs : List Rlow_4_2_1__chain) -> Rlow_4_2_1__tables_agree tss cs -> (r : Nat) ->
                              iret_11_3_1__unblocked_acts (iret_11__table_at r tss) = iret_11__chain_acts_at r cs
rlow_4_2_1__tables_agree_at [] [] TANil r = Refl
rlow_4_2_1__tables_agree_at (ts :: tss) (c :: cs) (TACons eq rest) Z = eq
rlow_4_2_1__tables_agree_at (ts :: tss) (c :: cs) (TACons eq rest) (S r) = rlow_4_2_1__tables_agree_at tss cs rest r

--@derives [IRET.11.3.1]
||| A test over the unblocked activations is the test over the tokens,
||| unblocked and read as activations.
export
iret_11_3_1__any_unblocked : (q : Iret_8_1__act -> Bool) -> (ts : List Iret_11__tok) ->
                             rarc_5_6_5__any q (iret_11_3_1__unblocked_acts ts) = rarc_5_6_5__any (\t => not (blocked t) && q (iret_11__to_act t)) ts
iret_11_3_1__any_unblocked q [] = Refl
iret_11_3_1__any_unblocked q (t :: ts) =
  case iret_12__bool_split (blocked t) of
    Left bt  => rewrite bt in iret_11_3_1__any_unblocked q ts
    Right bf => rewrite bf in
                case iret_12__bool_split (q (iret_11__to_act t)) of
                  Left qt  => rewrite qt in Refl
                  Right qf => rewrite qf in iret_11_3_1__any_unblocked q ts

--@derives [IRET.12]
||| The token's liveness test, rearranged as the activation's.
export
iret_12__live_test_rot : (b, x, f : Bool) -> (not b && (x && f)) = (x && (f && not b))
iret_12__live_test_rot True  True  True  = Refl
iret_12__live_test_rot True  True  False = Refl
iret_12__live_test_rot True  False True  = Refl
iret_12__live_test_rot True  False False = Refl
iret_12__live_test_rot False True  True  = Refl
iret_12__live_test_rot False True  False = Refl
iret_12__live_test_rot False False True  = Refl
iret_12__live_test_rot False False False = Refl

--@derives [IRET.7.8]
--@derives [RLOW.4.2.1]
||| AN ACTIVATION IS LIVE ON THE NETWORK exactly when it is live on
||| FireLoop: under the tables' agreement the terminal's fired
||| activation of the row's identity is the table's fired, unblocked
||| token of it.
export
iret_7_8__activation_live_agree : (tss : List (List Iret_11__tok)) -> (cs : List Rlow_4_2_1__chain) -> Rlow_4_2_1__tables_agree tss cs ->
                                  (row : Iret_12_4__row) -> iret_7_8__activation_live_net cs row = iret_7_8__activation_live tss row
iret_7_8__activation_live_agree tss cs ta row =
  trans (cong (rarc_5_6_5__any (\a => (iret_11_3__fact_ids (atuple a) == rids row) && afired a)) (sym (rlow_4_2_1__tables_agree_at tss cs ta (rrule row))))
        (trans (iret_11_3_1__any_unblocked (\a => (iret_11_3__fact_ids (atuple a) == rids row) && afired a) (iret_11__table_at (rrule row) tss))
               (iret_7_9__any_ext (\t => not (blocked t) && ((iret_11_3__ids t == rids row) && fired t))
                                  (\t => (iret_11_3__ids t == rids row) && (fired t && not (blocked t)))
                                  (iret_11__table_at (rrule row) tss)
                                  (\t, _ => iret_12__live_test_rot (blocked t) (iret_11_3__ids t == rids row) (fired t))))

--@derives [IRET.12.2]
||| The rows that ended agree.
export
iret_12_2__ended_agree : (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> Rlow_4_2_1__tables_agree toks (nchains net) ->
                         (rows : Iret_12_4__table) -> iret_12_2__ended_net (MkEngine wm net) rows = iret_12_2__ended (MkState wm toks) rows
iret_12_2__ended_agree wm net toks ta rows =
  lcyc_1_1__filter_ext (\row => not (iret_7_8__activation_live_net (nchains net) row && rarc_5_6_4__is_live (rtarget row) wm))
                       (\row => not (iret_7_8__activation_live toks row && rarc_5_6_4__is_live (rtarget row) wm))
                       (\row => cong (\l => not (l && rarc_5_6_4__is_live (rtarget row) wm)) (iret_7_8__activation_live_agree toks (nchains net) ta row))
                       rows

--@derives [IRET.12.2]
||| The rows kept agree.
export
iret_12_2__kept_agree : (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> Rlow_4_2_1__tables_agree toks (nchains net) ->
                        (rows : Iret_12_4__table) -> iret_12_2__kept_net (MkEngine wm net) rows = iret_12_2__kept (MkState wm toks) rows
iret_12_2__kept_agree wm net toks ta rows =
  lcyc_1_1__filter_ext (\row => iret_7_8__activation_live_net (nchains net) row && rarc_5_6_4__is_live (rtarget row) wm)
                       (\row => iret_7_8__activation_live toks row && rarc_5_6_4__is_live (rtarget row) wm)
                       (\row => cong (\l => l && rarc_5_6_4__is_live (rtarget row) wm) (iret_7_8__activation_live_agree toks (nchains net) ta row))
                       rows

-- ---------------------------------------------------------------------
-- Retracting the zeroed ids agrees
-- ---------------------------------------------------------------------

--@derives [IRET.19]
||| An engine is its working memory and its network.
export
iret_19__engine_eta : (e : Iret_19__engine) -> MkEngine (ewm e) (enet e) = e
iret_19__engine_eta (MkEngine w n) = Refl

--@derives [IRET.12.2]
--@derives [IRET.4.4]
||| Retracting ids one at a time leaves the working memory the batch
||| leaves, under unique ids.
export
iret_12_2__retract_ids_net_wm : (ids : List Nat) -> (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (net : Rarc_5_3_1__network) ->
                                ewm (iret_12_2__retract_ids_net ids (MkEngine wm net)) = iret_12_2__retract_ids ids wm
iret_12_2__retract_ids_net_wm [] wm uq net = sym (iret_12_2__retract_ids_nil wm)
iret_12_2__retract_ids_net_wm (i :: is) wm uq net with (rarc_5_6_4__lookup_fact i wm) proof lk
  iret_12_2__retract_ids_net_wm (i :: is) wm uq net | Nothing =
    trans (iret_12_2__retract_ids_net_wm is wm uq net) (sym (iret_12_2__retract_ids_cons_dead wm i is lk))
  iret_12_2__retract_ids_net_wm (i :: is) wm uq net | (Just f) =
    trans (iret_12_2__retract_ids_net_wm is (rarc_5_6_4__remove_exact f wm) (iret_4_4__unique_filter wm uq (\g => not (lfac_2_5_4__same_fact g f)))
                                          (enet (iret_19_2__retract f (MkEngine wm net))))
          (sym (iret_12_2__retract_ids_cons_live wm uq i is f lk))

--@derives [RLOW.4.2.1]
--@derives [IRET.12.2]
||| RETRACTING A BATCH OF IDS keeps the agreement: one at a time through
||| alpha dispatch on the network, as a batch with one propagation on
||| FireLoop. Each network retraction keeps the agreement against one
||| more FireLoop propagation, and those propagations compose into the
||| batch's one; an id no live fact carries retracts nothing on either
||| side.
export
rlow_4_2_1__retract_ids_agree : (pg : Lcyc_3_2_1__program) -> (ids : List Nat) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                                Rlow_4_2_1__agree pg wm net toks ->
                                Rlow_4_2_1__agree pg (iret_12_2__retract_ids ids wm) (enet (iret_12_2__retract_ids_net ids (MkEngine wm net)))
                                                     (rarc_5_6_5__propagate pg (iret_12_2__retract_ids ids wm) toks)
rlow_4_2_1__retract_ids_agree pg [] wm net toks ag =
  let (ra, ta, ord, (dw, uq, tw)) = ag
  in replace {p = \w => Rlow_4_2_1__agree pg w net (rarc_5_6_5__propagate pg w toks)} (sym (iret_12_2__retract_ids_nil wm))
       (replace {p = \z => Rlow_4_2_1__agree pg wm net z} (sym (rarc_5_6_5__propagate_settled_id pg wm toks tw)) ag)
rlow_4_2_1__retract_ids_agree pg (i :: is) wm net toks ag with (rarc_5_6_4__lookup_fact i wm) proof lk
  rlow_4_2_1__retract_ids_agree pg (i :: is) wm net toks ag | Nothing =
    replace {p = \w => Rlow_4_2_1__agree pg w (enet (iret_12_2__retract_ids_net is (MkEngine wm net))) (rarc_5_6_5__propagate pg w toks)}
            (sym (iret_12_2__retract_ids_cons_dead wm i is lk))
            (rlow_4_2_1__retract_ids_agree pg is wm net toks ag)
  rlow_4_2_1__retract_ids_agree pg (i :: is) wm net toks ag | (Just f) =
    let (ra, ta, ord, (dw, uq, tw)) = ag
    in let ef : Elem f wm
           ef = fst (rarc_5_6_4__lookup_elem i wm f lk)
           ag1 : Rlow_4_2_1__agree pg (rarc_5_6_4__remove_exact f wm) (enet (iret_19_2__retract f (MkEngine wm net)))
                                      (rarc_5_6_5__propagate pg (rarc_5_6_4__remove_exact f wm) toks)
           ag1 = rlow_4_2_1__retract_agree pg wm net toks ag f ef
           ih : Rlow_4_2_1__agree pg (iret_12_2__retract_ids is (rarc_5_6_4__remove_exact f wm))
                                     (enet (iret_12_2__retract_ids_net is (iret_19_2__retract f (MkEngine wm net))))
                                     (rarc_5_6_5__propagate pg (iret_12_2__retract_ids is (rarc_5_6_4__remove_exact f wm)) (rarc_5_6_5__propagate pg (rarc_5_6_4__remove_exact f wm) toks))
           ih = rlow_4_2_1__retract_ids_agree pg is (rarc_5_6_4__remove_exact f wm) (enet (iret_19_2__retract f (MkEngine wm net)))
                  (rarc_5_6_5__propagate pg (rarc_5_6_4__remove_exact f wm) toks) ag1
           comp : (rarc_5_6_5__propagate pg (iret_12_2__retract_ids is (rarc_5_6_4__remove_exact f wm)) (rarc_5_6_5__propagate pg (rarc_5_6_4__remove_exact f wm) toks)
                   = rarc_5_6_5__propagate pg (iret_12_2__retract_ids is (rarc_5_6_4__remove_exact f wm)) toks)
           comp = rarc_5_6_5__propagate_shrink_compose pg wm (rarc_5_6_4__remove_exact f wm) (iret_12_2__retract_ids is (rarc_5_6_4__remove_exact f wm))
                    (\g, e => fst (rarc_5_6_4__remove_exact_elem_inv f wm g e))
                    (\g, e => fst (lcyc_1_1__elem_filter_inv (\h => not (rarc_5_6_5__elem (fid h) is)) (rarc_5_6_4__remove_exact f wm) e))
                    toks tw
       in replace {p = \w => Rlow_4_2_1__agree pg w (enet (iret_12_2__retract_ids_net is (iret_19_2__retract f (MkEngine wm net)))) (rarc_5_6_5__propagate pg w toks)}
                  (sym (iret_12_2__retract_ids_cons_live wm uq i is f lk))
                  (replace {p = \z => Rlow_4_2_1__agree pg (iret_12_2__retract_ids is (rarc_5_6_4__remove_exact f wm)) (enet (iret_12_2__retract_ids_net is (iret_19_2__retract f (MkEngine wm net)))) z}
                           comp ih)

-- ---------------------------------------------------------------------
-- One phase agrees, and the cascade
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| A phase on the network that ends nothing is the identity.
export
iret_12_2__phase_step_net_nil : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                iret_12_2__ended_net eng rows = [] -> iret_12_2__phase_step_net pg (MkTmsNet eng rows) = MkTmsNet eng rows
iret_12_2__phase_step_net_nil pg eng rows h with (iret_12_2__ended_net eng rows)
  iret_12_2__phase_step_net_nil pg eng rows h | [] = Refl
  iret_12_2__phase_step_net_nil pg eng rows h | (x :: xs) = void (iret_12__cons_not_nil h)

--@derives [IRET.12.2]
||| A phase on the network that ends something keeps the live rows and
||| retracts what the ended ones alone supported.
export
iret_12_2__phase_step_net_cons : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (x : Iret_12_4__row) -> (xs : Iret_12_4__table) ->
                                 iret_12_2__ended_net eng rows = x :: xs ->
                                 iret_12_2__phase_step_net pg (MkTmsNet eng rows)
                                   = MkTmsNet (iret_12_2__retract_ids_net (iret_12_2__zeroed (iret_12_2__ended_net eng rows) (iret_12_2__kept_net eng rows)) eng) (iret_12_2__kept_net eng rows)
iret_12_2__phase_step_net_cons pg eng rows x xs h with (iret_12_2__ended_net eng rows)
  iret_12_2__phase_step_net_cons pg eng rows x xs h | [] = absurd h
  iret_12_2__phase_step_net_cons pg eng rows x xs h | (y :: ys) = Refl

--@derives [IRET.12.2]
||| A phase on FireLoop that ends something keeps the live rows and
||| retracts what the ended ones alone supported, as a batch.
export
iret_12_2__phase_step_cons : (pg : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             (x : Iret_12_4__row) -> (xs : Iret_12_4__table) -> iret_12_2__ended (MkState wm tables) rows = x :: xs ->
                             iret_12_2__phase_step pg (MkTms (MkState wm tables) rows)
                               = iret_12_2__phase_after pg wm tables (iret_12_2__kept (MkState wm tables) rows)
                                   (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows))
iret_12_2__phase_step_cons pg wm tables rows x xs h with (iret_12_2__ended (MkState wm tables) rows)
  iret_12_2__phase_step_cons pg wm tables rows x xs h | [] = absurd h
  iret_12_2__phase_step_cons pg wm tables rows x xs h | (y :: ys) = Refl

--@derives [IRET.12]
||| A list is empty or not.
export
iret_12__list_split : (xs : List a) -> Either (xs = []) (x ** xs' ** xs = x :: xs')
iret_12__list_split [] = Left Refl
iret_12__list_split (x :: xs) = Right (x ** xs ** Refl)

--@derives [RLOW.4.2.1]
--@derives [IRET.12.2]
||| ONE PHASE AGREES: the two sides end and keep the same rows, so they
||| retract the same ids -- the network one at a time, FireLoop as a
||| batch -- and agree after; a phase that ends nothing, or ends rows
||| that supported nothing alone, changes neither side.
export
rlow_4_2_1__phase_step_agree : (pg : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                               Rlow_4_2_1__agree pg wm net toks ->
                               (wm' ** net' ** toks' ** rows' ** ( iret_12_2__phase_step_net pg (MkTmsNet (MkEngine wm net) rows) = MkTmsNet (MkEngine wm' net') rows'
                                                                 , iret_12_2__phase_step pg (MkTms (MkState wm toks) rows) = MkTms (MkState wm' toks') rows'
                                                                 , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__phase_step_agree pg wm net toks rows ag =
  let (ra, ta, ord, (dw, uq, tw)) = ag
  in let endEq : (iret_12_2__ended_net (MkEngine wm net) rows = iret_12_2__ended (MkState wm toks) rows)
         endEq = iret_12_2__ended_agree wm net toks ta rows
         keptEq : (iret_12_2__kept_net (MkEngine wm net) rows = iret_12_2__kept (MkState wm toks) rows)
         keptEq = iret_12_2__kept_agree wm net toks ta rows
     in case iret_12__list_split (iret_12_2__ended (MkState wm toks) rows) of
          Left nil =>
            (wm ** net ** toks ** rows ** ( iret_12_2__phase_step_net_nil pg (MkEngine wm net) rows (trans endEq nil)
                                          , iret_12_2__phase_step_nil pg wm toks rows nil
                                          , ag ))
          Right (x ** xs ** cons) =>
            let netEq : (iret_12_2__phase_step_net pg (MkTmsNet (MkEngine wm net) rows)
                         = MkTmsNet (iret_12_2__retract_ids_net (iret_12_2__zeroed (iret_12_2__ended (MkState wm toks) rows) (iret_12_2__kept (MkState wm toks) rows)) (MkEngine wm net))
                                    (iret_12_2__kept (MkState wm toks) rows))
                netEq = replace {p = \k => iret_12_2__phase_step_net pg (MkTmsNet (MkEngine wm net) rows)
                                           = MkTmsNet (iret_12_2__retract_ids_net (iret_12_2__zeroed (iret_12_2__ended (MkState wm toks) rows) k) (MkEngine wm net)) k}
                                keptEq
                          (replace {p = \e => iret_12_2__phase_step_net pg (MkTmsNet (MkEngine wm net) rows)
                                              = MkTmsNet (iret_12_2__retract_ids_net (iret_12_2__zeroed e (iret_12_2__kept_net (MkEngine wm net) rows)) (MkEngine wm net)) (iret_12_2__kept_net (MkEngine wm net) rows)}
                                   endEq
                                   (iret_12_2__phase_step_net_cons pg (MkEngine wm net) rows x xs (trans endEq cons)))
                flEq : (iret_12_2__phase_step pg (MkTms (MkState wm toks) rows)
                        = iret_12_2__phase_after pg wm toks (iret_12_2__kept (MkState wm toks) rows)
                            (iret_12_2__zeroed (iret_12_2__ended (MkState wm toks) rows) (iret_12_2__kept (MkState wm toks) rows)))
                flEq = iret_12_2__phase_step_cons pg wm toks rows x xs cons
            in case iret_12__list_split (iret_12_2__zeroed (iret_12_2__ended (MkState wm toks) rows) (iret_12_2__kept (MkState wm toks) rows)) of
                 Left znil =>
                   (wm ** net ** toks ** iret_12_2__kept (MkState wm toks) rows **
                     ( trans netEq (cong (\z => MkTmsNet (iret_12_2__retract_ids_net z (MkEngine wm net)) (iret_12_2__kept (MkState wm toks) rows)) znil)
                     , trans flEq (cong (iret_12_2__phase_after pg wm toks (iret_12_2__kept (MkState wm toks) rows)) znil)
                     , ag ))
                 Right (g ** gs ** zcons) =>
                   let ag' : Rlow_4_2_1__agree pg (iret_12_2__retract_ids (g :: gs) wm) (enet (iret_12_2__retract_ids_net (g :: gs) (MkEngine wm net)))
                                                 (rarc_5_6_5__propagate pg (iret_12_2__retract_ids (g :: gs) wm) toks)
                       ag' = rlow_4_2_1__retract_ids_agree pg (g :: gs) wm net toks ag
                       engEq : (iret_12_2__retract_ids_net (g :: gs) (MkEngine wm net)
                                = MkEngine (iret_12_2__retract_ids (g :: gs) wm) (enet (iret_12_2__retract_ids_net (g :: gs) (MkEngine wm net))))
                       engEq = trans (sym (iret_19__engine_eta (iret_12_2__retract_ids_net (g :: gs) (MkEngine wm net))))
                                     (cong (\w => MkEngine w (enet (iret_12_2__retract_ids_net (g :: gs) (MkEngine wm net)))) (iret_12_2__retract_ids_net_wm (g :: gs) wm uq net))
                   in (iret_12_2__retract_ids (g :: gs) wm ** enet (iret_12_2__retract_ids_net (g :: gs) (MkEngine wm net))
                        ** rarc_5_6_5__propagate pg (iret_12_2__retract_ids (g :: gs) wm) toks ** iret_12_2__kept (MkState wm toks) rows **
                        ( trans netEq (trans (cong (\z => MkTmsNet (iret_12_2__retract_ids_net z (MkEngine wm net)) (iret_12_2__kept (MkState wm toks) rows)) zcons)
                                             (cong (\e => MkTmsNet e (iret_12_2__kept (MkState wm toks) rows)) engEq))
                        , trans flEq (cong (iret_12_2__phase_after pg wm toks (iret_12_2__kept (MkState wm toks) rows)) zcons)
                        , ag' ))

--@derives [IRET.12.2]
||| One more phase on the network, when the first is known.
export
iret_12_2__phase_n_net_succ : (n : Nat) -> (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                              iret_12_2__phase_step_net pg s = MkTmsNet eng rows -> iret_12_2__phase_n_net (S n) pg s = iret_12_2__phase_n_net n pg (MkTmsNet eng rows)
iret_12_2__phase_n_net_succ n pg s eng rows eq with (iret_12_2__phase_step_net pg s)
  iret_12_2__phase_n_net_succ n pg s eng rows eq | (MkTmsNet e r) = cong (iret_12_2__phase_n_net n pg) eq

--@derives [RLOW.4.2.1]
--@derives [IRET.12.2]
||| Any number of phases agree.
export
rlow_4_2_1__phase_n_agree : (n : Nat) -> (pg : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            Rlow_4_2_1__agree pg wm net toks ->
                            (wm' ** net' ** toks' ** rows' ** ( iret_12_2__phase_n_net n pg (MkTmsNet (MkEngine wm net) rows) = MkTmsNet (MkEngine wm' net') rows'
                                                              , iret_12_2__phase_n n pg (MkTms (MkState wm toks) rows) = MkTms (MkState wm' toks') rows'
                                                              , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__phase_n_agree Z pg wm net toks rows ag = (wm ** net ** toks ** rows ** (Refl, Refl, ag))
rlow_4_2_1__phase_n_agree (S n) pg wm net toks rows ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** (e1, f1, ag1)) = rlow_4_2_1__phase_step_agree pg wm net toks rows ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** (e2, f2, ag2)) = rlow_4_2_1__phase_n_agree n pg wm1 net1 toks1 rows1 ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** ( trans (iret_12_2__phase_n_net_succ n pg (MkTmsNet (MkEngine wm net) rows) (MkEngine wm1 net1) rows1 e1) e2
                                          , trans (iret_12_2__phase_n_succ n pg (MkTms (MkState wm toks) rows) (MkState wm1 toks1) rows1 f1) f2
                                          , ag2 ))

--@derives [RLOW.4.2.1]
--@derives [IRET.12.2]
||| THE CASCADE AGREES: with the same rows on both sides the fuel is the
||| same, and every phase agrees.
export
rlow_4_2_1__phase_agree : (pg : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                          Rlow_4_2_1__agree pg wm net toks ->
                          (wm' ** net' ** toks' ** rows' ** ( iret_12_2__phase_net pg (MkTmsNet (MkEngine wm net) rows) = MkTmsNet (MkEngine wm' net') rows'
                                                            , iret_12_2__phase pg (MkTms (MkState wm toks) rows) = MkTms (MkState wm' toks') rows'
                                                            , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__phase_agree pg wm net toks rows ag = rlow_4_2_1__phase_n_agree (S (length rows)) pg wm net toks rows ag

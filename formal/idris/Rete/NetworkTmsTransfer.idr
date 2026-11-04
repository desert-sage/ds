-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE TRANSFER WITH TRUTH MAINTENANCE. The network engine with the
||| dependency table (Rete/NetworkTms.idr) and Rete/FireLoopTms.idr's
||| engine, run on one history from the loaded network and the empty
||| state under the program the network lowers to, agree at every step:
||| one working memory, one dependency table, each table's unblocked
||| tokens the terminal's activations in order and with their flags.
||| Every action records the same row and cascades alike
||| ([IRET.10.2], [IRET.12.2]); selection and marking agree as in
||| Rete/NetworkTransfer.idr; an input is applied, propagated and
||| cascaded alike (RARC.5.6.4); a pump is the same firings
||| (RARC.5.6.6); a canonical replay -- each input pumped to
||| quiescence, [LFST.9.2.1] -- is canonical on both sides with the same
||| fuel. So Rete/TmsRun.idr, Lcyc/TmsTermination.idr and
||| Rete/PumpBoundary.idr, stated over FireLoopTms's run, hold of the
||| network: what they say of the tables they say of the terminals, and
||| what they say of the dependency table they say of the network's.
module Rete.NetworkTmsTransfer

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
import Rete.NetworkTms
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Rete.RunFold
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.List.Elem
import Data.List.Quantifiers

%default total

-- ---------------------------------------------------------------------
-- Dispatch and the loop, on the network
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.7]
||| One action: the network's dispatch, the justification it records,
||| then the cascade its retraction started, before the next action.
public export
rarc_5_6_7__do_action_tms_net : Lcyc_3_2_1__program -> Nat -> Iret_8_1__act -> Lgra_10_1__action -> Iret_12__net_state -> Iret_12__net_state
rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows) =
  case rarc_5_6_7__do_action_net (life pg) (atuple a) act eng of
    MkEngine wm' net' =>
      iret_12_2__phase_net pg (MkTmsNet (MkEngine wm' net') (iret_10_2__record pg r (iret_11_3__fact_ids (atuple a)) (atuple a) act wm' rows))

--@spec [RARC.5.6.7]
public export
rarc_5_6_7__do_actions_tms_net : Lcyc_3_2_1__program -> Nat -> Iret_8_1__act -> List Lgra_10_1__action -> Iret_12__net_state -> Iret_12__net_state
rarc_5_6_7__do_actions_tms_net pg r a [] s = s
rarc_5_6_7__do_actions_tms_net pg r a (act :: acts) s = case rarc_5_6_7__do_action_tms_net pg r a act s of
  MkTmsNet eng rows => rarc_5_6_7__do_actions_tms_net pg r a acts (MkTmsNet eng rows)

--@spec [IRET.11.4]
||| One firing with truth maintenance: the network's selection and
||| mark, then the RHS with the table and the cascade in the loop.
public export
iret_11_4__step_tms_net : Lcyc_3_2_1__program -> Iret_12__net_state -> Maybe Iret_12__net_state
iret_11_4__step_tms_net pg (MkTmsNet eng rows) = case iret_11_1__select (nchains (enet eng)) of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (nchains (enet eng)) of
    Nothing => Nothing
    Just c => case rarc_5_6_5__nth j (cacts c) of
      Nothing => Nothing
      Just a  => Just (rarc_5_6_7__do_actions_tms_net pg r a (cactions c) (MkTmsNet (idat_6_2_2__mark_net r j eng) rows))

--@spec [IRET.11.4]
--@spec [IRET.11.5]
public export
iret_11_4__run_tms_net : Lcyc_3_2_1__program -> Nat -> Iret_12__net_state -> (Iret_12__net_state, Iret_11_4__halt, Nat)
iret_11_4__run_tms_net pg Z s = (s, FuelOut, 0)
iret_11_4__run_tms_net pg (S fuel) s = case iret_11_4__step_tms_net pg s of
  Nothing => (s, Quiescent, 0)
  Just s' => let (t, h, n) = iret_11_4__run_tms_net pg fuel s' in (t, h, S n)

--@spec [RARC.5.6.4]
||| Apply the event to the network, propagate through it, and run the
||| cascade the ended activations demand; a no-op assert and a
||| retraction of an id not live touch nothing, as on FireLoop's side.
public export
rarc_5_6_4__apply_tms_net : Lcyc_3_2_1__program -> Rarc_5_6_1__event -> Iret_12__net_state -> Iret_12__net_state
rarc_5_6_4__apply_tms_net pg (Assert k key pay) (MkTmsNet eng rows) =
  case iret_19_1__assert_fact (life pg k) [] k key pay (ewm eng) of
    Nothing => MkTmsNet eng rows
    Just _  => iret_12_2__phase_net pg (MkTmsNet (iret_19_1__assert (life pg) [] k key pay eng) rows)
rarc_5_6_4__apply_tms_net pg (Retract i) (MkTmsNet eng rows) =
  case rarc_5_6_4__lookup_fact i (ewm eng) of
    Nothing => MkTmsNet eng rows
    Just f  => iret_12_2__phase_net pg (MkTmsNet (iret_19_2__retract f eng) rows)

--@spec [RARC.5.6.6]
public export
rarc_5_6_6__pump_tms_net : Lcyc_3_2_1__program -> Nat -> Iret_12__net_state -> (Iret_12__net_state, Iret_11_4__halt, Nat)
rarc_5_6_6__pump_tms_net pg fuel s = iret_11_4__run_tms_net pg fuel s

--@spec [LFST.9.2.1]
||| The canonical cadence on the network: one input, then a pump.
public export
lfst_9_2_1__boundary_tms_net : Lcyc_3_2_1__program -> Nat -> Rarc_5_6_1__event -> Iret_12__net_state -> Iret_12__net_state
lfst_9_2_1__boundary_tms_net pg fuel ev s = fst (rarc_5_6_6__pump_tms_net pg fuel (rarc_5_6_4__apply_tms_net pg ev s))

--@spec [LFST.9.2.1]
||| A history on the network with truth maintenance: the inputs, each
||| pumped, in order, under one fuel.
public export
lfst_9_2_1__replay_tms_net : Lcyc_3_2_1__program -> Nat -> List Rarc_5_6_1__event -> Iret_12__net_state -> Iret_12__net_state
lfst_9_2_1__replay_tms_net pg fuel [] s = s
lfst_9_2_1__replay_tms_net pg fuel (ev :: evs) s = lfst_9_2_1__replay_tms_net pg fuel evs (lfst_9_2_1__boundary_tms_net pg fuel ev s)

--@spec [LFST.9.2.1]
||| The same history on FireLoopTms's engine, under one fuel.
public export
lfst_9_2_1__replay_tms : Lcyc_3_2_1__program -> Nat -> List Rarc_5_6_1__event -> Iret_12__state -> Iret_12__state
lfst_9_2_1__replay_tms pg fuel [] s = s
lfst_9_2_1__replay_tms pg fuel (ev :: evs) s = lfst_9_2_1__replay_tms pg fuel evs (lfst_9_2_1__boundary pg fuel ev s)

--@spec [LFST.9.2.1]
||| A canonical replay on the network: each input pumped to quiescence,
||| in order.
public export
data Lfst_9_2_1__canonical_net : Lcyc_3_2_1__program -> Iret_12__net_state -> List Rarc_5_6_1__event -> Iret_12__net_state -> Type where
  CanonNetNil  : Lfst_9_2_1__canonical_net pg s [] s
  CanonNetStep : (fuel : Nat) -> fst (snd (rarc_5_6_6__pump_tms_net pg fuel (rarc_5_6_4__apply_tms_net pg ev s))) = Quiescent ->
                 Lfst_9_2_1__canonical_net pg (lfst_9_2_1__boundary_tms_net pg fuel ev s) evs s' ->
                 Lfst_9_2_1__canonical_net pg s (ev :: evs) s'

-- ---------------------------------------------------------------------
-- Small facts
-- ---------------------------------------------------------------------

--@derives [IRET.19]
export
iret_19__engine_inj : {w, w' : Rarc_5_6_4__wm} -> {n, n' : Rarc_5_3_1__network} -> MkEngine w n = MkEngine w' n' -> (w = w', n = n')
iret_19__engine_inj Refl = (Refl, Refl)

--@derives [IRET.12]
export
iret_12__maybe_split : (m : Maybe a) -> Either (m = Nothing) (x ** m = Just x)
iret_12__maybe_split Nothing = Left Refl
iret_12__maybe_split (Just x) = Right (x ** Refl)

-- ---------------------------------------------------------------------
-- One action agrees
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.7]
||| The network's action, when the dispatch is known.
export
rarc_5_6_7__do_action_tms_net_unfold : (pg : Lcyc_3_2_1__program) -> (r : Nat) -> (a : Iret_8_1__act) -> (act : Lgra_10_1__action) ->
                                       (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (wm' : Rarc_5_6_4__wm) -> (net' : Rarc_5_3_1__network) ->
                                       rarc_5_6_7__do_action_net (life pg) (atuple a) act eng = MkEngine wm' net' ->
                                       rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows)
                                         = iret_12_2__phase_net pg (MkTmsNet (MkEngine wm' net') (iret_10_2__record pg r (iret_11_3__fact_ids (atuple a)) (atuple a) act wm' rows))
rarc_5_6_7__do_action_tms_net_unfold pg r a act eng rows wm' net' da with (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng)
  rarc_5_6_7__do_action_tms_net_unfold pg r a act eng rows wm' net' da | (MkEngine w n) =
    let (we, ne) = iret_19__engine_inj da in rewrite we in rewrite ne in Refl

--@derives [RARC.5.6.7]
||| FireLoop's action, when the core action is known.
export
rarc_5_6_7__do_action_tms_fl_unfold : (pg : Lcyc_3_2_1__program) -> (r : Nat) -> (tok : Iret_11__tok) -> (act : Lgra_10_1__action) ->
                                    (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                    (wm1 : Rarc_5_6_4__wm) -> (tables1 : List (List Iret_11__tok)) ->
                                    rarc_5_6_7__do_action pg (tfacts tok) act (MkState wm tables) = MkState wm1 tables1 ->
                                    rarc_5_6_7__do_action_tms pg r tok act (MkTms (MkState wm tables) rows)
                                      = iret_12_2__phase pg (MkTms (MkState wm1 tables1) (iret_10_2__record pg r (iret_11_3__ids tok) (tfacts tok) act wm1 rows))
rarc_5_6_7__do_action_tms_fl_unfold pg r tok act wm tables rows wm1 tables1 da with (rarc_5_6_7__do_action pg (tfacts tok) act (MkState wm tables))
  rarc_5_6_7__do_action_tms_fl_unfold pg r tok act wm tables rows wm1 tables1 da | (MkState w t) =
    let (we, te) = rarc_5_6_5__state_inj da in rewrite we in rewrite te in Refl

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.7]
--@derives [IRET.10.2]
||| ONE ACTION AGREES: the core actions agree, both record the same row
||| against the same working memory, and the cascades agree.
export
rlow_4_2_1__do_action_tms_agree : (pg : Lcyc_3_2_1__program) -> (r : Nat) -> (tok : Iret_11__tok) -> (act : Lgra_10_1__action) ->
                                  (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                  Rlow_4_2_1__agree pg wm net toks ->
                                  (wm' ** net' ** toks' ** rows' ** ( rarc_5_6_7__do_action_tms_net pg r (iret_11__to_act tok) act (MkTmsNet (MkEngine wm net) rows) = MkTmsNet (MkEngine wm' net') rows'
                                                                    , rarc_5_6_7__do_action_tms pg r tok act (MkTms (MkState wm toks) rows) = MkTms (MkState wm' toks') rows'
                                                                    , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__do_action_tms_agree pg r tok act wm net toks rows ag =
  let (wm1 ** net1 ** toks1 ** (eN, eF, ag1)) = rlow_4_2_1__do_action_agree pg (tfacts tok) act wm net toks ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** (pN, pF, ag2)) =
           rlow_4_2_1__phase_agree pg wm1 net1 toks1 (iret_10_2__record pg r (iret_11_3__ids tok) (tfacts tok) act wm1 rows) ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** ( trans (rarc_5_6_7__do_action_tms_net_unfold pg r (iret_11__to_act tok) act (MkEngine wm net) rows wm1 net1 eN) pN
                                          , trans (rarc_5_6_7__do_action_tms_fl_unfold pg r tok act wm toks rows wm1 toks1 eF) pF
                                          , ag2 ))

--@derives [RARC.5.6.7]
||| One more action at the front of an RHS on the network, when the
||| first is known.
export
rarc_5_6_7__actions_tms_net_succ : (pg : Lcyc_3_2_1__program) -> (r : Nat) -> (a : Iret_8_1__act) -> (act : Lgra_10_1__action) -> (acts : List Lgra_10_1__action) ->
                                   (s : Iret_12__net_state) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                   rarc_5_6_7__do_action_tms_net pg r a act s = MkTmsNet eng rows ->
                                   rarc_5_6_7__do_actions_tms_net pg r a (act :: acts) s = rarc_5_6_7__do_actions_tms_net pg r a acts (MkTmsNet eng rows)
rarc_5_6_7__actions_tms_net_succ pg r a act acts s eng rows eq with (rarc_5_6_7__do_action_tms_net pg r a act s)
  rarc_5_6_7__actions_tms_net_succ pg r a act acts s eng rows eq | (MkTmsNet e rs) = cong (rarc_5_6_7__do_actions_tms_net pg r a acts) eq

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.7]
||| THE RHS AGREES, with the table and the cascade in the loop.
export
rlow_4_2_1__do_actions_tms_agree : (pg : Lcyc_3_2_1__program) -> (r : Nat) -> (tok : Iret_11__tok) -> (acts : List Lgra_10_1__action) ->
                                   (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                   Rlow_4_2_1__agree pg wm net toks ->
                                   (wm' ** net' ** toks' ** rows' ** ( rarc_5_6_7__do_actions_tms_net pg r (iret_11__to_act tok) acts (MkTmsNet (MkEngine wm net) rows) = MkTmsNet (MkEngine wm' net') rows'
                                                                     , rarc_5_6_7__do_actions_tms pg r tok acts (MkTms (MkState wm toks) rows) = MkTms (MkState wm' toks') rows'
                                                                     , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__do_actions_tms_agree pg r tok [] wm net toks rows ag = (wm ** net ** toks ** rows ** (Refl, Refl, ag))
rlow_4_2_1__do_actions_tms_agree pg r tok (act :: acts) wm net toks rows ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** (e1, f1, ag1)) = rlow_4_2_1__do_action_tms_agree pg r tok act wm net toks rows ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** (e2, f2, ag2)) = rlow_4_2_1__do_actions_tms_agree pg r tok acts wm1 net1 toks1 rows1 ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** ( trans (rarc_5_6_7__actions_tms_net_succ pg r (iret_11__to_act tok) act acts (MkTmsNet (MkEngine wm net) rows) (MkEngine wm1 net1) rows1 e1) e2
                                          , trans (rarc_5_6_7__actions_tms_succ pg r tok act acts (MkTms (MkState wm toks) rows) (MkState wm1 toks1) rows1 f1) f2
                                          , ag2 ))

-- ---------------------------------------------------------------------
-- One firing agrees
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
export
iret_11_4__step_tms_net_quiet : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                iret_11_1__select (nchains (enet eng)) = Nothing -> iret_11_4__step_tms_net pg (MkTmsNet eng rows) = Nothing
iret_11_4__step_tms_net_quiet pg eng rows h = rewrite h in Refl

--@derives [IRET.11.4]
export
iret_11_4__step_tms_net_fires : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (r, j : Nat) -> (c : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) ->
                                iret_11_1__select (nchains (enet eng)) = Just (r, j) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just c -> rarc_5_6_5__nth j (cacts c) = Just a ->
                                iret_11_4__step_tms_net pg (MkTmsNet eng rows) = Just (rarc_5_6_7__do_actions_tms_net pg r a (cactions c) (MkTmsNet (idat_6_2_2__mark_net r j eng) rows))
iret_11_4__step_tms_net_fires pg eng rows r j c a s n1 n2 = rewrite s in rewrite n1 in rewrite n2 in Refl

--@derives [IRET.11.4]
export
iret_11_4__step_tms_quiet : (pg : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            ldet_5_1__select_next tables = Nothing -> iret_11_4__step_tms pg (MkTms (MkState wm tables) rows) = Nothing
iret_11_4__step_tms_quiet pg wm tables rows h = rewrite h in Refl

--@derives [IRET.11.4]
export
iret_11_4__step_tms_fires : (pg : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            (r, j : Nat) -> (rule : Lgra_6_1__rule) -> (tok : Iret_11__tok) ->
                            ldet_5_1__select_next tables = Just (r, j) -> rarc_5_6_5__nth r (rules pg) = Just rule -> rarc_5_6_5__nth j (iret_11__table_at r tables) = Just tok ->
                            iret_11_4__step_tms pg (MkTms (MkState wm tables) rows)
                              = Just (rarc_5_6_7__do_actions_tms pg r tok (actions rule) (MkTms (MkState wm (idat_6_2_2__mark_fired r j tables)) rows))
iret_11_4__step_tms_fires pg wm tables rows r j rule tok s n1 n2 = rewrite s in rewrite n1 in rewrite n2 in Refl

--@derives [RLOW.4.2.1]
--@derives [IDAT.6.2.2]
||| Marking the selected activation on both sides keeps the agreement.
export
rlow_4_2_1__mark_agree_state : (pg : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                               Rlow_4_2_1__agree pg wm net toks ->
                               (r, j, j' : Nat) -> (ts : List Iret_11__tok) -> (c : Rlow_4_2_1__chain) ->
                               ldet_5_1__select_next toks = Just (r, j) -> iret_11_1__select (nchains net) = Just (r, j') ->
                               rarc_5_6_5__nth r toks = Just ts -> rarc_5_6_5__nth r (nchains net) = Just c ->
                               Rlow_4_2_1__agree pg wm (MkNetwork (nalphas net) (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j') (nchains net))) (idat_6_2_2__mark_fired r j toks)
rlow_4_2_1__mark_agree_state pg wm net toks ag r j j' ts c sn sc nts nc =
  let (ra, ta, ord, well) = ag
  in ( rlow_4_2_1__rules_agree_mark (nalphas net) r j' (nchains net) (rules pg) ra
     , rlow_4_2_1__mark_tables_agree r j j' toks (nchains net) ta ts c nts nc
         (rlow_4_2_1__first_of_select toks r j sn ts nts) (rlow_4_2_1__first_of_net (nchains net) r j' sc c nc)
     , idat_6_2_2__mark_net_ordered r j' (MkEngine wm net) ord
     , (fst well, fst (snd well), idat_6_2_2__mark_tables_well wm r j (rules pg) toks (snd (snd well))) )

--@derives [RLOW.4.2.1]
--@derives [IRET.11.4]
||| ONE FIRING AGREES: both engines stop, or both fire the same
||| activation of the same rule, record the same rows, cascade alike,
||| and agree afterwards.
export
rlow_4_2_1__step_tms_agree : (pg : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             Rlow_4_2_1__agree pg wm net toks ->
                             Either (iret_11_4__step_tms_net pg (MkTmsNet (MkEngine wm net) rows) = Nothing, iret_11_4__step_tms pg (MkTms (MkState wm toks) rows) = Nothing)
                                    (wm' ** net' ** toks' ** rows' ** ( iret_11_4__step_tms_net pg (MkTmsNet (MkEngine wm net) rows) = Just (MkTmsNet (MkEngine wm' net') rows')
                                                                      , iret_11_4__step_tms pg (MkTms (MkState wm toks) rows) = Just (MkTms (MkState wm' toks') rows')
                                                                      , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__step_tms_agree pg wm net toks rows ag =
  let (ra, ta, ord, well) = ag
  in case rlow_4_2_1__select_agree toks (nchains net) ta of
       Left (sn, sc) => Left (iret_11_4__step_tms_net_quiet pg (MkEngine wm net) rows sc, iret_11_4__step_tms_quiet pg wm toks rows sn)
       Right (r ** j ** j' ** ts ** c ** tok ** (sn, sc, nts, nc, nt, nb, nf, na)) =>
         let (rule ** (nr, sr)) = rlow_4_2_1__rule_at (nalphas net) (nchains net) (rules pg) ra r c nc
         in let acEq : (actions (rlow_4_2_1__rule_of (nalphas net) c) = actions rule)
                acEq = snd (snd (snd sr))
                marked : Rlow_4_2_1__agree pg wm (MkNetwork (nalphas net) (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j') (nchains net))) (idat_6_2_2__mark_fired r j toks)
                marked = rlow_4_2_1__mark_agree_state pg wm net toks ag r j j' ts c sn sc nts nc
         in let (wm2 ** net2 ** toks2 ** rows2 ** (aN, aF, ag2)) =
                  rlow_4_2_1__do_actions_tms_agree pg r tok (cactions c) wm (MkNetwork (nalphas net) (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j') (nchains net)))
                    (idat_6_2_2__mark_fired r j toks) rows marked
         in let stepN : (iret_11_4__step_tms_net pg (MkTmsNet (MkEngine wm net) rows) = Just (MkTmsNet (MkEngine wm2 net2) rows2))
                stepN = trans (iret_11_4__step_tms_net_fires pg (MkEngine wm net) rows r j' c (iret_11__to_act tok) sc nc na) (cong Just aN)
                stepF : (iret_11_4__step_tms pg (MkTms (MkState wm toks) rows) = Just (MkTms (MkState wm2 toks2) rows2))
                stepF = trans (iret_11_4__step_tms_fires pg wm toks rows r j rule tok sn nr
                                 (replace {p = \z => rarc_5_6_5__nth j z = Just tok} (sym (iret_11__table_at_nth r toks ts nts)) nt))
                              (cong Just (trans (cong (\acts => rarc_5_6_7__do_actions_tms pg r tok acts (MkTms (MkState wm (idat_6_2_2__mark_fired r j toks)) rows)) (sym acEq)) aF))
            in Right (wm2 ** net2 ** toks2 ** rows2 ** (stepN, stepF, ag2))

-- ---------------------------------------------------------------------
-- A run agrees
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE NETWORK'S RUN WITH TRUTH MAINTENANCE IS THE ONE FOLD at its step
||| (Rete/RunFold.idr's `iret_11_4__run_by`), by induction on the fuel. The two
||| unfoldings below are RunFold's through it.
export
iret_11_4__run_tms_net_by : (pg : Lcyc_3_2_1__program) -> (fuel : Nat) -> (s : Iret_12__net_state) ->
                            iret_11_4__run_tms_net pg fuel s = iret_11_4__run_by (iret_11_4__step_tms_net pg) fuel s
iret_11_4__run_tms_net_by pg Z s = Refl
iret_11_4__run_tms_net_by pg (S fuel) s with (iret_11_4__step_tms_net pg s)
  iret_11_4__run_tms_net_by pg (S fuel) s | Nothing = Refl
  iret_11_4__run_tms_net_by pg (S fuel) s | (Just s') with (iret_11_4__run_by (iret_11_4__step_tms_net pg) fuel s') proof rr
    iret_11_4__run_tms_net_by pg (S fuel) s | (Just s') | (t, h, n) = rewrite trans (iret_11_4__run_tms_net_by pg fuel s') rr in Refl

--@derives [IRET.11.4]
export
iret_11_4__run_tms_net_nothing : (pg : Lcyc_3_2_1__program) -> (fuel : Nat) -> (s : Iret_12__net_state) -> iret_11_4__step_tms_net pg s = Nothing ->
                                 iret_11_4__run_tms_net pg (S fuel) s = (s, Quiescent, 0)
iret_11_4__run_tms_net_nothing pg fuel s eq =
  trans (iret_11_4__run_tms_net_by pg (S fuel) s) (iret_11_4__run_by_nothing (iret_11_4__step_tms_net pg) fuel s eq)

--@derives [IRET.11.4]
export
iret_11_4__run_tms_net_just : (pg : Lcyc_3_2_1__program) -> (fuel : Nat) -> (s, s' : Iret_12__net_state) -> iret_11_4__step_tms_net pg s = Just s' ->
                              (t : Iret_12__net_state) -> (h : Iret_11_4__halt) -> (n : Nat) -> iret_11_4__run_tms_net pg fuel s' = (t, h, n) ->
                              iret_11_4__run_tms_net pg (S fuel) s = (t, h, S n)
iret_11_4__run_tms_net_just pg fuel s s' eq t h n rr =
  trans (iret_11_4__run_tms_net_by pg (S fuel) s)
        (iret_11_4__run_by_just (iret_11_4__step_tms_net pg) fuel s s' eq t h n (trans (sym (iret_11_4__run_tms_net_by pg fuel s')) rr))

-- `iret_11_4__run_tms_nothing` and `iret_11_4__run_tms_just`, the unfolding of
-- FireLoopTms's run by one firing, are Rete/TmsRun.idr's.

--@derives [RLOW.4.2.1]
--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| A RUN AGREES under any fuel: the same firings, the same halt, the
||| same count.
export
rlow_4_2_1__run_tms_agree : (pg : Lcyc_3_2_1__program) -> (fuel : Nat) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            Rlow_4_2_1__agree pg wm net toks ->
                            (wm' ** net' ** toks' ** rows' ** h ** n ** ( iret_11_4__run_tms_net pg fuel (MkTmsNet (MkEngine wm net) rows) = (MkTmsNet (MkEngine wm' net') rows', h, n)
                                                                        , iret_11_4__run_tms pg fuel (MkTms (MkState wm toks) rows) = (MkTms (MkState wm' toks') rows', h, n)
                                                                        , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__run_tms_agree pg Z wm net toks rows ag = (wm ** net ** toks ** rows ** FuelOut ** 0 ** (Refl, Refl, ag))
rlow_4_2_1__run_tms_agree pg (S fuel) wm net toks rows ag =
  case rlow_4_2_1__step_tms_agree pg wm net toks rows ag of
    Left (qn, qf) => (wm ** net ** toks ** rows ** Quiescent ** 0 **
                      ( iret_11_4__run_tms_net_nothing pg fuel (MkTmsNet (MkEngine wm net) rows) qn
                      , iret_11_4__run_tms_nothing pg fuel (MkTms (MkState wm toks) rows) qf
                      , ag ))
    Right (wm1 ** net1 ** toks1 ** rows1 ** (sN, sF, ag1)) =>
      let (wm2 ** net2 ** toks2 ** rows2 ** h ** n ** (rN, rF, ag2)) = rlow_4_2_1__run_tms_agree pg fuel wm1 net1 toks1 rows1 ag1
      in (wm2 ** net2 ** toks2 ** rows2 ** h ** S n **
           ( iret_11_4__run_tms_net_just pg fuel (MkTmsNet (MkEngine wm net) rows) (MkTmsNet (MkEngine wm1 net1) rows1) sN (MkTmsNet (MkEngine wm2 net2) rows2) h n rN
           , iret_11_4__run_tms_just pg fuel (MkTms (MkState wm toks) rows) (MkTms (MkState wm1 toks1) rows1) sF (MkTms (MkState wm2 toks2) rows2) h n rF
           , ag2 ))

-- ---------------------------------------------------------------------
-- An input agrees
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_tms_net_assert_nothing : (pg : Lcyc_3_2_1__program) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                           iret_19_1__assert_fact (life pg k) [] k key pay (ewm eng) = Nothing ->
                                           rarc_5_6_4__apply_tms_net pg (Assert k key pay) (MkTmsNet eng rows) = MkTmsNet eng rows
rarc_5_6_4__apply_tms_net_assert_nothing pg k key pay eng rows h = rewrite h in Refl

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_tms_net_assert_just : (pg : Lcyc_3_2_1__program) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (w : Rarc_5_6_4__wm) ->
                                        iret_19_1__assert_fact (life pg k) [] k key pay (ewm eng) = Just w ->
                                        rarc_5_6_4__apply_tms_net pg (Assert k key pay) (MkTmsNet eng rows) = iret_12_2__phase_net pg (MkTmsNet (iret_19_1__assert (life pg) [] k key pay eng) rows)
rarc_5_6_4__apply_tms_net_assert_just pg k key pay eng rows w h = rewrite h in Refl

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_tms_net_retract_nothing : (pg : Lcyc_3_2_1__program) -> (i : Nat) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                            rarc_5_6_4__lookup_fact i (ewm eng) = Nothing ->
                                            rarc_5_6_4__apply_tms_net pg (Retract i) (MkTmsNet eng rows) = MkTmsNet eng rows
rarc_5_6_4__apply_tms_net_retract_nothing pg i eng rows h = rewrite h in Refl

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_tms_net_retract_just : (pg : Lcyc_3_2_1__program) -> (i : Nat) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (f : Lfac_1_7_1__fact) ->
                                         rarc_5_6_4__lookup_fact i (ewm eng) = Just f ->
                                         rarc_5_6_4__apply_tms_net pg (Retract i) (MkTmsNet eng rows) = iret_12_2__phase_net pg (MkTmsNet (iret_19_2__retract f eng) rows)
rarc_5_6_4__apply_tms_net_retract_just pg i eng rows f h = rewrite h in Refl

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_assert_nothing : (pg : Lcyc_3_2_1__program) -> (k, key, pay : Nat) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                   iret_19_1__assert_fact (life pg k) [] k key pay wm = Nothing ->
                                   rarc_5_6_4__apply pg (Assert k key pay) (MkTms (MkState wm tables) rows) = MkTms (MkState wm tables) rows
rarc_5_6_4__apply_assert_nothing pg k key pay wm tables rows h = rewrite h in Refl

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_assert_just : (pg : Lcyc_3_2_1__program) -> (k, key, pay : Nat) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> (w : Rarc_5_6_4__wm) ->
                                iret_19_1__assert_fact (life pg k) [] k key pay wm = Just w ->
                                rarc_5_6_4__apply pg (Assert k key pay) (MkTms (MkState wm tables) rows) = iret_12_2__phase pg (MkTms (MkState w (rarc_5_6_5__propagate pg w tables)) rows)
rarc_5_6_4__apply_assert_just pg k key pay wm tables rows w h = rewrite h in Refl

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_retract_nothing : (pg : Lcyc_3_2_1__program) -> (i : Nat) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                    rarc_5_6_4__lookup_fact i wm = Nothing ->
                                    rarc_5_6_4__apply pg (Retract i) (MkTms (MkState wm tables) rows) = MkTms (MkState wm tables) rows
rarc_5_6_4__apply_retract_nothing pg i wm tables rows h = rewrite h in Refl

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_retract_just : (pg : Lcyc_3_2_1__program) -> (i : Nat) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> (f : Lfac_1_7_1__fact) ->
                                 rarc_5_6_4__lookup_fact i wm = Just f ->
                                 rarc_5_6_4__apply pg (Retract i) (MkTms (MkState wm tables) rows)
                                   = iret_12_2__phase pg (MkTms (MkState (rarc_5_6_4__remove_exact f wm) (rarc_5_6_5__propagate pg (rarc_5_6_4__remove_exact f wm) tables)) rows)
rarc_5_6_4__apply_retract_just pg i wm tables rows f h = rewrite h in Refl

--@derives [IRET.19.1]
||| The named assert-then-propagate, when the assert is known.
export
iret_19_1__assert_state_just : (pg : Lcyc_3_2_1__program) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (wm : Rarc_5_6_4__wm) -> (toks : List (List Iret_11__tok)) -> (w : Rarc_5_6_4__wm) ->
                               iret_19_1__assert_fact (life pg k) avoid k key pay wm = Just w ->
                               iret_19_1__assert_state pg avoid k key pay wm toks = MkState w (rarc_5_6_5__propagate pg w toks)
iret_19_1__assert_state_just pg avoid k key pay wm toks w h = rewrite h in Refl

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.4]
||| AN INPUT AGREES: a no-op assert or a retraction of an id not live
||| touches neither side; otherwise the network's assert or retract and
||| FireLoop's assert-then-propagate or retract-then-propagate agree, and
||| the cascades after them agree.
export
rlow_4_2_1__apply_tms_agree : (pg : Lcyc_3_2_1__program) -> (ev : Rarc_5_6_1__event) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              Rlow_4_2_1__agree pg wm net toks ->
                              (wm' ** net' ** toks' ** rows' ** ( rarc_5_6_4__apply_tms_net pg ev (MkTmsNet (MkEngine wm net) rows) = MkTmsNet (MkEngine wm' net') rows'
                                                                , rarc_5_6_4__apply pg ev (MkTms (MkState wm toks) rows) = MkTms (MkState wm' toks') rows'
                                                                , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__apply_tms_agree pg (Assert k key pay) wm net toks rows ag =
  case iret_12__maybe_split (iret_19_1__assert_fact (life pg k) [] k key pay wm) of
    Left af => (wm ** net ** toks ** rows ** ( rarc_5_6_4__apply_tms_net_assert_nothing pg k key pay (MkEngine wm net) rows af
                                             , rarc_5_6_4__apply_assert_nothing pg k key pay wm toks rows af
                                             , ag ))
    Right (w ** af) =>
      let (wm1 ** net1 ** toks1 ** (eN, eS, ag1)) = rlow_4_2_1__assert_agree pg [] k key pay wm net toks ag
      in let stEq : (MkState w (rarc_5_6_5__propagate pg w toks) = MkState wm1 toks1)
             stEq = trans (sym (iret_19_1__assert_state_just pg [] k key pay wm toks w af)) eS
         in let (wm2 ** net2 ** toks2 ** rows2 ** (pN, pF, ag2)) = rlow_4_2_1__phase_agree pg wm1 net1 toks1 rows ag1
            in (wm2 ** net2 ** toks2 ** rows2 **
                 ( trans (rarc_5_6_4__apply_tms_net_assert_just pg k key pay (MkEngine wm net) rows w af)
                         (trans (cong (\e => iret_12_2__phase_net pg (MkTmsNet e rows)) eN) pN)
                 , trans (rarc_5_6_4__apply_assert_just pg k key pay wm toks rows w af)
                         (trans (cong (\st => iret_12_2__phase pg (MkTms st rows)) stEq) pF)
                 , ag2 ))
rlow_4_2_1__apply_tms_agree pg (Retract i) wm net toks rows ag =
  case iret_12__maybe_split (rarc_5_6_4__lookup_fact i wm) of
    Left lk => (wm ** net ** toks ** rows ** ( rarc_5_6_4__apply_tms_net_retract_nothing pg i (MkEngine wm net) rows lk
                                             , rarc_5_6_4__apply_retract_nothing pg i wm toks rows lk
                                             , ag ))
    Right (f ** lk) =>
      let ag1 : Rlow_4_2_1__agree pg (rarc_5_6_4__remove_exact f wm) (enet (iret_19_2__retract f (MkEngine wm net))) (rarc_5_6_5__propagate pg (rarc_5_6_4__remove_exact f wm) toks)
          ag1 = rlow_4_2_1__retract_agree pg wm net toks ag f (fst (rarc_5_6_4__lookup_elem i wm f lk))
      in let (wm2 ** net2 ** toks2 ** rows2 ** (pN, pF, ag2)) =
               rlow_4_2_1__phase_agree pg (rarc_5_6_4__remove_exact f wm) (enet (iret_19_2__retract f (MkEngine wm net))) (rarc_5_6_5__propagate pg (rarc_5_6_4__remove_exact f wm) toks) rows ag1
         in (wm2 ** net2 ** toks2 ** rows2 **
              ( trans (rarc_5_6_4__apply_tms_net_retract_just pg i (MkEngine wm net) rows f lk) pN
              , trans (rarc_5_6_4__apply_retract_just pg i wm toks rows f lk) pF
              , ag2 ))

-- ---------------------------------------------------------------------
-- A boundary, a history, a canonical replay, the transfer
-- ---------------------------------------------------------------------

--@derives [RLOW.4.2.1]
--@derives [LFST.9.2.1]
||| AN INPUT PUMPED agrees: the input, then the run, with the same halt
||| and count.
export
rlow_4_2_1__boundary_tms_agree : (pg : Lcyc_3_2_1__program) -> (fuel : Nat) -> (ev : Rarc_5_6_1__event) ->
                                 (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                 Rlow_4_2_1__agree pg wm net toks ->
                                 (wm' ** net' ** toks' ** rows' ** h ** n ** ( rarc_5_6_6__pump_tms_net pg fuel (rarc_5_6_4__apply_tms_net pg ev (MkTmsNet (MkEngine wm net) rows)) = (MkTmsNet (MkEngine wm' net') rows', h, n)
                                                                             , rarc_5_6_6__pump_tms pg fuel (rarc_5_6_4__apply pg ev (MkTms (MkState wm toks) rows)) = (MkTms (MkState wm' toks') rows', h, n)
                                                                             , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__boundary_tms_agree pg fuel ev wm net toks rows ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** (aN, aF, ag1)) = rlow_4_2_1__apply_tms_agree pg ev wm net toks rows ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** h ** n ** (rN, rF, ag2)) = rlow_4_2_1__run_tms_agree pg fuel wm1 net1 toks1 rows1 ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** h ** n **
          ( trans (cong (iret_11_4__run_tms_net pg fuel) aN) rN
          , trans (cong (iret_11_4__run_tms pg fuel) aF) rF
          , ag2 ))

--@derives [RLOW.4.2.1]
--@derives [LFST.9.2.1]
||| EVERY HISTORY keeps the agreement, under one fuel.
export
rlow_4_2_1__replay_tms_agree : (pg : Lcyc_3_2_1__program) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                               (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                               Rlow_4_2_1__agree pg wm net toks ->
                               (wm' ** net' ** toks' ** rows' ** ( lfst_9_2_1__replay_tms_net pg fuel evs (MkTmsNet (MkEngine wm net) rows) = MkTmsNet (MkEngine wm' net') rows'
                                                                 , lfst_9_2_1__replay_tms pg fuel evs (MkTms (MkState wm toks) rows) = MkTms (MkState wm' toks') rows'
                                                                 , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__replay_tms_agree pg fuel [] wm net toks rows ag = (wm ** net ** toks ** rows ** (Refl, Refl, ag))
rlow_4_2_1__replay_tms_agree pg fuel (ev :: evs) wm net toks rows ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** h ** n ** (bN, bF, ag1)) = rlow_4_2_1__boundary_tms_agree pg fuel ev wm net toks rows ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** (rN, rF, ag2)) = rlow_4_2_1__replay_tms_agree pg fuel evs wm1 net1 toks1 rows1 ag1
     in (wm2 ** net2 ** toks2 ** rows2 **
          ( trans (cong (\t => lfst_9_2_1__replay_tms_net pg fuel evs (fst t)) bN) rN
          , trans (cong (\t => lfst_9_2_1__replay_tms pg fuel evs (fst t)) bF) rF
          , ag2 ))

--@derives [RLOW.4.2.1]
--@derives [LFST.9.2.1]
||| A CANONICAL REPLAY ON FIRELOOP IS CANONICAL ON THE NETWORK, input
||| by input with the same fuel: each pump quiesces on both sides, and
||| the states agree throughout.
export
rlow_4_2_1__canonical_tms_agree : (pg : Lcyc_3_2_1__program) -> (evs : List Rarc_5_6_1__event) ->
                                  (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> (s' : Iret_12__state) ->
                                  Lfst_9_2_1__canonical pg (MkTms (MkState wm toks) rows) evs s' -> Rlow_4_2_1__agree pg wm net toks ->
                                  (wm' ** net' ** toks' ** rows' ** ( Lfst_9_2_1__canonical_net pg (MkTmsNet (MkEngine wm net) rows) evs (MkTmsNet (MkEngine wm' net') rows')
                                                                    , s' = MkTms (MkState wm' toks') rows'
                                                                    , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__canonical_tms_agree pg [] wm net toks rows _ CanonNil ag = (wm ** net ** toks ** rows ** (CanonNetNil, Refl, ag))
rlow_4_2_1__canonical_tms_agree pg (ev :: evs) wm net toks rows s' (CanonStep fuel q rest) ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** h ** n ** (bN, bF, ag1)) = rlow_4_2_1__boundary_tms_agree pg fuel ev wm net toks rows ag
  in let hq : (h = Quiescent)
         hq = trans (sym (cong (\t => fst (snd t)) bF)) q
         bEq : (lfst_9_2_1__boundary pg fuel ev (MkTms (MkState wm toks) rows) = MkTms (MkState wm1 toks1) rows1)
         bEq = cong fst bF
         bNEq : (lfst_9_2_1__boundary_tms_net pg fuel ev (MkTmsNet (MkEngine wm net) rows) = MkTmsNet (MkEngine wm1 net1) rows1)
         bNEq = cong fst bN
         rest1 : Lfst_9_2_1__canonical pg (MkTms (MkState wm1 toks1) rows1) evs s'
         rest1 = replace {p = \s => Lfst_9_2_1__canonical pg s evs s'} bEq rest
     in let (wm2 ** net2 ** toks2 ** rows2 ** (cn, eq2, ag2)) = rlow_4_2_1__canonical_tms_agree pg evs wm1 net1 toks1 rows1 s' rest1 ag1
        in (wm2 ** net2 ** toks2 ** rows2 **
             ( CanonNetStep fuel (trans (cong (\t => fst (snd t)) bN) hq)
                 (replace {p = \s => Lfst_9_2_1__canonical_net pg s evs (MkTmsNet (MkEngine wm2 net2) rows2)} (sym bNEq) cn)
             , eq2
             , ag2 ))

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.5]
--@derives [IRET.12]
--@derives [IRET.12.4]
--@derives [LFST.9.2.1]
||| THE TRANSFER THEOREM WITH TRUTH MAINTENANCE. Run on one history
||| from the loaded network and from FireLoopTms's empty state under
||| the program the network lowers to, the two engines reach one
||| working memory and one dependency table, and each table's unblocked
||| tokens are the terminal's activations, in order and with their
||| flags. Every theorem stated over FireLoopTms's run -- Rete/TmsRun.idr,
||| Lcyc/TmsTermination.idr, Rete/PumpBoundary.idr -- is a theorem about
||| the spec's network.
export
rlow_4_2_1__transfer_tms : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                           (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                           (wm' ** net' ** toks' ** rows' **
                             ( lfst_9_2_1__replay_tms_net (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) fuel evs (MkTmsNet (rdsc_4a_5__load alphas rules) [])
                                 = MkTmsNet (MkEngine wm' net') rows'
                             , lfst_9_2_1__replay_tms (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) fuel evs
                                 (rarc_5_6_5__init_tms (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) []) = MkTms (MkState wm' toks') rows'
                             , Rlow_4_2_1__agree (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) wm' net' toks' ))
rlow_4_2_1__transfer_tms life fuel evs alphas rules =
  rlow_4_2_1__replay_tms_agree (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) fuel evs [] (enet (rdsc_4a_5__load alphas rules))
    (toks (rarc_5_6_5__init_state (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) [])) []
    (rlow_4_2_1__init_agree life alphas rules)

--@derives [RLOW.4.2.1]
--@derives [LFST.9.2.1]
--@derives [IRET.12]
||| THE CANONICAL TRANSFER: a canonical replay from FireLoopTms's empty
||| state is a canonical replay from the loaded network, with the same
||| fuel per input, and the states agree at its end.
export
rlow_4_2_1__transfer_canonical : (life : Nat -> Lscp_1_3__lifecycle) -> (evs : List Rarc_5_6_1__event) ->
                                 (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                 (s' : Iret_12__state) ->
                                 Lfst_9_2_1__canonical (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules)))
                                   (rarc_5_6_5__init_tms (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) []) evs s' ->
                                 (wm' ** net' ** toks' ** rows' **
                                   ( Lfst_9_2_1__canonical_net (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) (MkTmsNet (rdsc_4a_5__load alphas rules) []) evs
                                       (MkTmsNet (MkEngine wm' net') rows')
                                   , s' = MkTms (MkState wm' toks') rows'
                                   , Rlow_4_2_1__agree (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) wm' net' toks' ))
rlow_4_2_1__transfer_canonical life evs alphas rules s' canon =
  rlow_4_2_1__canonical_tms_agree (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) evs [] (enet (rdsc_4a_5__load alphas rules))
    (toks (rarc_5_6_5__init_state (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) [])) [] s' canon
    (rlow_4_2_1__init_agree life alphas rules)

-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The pump boundary: external events, each followed by a run to
||| quiescence, on Rete/FireLoopTms.idr's engine -- the cadence of
||| [LFST.9.2.1] (the replayer "fires the engine to quiescence between the
||| inputs the trace marks as separately pumped") over the consumption
||| loop of RARC.5.6.1-RARC.5.6.6.
|||
||| NORMATIVE COMPANION, on the same mechanisms as Rete/FireLoopTms.idr.
|||
||| WHAT IS MODELLED. An event entering working memory from outside a
||| firing (`Rarc_5_6_1__event`: an adapter assert, or the retraction of a
||| live fact) is applied RARC.5.6.4, propagated, and followed by the
||| cascade the ended activations demand [IRET.12.2]; then the pump fires
||| until the agenda is empty or the fuel is spent RARC.5.6.6. A
||| canonical replay (`Lfst_9_2_1__canonical`) is a sequence of inputs each
||| pumped to quiescence.
|||
||| WHAT IS PROVED. Applying an event and running a pump keep the run
||| invariant of Rete/TmsRun.idr and the kinds of the rows' targets
||| (`rarc_5_6_4__apply_inv`, `iret_11_4__pump_inv`), so every boundary of
||| a canonical replay satisfies them (`lfst_9_2_1__canonical_inv`). For a
||| positive program certified as [LCYC.3.1.1] admits it, every input
||| sequence HAS a canonical replay: each pump reaches quiescence
||| (`rarc_5_6_6__pump_quiesces` -- RARC.5.6.6's "until the agenda is
||| empty", which Lcyc/TmsTermination.idr supplies -- and
||| `lfst_9_2_1__canonical_exists`, `lfst_9_2_1__canonical_from_input`).
|||
||| AT A BOUNDARY, and indeed at every state between actions, the live ids
||| are exactly Rete/Refcount.idr's cascade of the engine's own table over
||| themselves (`iret_12_2__boundary_fixpoint`): every row is live, so the
||| live set is self-supported. Hence the well-founded facts are live and
||| what is live beyond them is an unfounded set
||| (`llog_2_5__boundary_unfounded`) -- exactly what recompute-and-diff at
||| the boundary would retract -- and on acyclic support the live set IS
||| the well-founded set (`iret_12_3__boundary_ranked`): recompute-and-diff
||| would change nothing there, as the recommended mechanism's containment
||| property claims.
|||
||| SCOPE. Positive programs (the run invariant). The cascade runs after an
||| external event as it runs after an action; an adapter assert into a
||| `logical` kind records no row, so it is an input fact until some
||| activation also emits it.
module Rete.PumpBoundary

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Certificate
import Lcyc.Termination
import Lcyc.TmsTermination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- Events, the pump, the cadence
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.1]
||| An event entering working memory from outside a firing: an adapter
||| assert of a value into a kind, or the retraction of a live fact by id.
public export
data Rarc_5_6_1__event : Type where
  Assert  : (kind : Nat) -> (key : Nat) -> (pay : Nat) -> Rarc_5_6_1__event
  Retract : (id : Nat) -> Rarc_5_6_1__event

--@derives [RARC.5.6.1]
||| The value an assert carries lies in the domain; a retraction carries none.
public export
Rarc_5_6_1__event_in_dom : List (Nat, Nat) -> Rarc_5_6_1__event -> Type
Rarc_5_6_1__event_in_dom dom (Assert k key pay) = Elem (key, pay) dom
Rarc_5_6_1__event_in_dom dom (Retract _) = ()

--@spec [RARC.5.6.4]
||| Apply the event to working memory, propagate, and run the cascade the
||| ended activations demand [IRET.12.2]. An adapter assert has no bound
||| ids to avoid; a retraction of an id not live is a no-op.
public export
rarc_5_6_4__apply : Lcyc_3_2_1__program -> Rarc_5_6_1__event -> Iret_12__state -> Iret_12__state
rarc_5_6_4__apply p (Assert k key pay) (MkTms (MkState wm tables) rows) =
  case iret_19_1__assert_fact (life p k) [] k key pay wm of
    Nothing => MkTms (MkState wm tables) rows
    Just wm' => iret_12_2__phase p (MkTms (MkState wm' (rarc_5_6_5__propagate p wm' tables)) rows)
rarc_5_6_4__apply p (Retract i) (MkTms (MkState wm tables) rows) =
  case rarc_5_6_4__lookup_fact i wm of
    Nothing => MkTms (MkState wm tables) rows
    Just f => iret_12_2__phase p (MkTms (MkState (rarc_5_6_4__remove_exact f wm) (rarc_5_6_5__propagate p (rarc_5_6_4__remove_exact f wm) tables)) rows)

--@spec [RARC.5.6.6]
||| One pump: fire until the agenda is empty or the fuel is spent,
||| reporting which and how many firings.
public export
rarc_5_6_6__pump_tms : Lcyc_3_2_1__program -> Nat -> Iret_12__state -> (Iret_12__state, Iret_11_4__halt, Nat)
rarc_5_6_6__pump_tms p fuel s = iret_11_4__run_tms p fuel s

--@spec [LFST.9.2.1]
||| The canonical cadence: one input, then a pump.
public export
lfst_9_2_1__boundary : Lcyc_3_2_1__program -> Nat -> Rarc_5_6_1__event -> Iret_12__state -> Iret_12__state
lfst_9_2_1__boundary p fuel ev s = fst (rarc_5_6_6__pump_tms p fuel (rarc_5_6_4__apply p ev s))

--@spec [LFST.9.2.1]
||| A canonical replay: each input pumped to quiescence, in order.
public export
data Lfst_9_2_1__canonical : Lcyc_3_2_1__program -> Iret_12__state -> List Rarc_5_6_1__event -> Iret_12__state -> Type where
  CanonNil  : Lfst_9_2_1__canonical p s [] s
  CanonStep : (fuel : Nat) -> fst (snd (rarc_5_6_6__pump_tms p fuel (rarc_5_6_4__apply p ev s))) = Quiescent ->
              Lfst_9_2_1__canonical p (lfst_9_2_1__boundary p fuel ev s) evs s' ->
              Lfst_9_2_1__canonical p s (ev :: evs) s'

--@derives [IRET.12.4]
||| The kinds of the rows' targets, of a state.
public export
Iret_12_4__run_kind_s : Lcyc_3_2_1__program -> Iret_12__state -> Type
Iret_12_4__run_kind_s p s = Iret_12_4__run_kind p (core s).wm (deps s)

-- ---------------------------------------------------------------------
-- The pump
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.6]
||| The halt reason is honest: a pump reporting quiescence left an agenda
||| that fires nothing.
export
rarc_5_6_6__quiescent_means_empty : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (s : Iret_12__state) ->
                                    fst (snd (rarc_5_6_6__pump_tms p fuel s)) = Quiescent ->
                                    iret_11_4__step_tms p (fst (rarc_5_6_6__pump_tms p fuel s)) = Nothing
rarc_5_6_6__quiescent_means_empty p Z s prf = absurd prf
rarc_5_6_6__quiescent_means_empty p (S fuel) s prf with (iret_11_4__step_tms p s) proof st
  rarc_5_6_6__quiescent_means_empty p (S fuel) s prf | Nothing = st
  rarc_5_6_6__quiescent_means_empty p (S fuel) s prf | (Just s1) with (iret_11_4__run_tms p fuel s1) proof rr
    rarc_5_6_6__quiescent_means_empty p (S fuel) s prf | (Just s1) | (t, h, n) =
      replace {p = \x => iret_11_4__step_tms p (fst x) = Nothing} rr
        (rarc_5_6_6__quiescent_means_empty p fuel s1 (replace {p = \x => fst (snd x) = Quiescent} (sym rr) prf))

--@derives [IRET.11.4]
||| A run that quiesces within n firings reports quiescence with fuel n.
export
iret_11_4__run_halts : (p : Lcyc_3_2_1__program) -> (n : Nat) -> (s : Iret_12__state) -> iret_11_4__step_n_tms p n s = Nothing ->
                       fst (snd (rarc_5_6_6__pump_tms p n s)) = Quiescent
iret_11_4__run_halts p Z s prf = absurd prf
iret_11_4__run_halts p (S m) s prf with (iret_11_4__step_tms p s) proof st
  iret_11_4__run_halts p (S m) s prf | Nothing = Refl
  iret_11_4__run_halts p (S m) s prf | (Just (MkTms st1 rows1)) with (iret_11_4__run_tms p m (MkTms st1 rows1)) proof rr
    iret_11_4__run_halts p (S m) s prf | (Just (MkTms st1 rows1)) | (t, h, k) =
      replace {p = \x => fst (snd x) = Quiescent} rr (iret_11_4__run_halts p m (MkTms st1 rows1) prf)

--@derives [IRET.11.4]
||| A pump keeps the run invariant and the kinds of the rows' targets,
||| however it halts.
export
iret_11_4__pump_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                      ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                      (fuel : Nat) -> (s : Iret_12__state) -> Iret_12__run_inv_s p dom s -> Iret_12_4__run_kind_s p s ->
                      (Iret_12__run_inv_s p dom (fst (rarc_5_6_6__pump_tms p fuel s)), Iret_12_4__run_kind_s p (fst (rarc_5_6_6__pump_tms p fuel s)))
iret_11_4__pump_inv p pos ct dom litsIn Z s rinv rk = (rinv, rk)
iret_11_4__pump_inv p pos ct dom litsIn (S fuel) (MkTms (MkState wm tables) rows) rinv rk with (iret_11_4__step_tms p (MkTms (MkState wm tables) rows)) proof st
  iret_11_4__pump_inv p pos ct dom litsIn (S fuel) (MkTms (MkState wm tables) rows) rinv rk | Nothing = (rinv, rk)
  iret_11_4__pump_inv p pos ct dom litsIn (S fuel) (MkTms (MkState wm tables) rows) rinv rk | (Just s1) with (iret_11_4__run_tms p fuel s1) proof rr
    iret_11_4__pump_inv p pos ct dom litsIn (S fuel) (MkTms (MkState wm tables) rows) rinv rk | (Just s1) | (t, h, n) =
      let (_, rinv1, rk1) = lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk s1 st
      in replace {p = \x => (Iret_12__run_inv_s p dom (fst x), Iret_12_4__run_kind_s p (fst x))} rr
           (iret_11_4__pump_inv p pos ct dom litsIn fuel s1 rinv1 rk1)

--@derives [RARC.5.6.6]
||| THE AGENDA EMPTIES. For a positive program certified as [LCYC.3.1.1]
||| admits it, from an invariant state some fuel makes the pump halt on
||| an empty agenda -- the clause's first disjunct, which the abstract
||| loop of ConsumptionLoop.idr could not state -- and the invariant holds
||| there.
export
rarc_5_6_6__pump_quiesces : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                            ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                            (s : Iret_12__state) -> Iret_12__run_inv_s p dom s -> Iret_12_4__run_kind_s p s ->
                            (fuel : Nat ** ( fst (snd (rarc_5_6_6__pump_tms p fuel s)) = Quiescent
                                           , Iret_12__run_inv_s p dom (fst (rarc_5_6_6__pump_tms p fuel s))
                                           , Iret_12_4__run_kind_s p (fst (rarc_5_6_6__pump_tms p fuel s)) ))
rarc_5_6_6__pump_quiesces p pos ct dom litsIn (MkTms (MkState wm tables) rows) rinv rk =
  let (n ** done) = lcyc_1_1__quiesces_tms p pos ct dom litsIn wm tables rows rinv rk
                      (lcyc_1_1__lex_acc (lcyc_1_1__measure p (tmsStrata ct) dom (MkState wm tables)))
  in let (rinvN, rkN) = iret_11_4__pump_inv p pos ct dom litsIn n (MkTms (MkState wm tables) rows) rinv rk
  in (n ** (iret_11_4__run_halts p n (MkTms (MkState wm tables) rows) done, rinvN, rkN))

-- ---------------------------------------------------------------------
-- The kinds of the rows' targets through a cascade
-- ---------------------------------------------------------------------

--@derives [IRET.12.4]
||| One phase keeps the target kinds: it only removes facts.
export
iret_12_4__phase_kind : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                        (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                        Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows -> Iret_12_4__run_kind p wm rows0 ->
                        (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> (rows' : Iret_12_4__table) ->
                        iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows' ->
                        Iret_12_4__run_kind p wm' rows0
iret_12_4__phase_kind p dom rows0 live0 wm tables rows inv rk wm' tables' rows' eq =
  case iret_12_2__phase_gone_shape p wm tables rows wm' tables' rows' eq of
    Left (we, _) => replace {p = \w => Iret_12_4__run_kind p w rows0} (sym we) rk
    Right (we, _) => replace {p = \w => Iret_12_4__run_kind p w rows0} (sym we)
                       (\row, e0 => let (q ** (nq, kf)) = rk row e0
                                    in (q ** (nq, \f, ef, feq => kf f (fst (lcyc_1_1__elem_filter_inv _ wm ef)) feq)))

--@derives [IRET.12.2]
||| A phase only removes facts.
export
iret_12_2__phase_facts_sub : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> (rows' : Iret_12_4__table) ->
                             iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows' ->
                             (f : Lfac_1_7_1__fact) -> Elem f wm' -> Elem f wm
iret_12_2__phase_facts_sub p wm tables rows wm' tables' rows' eq f ef = case iret_12_2__phase_gone_shape p wm tables rows wm' tables' rows' eq of
  Left (we, _) => replace {p = \w => Elem f w} we ef
  Right (we, _) => fst (lcyc_1_1__elem_filter_inv _ wm (replace {p = \w => Elem f w} we ef))

--@derives [IRET.12.2]
||| A phase never removes a fact of an explicit kind: what it retracts is
||| a row's target, and a row's target is `logical`.
export
iret_12_2__phase_explicit : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                            (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows -> Iret_12_4__run_kind p wm rows0 ->
                            (f : Lfac_1_7_1__fact) -> Elem f wm -> life p (fkind f) = Explicit ->
                            (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> (rows' : Iret_12_4__table) ->
                            iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows' -> Elem f wm'
iret_12_2__phase_explicit p dom rows0 live0 wm tables rows inv rk f ef ex wm' tables' rows' eq =
  case iret_12_2__phase_gone_shape p wm tables rows wm' tables' rows' eq of
    Left (we, _) => replace {p = \w => Elem f w} (sym we) ef
    Right (we, _) => replace {p = \w => Elem f w} (sym we)
      (lcyc_1_1__elem_filter_fwd (\g => not (rarc_5_6_5__elem (fid g) (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)))) wm ef
         (iret_12__not_false _ (iret_12__bool_false_of _ (\inGone =>
            let (inT, _) = lcyc_1_1__elem_filter_inv (\i => iret_12_1__count (iret_12_2__kept (MkState wm tables) rows) i == 0)
                             (map rtarget (iret_12_2__ended (MkState wm tables) rows)) (lcyc_1_1__elem_l_elem _ _ inGone)
            in let (row ** (er, ti)) = lcyc_1_1__elem_map_inv rtarget (iret_12_2__ended (MkState wm tables) rows) inT
            in let (e0, _) = lcyc_1_1__elem_filter_inv (\row => not (iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm)) rows er
            in let (rule ** (nr, kf)) = rk row (rowsSub inv row e0)
            in snd (kf f ef (sym ti)) ex))))

--@derives [IRET.12.4]
||| And so does any number of phases, alongside the cascade invariant;
||| the facts only shrink, and explicit-kind facts are kept.
export
iret_12_4__phase_n_kind : (n : Nat) -> (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                          (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                          Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows -> Iret_12_4__run_kind p wm rows0 ->
                          (wm' ** (tables' ** (rows' **
                            ( iret_12_2__phase_n n p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                            , Iret_12_2__cascade_inv p dom rows0 live0 wm' tables' rows'
                            , Iret_12_4__run_kind p wm' rows0
                            , (f : Lfac_1_7_1__fact) -> Elem f wm' -> Elem f wm
                            , (f : Lfac_1_7_1__fact) -> Elem f wm -> life p (fkind f) = Explicit -> Elem f wm' ))))
iret_12_4__phase_n_kind Z p pos dom rows0 live0 wm tables rows inv rk = (wm ** (tables ** (rows ** (Refl, inv, rk, \f, e => e, \f, e, _ => e))))
iret_12_4__phase_n_kind (S n) p pos dom rows0 live0 wm tables rows inv rk =
  case iret_12_2__phase_preserves p pos dom rows0 live0 wm tables rows inv of
    (wm1 ** (tables1 ** (rows1 ** (eq, inv1)))) =>
      case iret_12_4__phase_n_kind n p pos dom rows0 live0 wm1 tables1 rows1 inv1 (iret_12_4__phase_kind p dom rows0 live0 wm tables rows inv rk wm1 tables1 rows1 eq) of
        (wm2 ** (tables2 ** (rows2 ** (eq2, inv2, rk2, sub2, kept2)))) =>
          (wm2 ** (tables2 ** (rows2 **
            ( trans (iret_12_2__phase_n_succ n p (MkTms (MkState wm tables) rows) (MkState wm1 tables1) rows1 eq) eq2
            , inv2, rk2
            , \f, e => iret_12_2__phase_facts_sub p wm tables rows wm1 tables1 rows1 eq f (sub2 f e)
            , \f, e, ex => kept2 f (iret_12_2__phase_explicit p dom rows0 live0 wm tables rows inv rk f e ex wm1 tables1 rows1 eq) ex ))))

-- ---------------------------------------------------------------------
-- An external change, propagated and cascaded
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| The entry to the cascade after a change of working memory outside any
||| firing -- ids kept, at most facts with fresh ids added, unique, in the
||| domain: the bridge's cascade invariant holds over the rows and the ids
||| live after the change, because every row was live, and the target
||| kinds are kept.
export
iret_12_2__external_entry : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                            (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                            (wm1 : Rarc_5_6_4__wm) -> All (\f => Elem (lfac_2_5_1__val f) dom) wm1 -> Iret_4_4__keeps wm wm1 ->
                            ((g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)) -> Iret_4_4__unique wm1 ->
                            ( Iret_12_2__cascade_inv p dom rows (iret_11_3__fact_ids wm1) wm1 (rarc_5_6_5__propagate p wm1 tables) rows
                            , Iret_12_4__run_kind p wm1 rows )
iret_12_2__external_entry p pos dom wm tables rows rinv rk wm1 wd keeps adds uniq1 =
  let inv1 : Lcyc_1_1__inv p dom (MkState wm1 (rarc_5_6_5__propagate p wm1 tables))
      inv1 = lcyc_1_1__propagate_inv p dom (MkState wm tables) (runCore rinv) wm1 wd
      rf1 : (row : Iret_12_4__row) -> Elem row rows -> iret_7_8__activation_live (rarc_5_6_5__propagate p wm1 tables) row = True -> Iret_12_4__row_facts p wm1 row
      rf1 row e act1 = iret_12_2__entry_read_old p dom wm tables rows rinv wm1 keeps adds row e (iret_7_8__live_before_propagate p wm1 tables row act1)
      rl1 : (row : Iret_12_4__row) -> Elem row rows -> iret_12__all_in (rids row) (iret_11_3__fact_ids wm1) = True ->
            rarc_5_6_4__is_live (rtarget row) wm1 = True -> iret_7_8__activation_live (rarc_5_6_5__propagate p wm1 tables) row = True
      rl1 row e al _ = let (act, _) = iret_12__run_row_live p dom wm tables rows rinv row e
                       in iret_7_8__live_after_propagate p pos dom (MkState wm tables) (runCore rinv) wm1 row
                            (iret_12_2__entry_read_old p dom wm tables rows rinv wm1 keeps adds row e act) al act
      kind1 : Iret_12_4__run_kind p wm1 rows
      kind1 row e = let (q ** (nq, kf)) = rk row e
                    in (q ** (nq, \f, ef, feq => case adds f ef of
                          Left efw => kf f efw feq
                          Right nl => void (lcyc_1_1__bool_not_both _
                                             (replace {p = \j => rarc_5_6_4__is_live j wm = True} (sym feq) (snd (iret_12__run_row_live p dom wm tables rows rinv row e)))
                                             nl)))
  in ( MkCascadeInv inv1 uniq1 (\row, e => e) (\i, e => e) rf1 (\row, e, al, tl => (e, rl1 row e al tl))
         (iret_12_2__cascade_sub (iret_12_2__base rows (iret_11_3__fact_ids wm1)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm1))
         (iret_12_2__base_row rows (iret_11_3__fact_ids wm1))
     , kind1 )

--@derives [IRET.12.2]
||| A change of working memory outside any firing -- ids kept, at most
||| facts with fresh ids added, unique, in the domain -- followed by
||| propagation and the cascade keeps the run invariant and the target
||| kinds. The bridge's premises hold because every row was live.
export
iret_12_2__external_cascade : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                              (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                              (wm1 : Rarc_5_6_4__wm) -> All (\f => Elem (lfac_2_5_1__val f) dom) wm1 -> Iret_4_4__keeps wm wm1 ->
                              ((g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)) -> Iret_4_4__unique wm1 ->
                              (wmF ** (tablesF ** (rowsF **
                                ( iret_12_2__phase p (MkTms (MkState wm1 (rarc_5_6_5__propagate p wm1 tables)) rows) = MkTms (MkState wmF tablesF) rowsF
                                , Iret_12__run_inv p dom wmF tablesF rowsF
                                , Iret_12_4__run_kind p wmF rowsF
                                , (f : Lfac_1_7_1__fact) -> Elem f wmF -> Elem f wm1
                                , (f : Lfac_1_7_1__fact) -> Elem f wm1 -> life p (fkind f) = Explicit -> Elem f wmF ))))
iret_12_2__external_cascade p pos dom wm tables rows rinv rk wm1 wd keeps adds uniq1 =
  let (inv0, kind1) = iret_12_2__external_entry p pos dom wm tables rows rinv rk wm1 wd keeps adds uniq1
  in case iret_12_4__phase_n_kind (S (length rows)) p pos dom rows (iret_11_3__fact_ids wm1) wm1 (rarc_5_6_5__propagate p wm1 tables) rows inv0 kind1 of
       (wmF ** (tablesF ** (rowsF ** (eq, invF, rkF, subF, keptF)))) =>
         (wmF ** (tablesF ** (rowsF **
           ( eq
           , MkRunInv (coreInv invF) (uniq invF) (\row, e, act => rowFacts invF row (rowsSub invF row e) act)
               (replace {p = \x => iret_12_2__ended (core x) (deps x) = []} eq
                  (iret_12_2__phase_n_fixed (S (length rows)) p wm1 (rarc_5_6_5__propagate p wm1 tables) rows (iret_12__lte_succ_self (length rows))))
           , \row, e => rkF row (rowsSub invF row e)
           , subF
           , keptF ))))

--@derives [IRET.12.2]
||| The cascade after such a change ends in a state satisfying the bridge's
||| cascade invariant relative to the rows and the ids live after the
||| change: its rows are drawn from them, a row whose antecedents and
||| target are live is kept, and Rete/Refcount.idr's cascade of them is
||| still live. What a caller needs to reason about the rows and facts
||| the cascade keeps.
export
iret_12_2__external_final : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                            (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                            (wm1 : Rarc_5_6_4__wm) -> All (\f => Elem (lfac_2_5_1__val f) dom) wm1 -> Iret_4_4__keeps wm wm1 ->
                            ((g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)) -> Iret_4_4__unique wm1 ->
                            (wmF ** (tablesF ** (rowsF **
                              ( iret_12_2__phase p (MkTms (MkState wm1 (rarc_5_6_5__propagate p wm1 tables)) rows) = MkTms (MkState wmF tablesF) rowsF
                              , Iret_12_2__cascade_inv p dom rows (iret_11_3__fact_ids wm1) wmF tablesF rowsF ))))
iret_12_2__external_final p pos dom wm tables rows rinv rk wm1 wd keeps adds uniq1 =
  let (inv0, kind1) = iret_12_2__external_entry p pos dom wm tables rows rinv rk wm1 wd keeps adds uniq1
  in case iret_12_4__phase_n_kind (S (length rows)) p pos dom rows (iret_11_3__fact_ids wm1) wm1 (rarc_5_6_5__propagate p wm1 tables) rows inv0 kind1 of
       (wmF ** (tablesF ** (rowsF ** (eq, invF, _, _, _)))) => (wmF ** (tablesF ** (rowsF ** (eq, invF))))

--@derives [IRET.12.2]
||| And so the cascade after such a change keeps Rete/Refcount.idr's
||| cascade of the rows over the ids live after the change, the
||| never-justified ones as base: the half of the bridge a caller needs to
||| show that a fact survives.
export
iret_12_2__external_gfp : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                          (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                          Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                          (wm1 : Rarc_5_6_4__wm) -> All (\f => Elem (lfac_2_5_1__val f) dom) wm1 -> Iret_4_4__keeps wm wm1 ->
                          ((g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)) -> Iret_4_4__unique wm1 ->
                          Iret_12__sub (iret_12_2__cascade (iret_12_2__base rows (iret_11_3__fact_ids wm1)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm1))
                                       (iret_11_3__fact_ids (core (iret_12_2__phase p (MkTms (MkState wm1 (rarc_5_6_5__propagate p wm1 tables)) rows))).wm)
iret_12_2__external_gfp p pos dom wm tables rows rinv rk wm1 wd keeps adds uniq1 =
  case iret_12_2__external_final p pos dom wm tables rows rinv rk wm1 wd keeps adds uniq1 of
    (wmF ** (tablesF ** (rowsF ** (eq, invF)))) =>
      replace {p = \x => Iret_12__sub (iret_12_2__cascade (iret_12_2__base rows (iret_11_3__fact_ids wm1)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm1))
                                      (iret_11_3__fact_ids (core x).wm)}
              (sym eq) (gfpSub invF)

--@derives [RARC.5.6.4]
||| Applying an event keeps the run invariant and the target kinds.
export
rarc_5_6_4__apply_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (ev : Rarc_5_6_1__event) -> Rarc_5_6_1__event_in_dom dom ev ->
                        (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                        Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                        ( Iret_12__run_inv_s p dom (rarc_5_6_4__apply p ev (MkTms (MkState wm tables) rows))
                        , Iret_12_4__run_kind_s p (rarc_5_6_4__apply p ev (MkTms (MkState wm tables) rows)) )
rarc_5_6_4__apply_inv p pos dom (Assert k key pay) inDom wm tables rows rinv rk with (iret_19_1__assert_fact (life p k) [] k key pay wm) proof af
  rarc_5_6_4__apply_inv p pos dom (Assert k key pay) inDom wm tables rows rinv rk | Nothing = (rinv, rk)
  rarc_5_6_4__apply_inv p pos dom (Assert k key pay) inDom wm tables rows rinv rk | (Just wm1) =
    let (fresh, _) = lfac_2_5_3__fresh_id_free [] wm
    in case iret_19_1__emit_shape (life p k) [] k key pay wm wm1 af of
         Left eq =>
           case iret_12_2__external_cascade p pos dom wm tables rows rinv rk wm1
                  (replace {p = \w => All (\f => Elem (lfac_2_5_1__val f) dom) w} (sym eq) (lcyc_1_1__all_append (wmDom (runCore rinv)) [inDom]))
                  (replace {p = \w => Iret_4_4__keeps wm w} (sym eq) (iret_4_4__keeps_append wm _))
                  (replace {p = \w => (g : Lfac_1_7_1__fact) -> Elem g w -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)} (sym eq)
                     (\g, eg => case lcyc_1_1__elem_append_inv wm eg of
                        Left e => Left e
                        Right e1 => Right (replace {p = \x => rarc_5_6_4__is_live (fid x) wm = False} (sym (iret_12__elem_singleton e1)) fresh)))
                  (replace {p = \w => Iret_4_4__unique w} (sym eq) (iret_4_4__unique_append wm (runUniq rinv) _ fresh)) of
             (wmF ** (tablesF ** (rowsF ** (eq', rinvF, rkF, _, _)))) =>
               replace {p = \x => (Iret_12__run_inv_s p dom x, Iret_12_4__run_kind_s p x)} (sym eq') (rinvF, rkF)
         Right (old ** (_, eq)) =>
           case iret_12_2__external_cascade p pos dom wm tables rows rinv rk wm1
                  (replace {p = \w => All (\f => Elem (lfac_2_5_1__val f) dom) w} (sym eq)
                     (lcyc_1_1__all_append (lcyc_1_1__all_filter (\g => not (lfac_2_5_4__same_fact g old)) wm (wmDom (runCore rinv))) [inDom]))
                  (replace {p = \w => Iret_4_4__keeps wm w} (sym eq) (iret_4_4__keeps_replace wm (runUniq rinv) old _ fresh))
                  (replace {p = \w => (g : Lfac_1_7_1__fact) -> Elem g w -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)} (sym eq)
                     (\g, eg => case lcyc_1_1__elem_append_inv (rarc_5_6_4__remove_exact old wm) eg of
                        Left e => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h old)) wm e))
                        Right e1 => Right (replace {p = \x => rarc_5_6_4__is_live (fid x) wm = False} (sym (iret_12__elem_singleton e1)) fresh)))
                  (replace {p = \w => Iret_4_4__unique w} (sym eq) (iret_4_4__unique_replace wm (runUniq rinv) old _ fresh)) of
             (wmF ** (tablesF ** (rowsF ** (eq', rinvF, rkF, _, _)))) =>
               replace {p = \x => (Iret_12__run_inv_s p dom x, Iret_12_4__run_kind_s p x)} (sym eq') (rinvF, rkF)
rarc_5_6_4__apply_inv p pos dom (Retract i) inDom wm tables rows rinv rk with (rarc_5_6_4__lookup_fact i wm) proof lk
  rarc_5_6_4__apply_inv p pos dom (Retract i) inDom wm tables rows rinv rk | Nothing = (rinv, rk)
  rarc_5_6_4__apply_inv p pos dom (Retract i) inDom wm tables rows rinv rk | (Just f) =
    case iret_12_2__external_cascade p pos dom wm tables rows rinv rk (rarc_5_6_4__remove_exact f wm)
           (lcyc_1_1__all_filter (\g => not (lfac_2_5_4__same_fact g f)) wm (wmDom (runCore rinv)))
           (iret_4_4__keeps_filter wm (runUniq rinv) (\g => not (lfac_2_5_4__same_fact g f)))
           (\g, eg => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h f)) wm eg)))
           (iret_4_4__unique_filter wm (runUniq rinv) (\g => not (lfac_2_5_4__same_fact g f))) of
      (wmF ** (tablesF ** (rowsF ** (eq, rinvF, rkF, _, _)))) =>
        replace {p = \x => (Iret_12__run_inv_s p dom x, Iret_12_4__run_kind_s p x)} (sym eq) (rinvF, rkF)

-- ---------------------------------------------------------------------
-- Boundaries and canonical replays
-- ---------------------------------------------------------------------

--@derives [LFST.9.2.1]
||| One boundary keeps the invariant, however the pump halted.
export
lfst_9_2_1__boundary_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                           ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                           (fuel : Nat) -> (ev : Rarc_5_6_1__event) -> Rarc_5_6_1__event_in_dom dom ev ->
                           (s : Iret_12__state) -> Iret_12__run_inv_s p dom s -> Iret_12_4__run_kind_s p s ->
                           (Iret_12__run_inv_s p dom (lfst_9_2_1__boundary p fuel ev s), Iret_12_4__run_kind_s p (lfst_9_2_1__boundary p fuel ev s))
lfst_9_2_1__boundary_inv p pos ct dom litsIn fuel ev evd (MkTms (MkState wm tables) rows) rinv rk =
  let (rinv1, rk1) = rarc_5_6_4__apply_inv p pos dom ev evd wm tables rows rinv rk
  in iret_11_4__pump_inv p pos ct dom litsIn fuel (rarc_5_6_4__apply p ev (MkTms (MkState wm tables) rows)) rinv1 rk1

--@derives [LFST.9.2.1]
||| A canonical replay keeps the invariant to its end -- so at every
||| boundary along the way.
export
lfst_9_2_1__canonical_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                            ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                            (s : Iret_12__state) -> (evs : List Rarc_5_6_1__event) -> (s' : Iret_12__state) ->
                            Lfst_9_2_1__canonical p s evs s' -> All (Rarc_5_6_1__event_in_dom dom) evs ->
                            Iret_12__run_inv_s p dom s -> Iret_12_4__run_kind_s p s -> (Iret_12__run_inv_s p dom s', Iret_12_4__run_kind_s p s')
lfst_9_2_1__canonical_inv p pos ct dom litsIn s [] s CanonNil [] rinv rk = (rinv, rk)
lfst_9_2_1__canonical_inv p pos ct dom litsIn s (ev :: evs) s' (CanonStep fuel _ rest) (evd :: evds) rinv rk =
  let (rinv1, rk1) = lfst_9_2_1__boundary_inv p pos ct dom litsIn fuel ev evd s rinv rk
  in lfst_9_2_1__canonical_inv p pos ct dom litsIn (lfst_9_2_1__boundary p fuel ev s) evs s' rest evds rinv1 rk1

--@derives [LFST.9.2.1]
||| THE CANONICAL REPLAY EXISTS. For a positive program certified as
||| [LCYC.3.1.1] admits it, from an invariant state every input sequence
||| has a replay in which each pump reaches quiescence, and the invariant
||| holds at its end.
export
lfst_9_2_1__canonical_exists : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                               ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                               (s : Iret_12__state) -> Iret_12__run_inv_s p dom s -> Iret_12_4__run_kind_s p s ->
                               (evs : List Rarc_5_6_1__event) -> All (Rarc_5_6_1__event_in_dom dom) evs ->
                               (s' ** (Lfst_9_2_1__canonical p s evs s', Iret_12__run_inv_s p dom s', Iret_12_4__run_kind_s p s'))
lfst_9_2_1__canonical_exists p pos ct dom litsIn s rinv rk [] [] = (s ** (CanonNil, rinv, rk))
lfst_9_2_1__canonical_exists p pos ct dom litsIn (MkTms (MkState wm tables) rows) rinv rk (ev :: evs) (evd :: evds) =
  let (rinv1, rk1) = rarc_5_6_4__apply_inv p pos dom ev evd wm tables rows rinv rk
  in let (fuel ** (quiet, rinv2, rk2)) = rarc_5_6_6__pump_quiesces p pos ct dom litsIn (rarc_5_6_4__apply p ev (MkTms (MkState wm tables) rows)) rinv1 rk1
  in let (s' ** (rest, rinv', rk')) = lfst_9_2_1__canonical_exists p pos ct dom litsIn (lfst_9_2_1__boundary p fuel ev (MkTms (MkState wm tables) rows)) rinv2 rk2 evs evds
  in (s' ** (CanonStep fuel quiet rest, rinv', rk'))

--@derives [LCYC.1.1]
||| The core invariant is monotone in the domain.
export
lcyc_1_1__inv_widen : (p : Lcyc_3_2_1__program) -> (dom, dom' : List (Nat, Nat)) -> ((x : (Nat, Nat)) -> Elem x dom -> Elem x dom') ->
                      (st : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom st -> Lcyc_1_1__inv p dom' st
lcyc_1_1__inv_widen p dom dom' sub st inv =
  MkInv (lcyc_1_1__all_imp (wm st) (\f, e => sub _ e) (wmDom inv))
        (tokLen inv)
        (\ri, r, ts, nr, nt => lcyc_1_1__all_imp ts (\t, ok => (fst ok, lcyc_1_1__all_imp (tfacts t) (\f, e => sub _ e) (snd ok))) (tokOk inv ri r ts nr nt))
        (settled inv)

--@derives [LFST.9.2.1]
--@derives [LCYC.3.1.1]
||| FROM THE INPUT. A positive program certified as [LCYC.3.1.1] admits
||| it replays any canonical stream from any input with unique ids, every
||| pump quiescent, the run invariant at every boundary. The domain is the
||| program's literals, the input's values and the asserted values.
export
lfst_9_2_1__canonical_from_input : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                                   ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                                   (wm0 : Rarc_5_6_4__wm) -> All (\f => Elem (lfac_2_5_1__val f) dom) wm0 -> Iret_4_4__unique wm0 ->
                                   (evs : List Rarc_5_6_1__event) -> All (Rarc_5_6_1__event_in_dom dom) evs ->
                                   (s' ** (Lfst_9_2_1__canonical p (rarc_5_6_5__init_tms p wm0) evs s', Iret_12__run_inv_s p dom s', Iret_12_4__run_kind_s p s'))
lfst_9_2_1__canonical_from_input p pos ct dom litsIn wm0 wd uniq evs evds =
  lfst_9_2_1__canonical_exists p pos ct dom litsIn (rarc_5_6_5__init_tms p wm0)
    (rarc_5_6_5__init_tms_inv p dom wm0
       (lcyc_1_1__inv_widen p (lcyc_1_1__dom_of (lcyc_3_1_1__tms_to_core p ct) wm0) dom widen (rarc_5_6_5__init_state p wm0)
          (lcyc_1_1__init_inv p (lcyc_3_1_1__tms_to_core p ct) wm0))
       uniq)
    (\row, e => absurd e) evs evds
  where
    widen : (x : (Nat, Nat)) -> Elem x (lcyc_1_1__dom_of (lcyc_3_1_1__tms_to_core p ct) wm0) -> Elem x dom
    widen x e = case lcyc_1_1__elem_append_inv (tmsLits ct) e of
      Left l => litsIn x l
      Right r => case lcyc_1_1__elem_map_inv (\f => lfac_2_5_1__val f) wm0 r of
        (f ** (ef, eq)) => replace {p = \v => Elem v dom} eq (lcyc_1_1__all_lookup wd ef)

-- ---------------------------------------------------------------------
-- What holds at a boundary
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| AT A BOUNDARY -- at every state between actions -- the live ids are
||| exactly Rete/Refcount.idr's cascade of the engine's own table over
||| themselves: every row is live, so the live set is self-supported, and
||| the cascade is the greatest self-supported subset.
export
iret_12_2__boundary_fixpoint : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                               Iret_12__run_inv p dom wm tables rows ->
                               ( Iret_12__sub (iret_11_3__fact_ids wm) (iret_12_2__cascade (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
                               , Iret_12__sub (iret_12_2__cascade (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm)) (iret_11_3__fact_ids wm) )
iret_12_2__boundary_fixpoint p dom wm tables rows rinv =
  let inv0 : Iret_12_2__cascade_inv p dom rows (iret_11_3__fact_ids wm) wm tables rows
      inv0 = MkCascadeInv (runCore rinv) (runUniq rinv) (\row, e => e) (\i, e => e) (runFacts rinv)
               (\row, e, _, _ => (e, fst (iret_12__run_row_live p dom wm tables rows rinv row e)))
               (iret_12_2__cascade_sub (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
               (iret_12_2__base_row rows (iret_11_3__fact_ids wm))
  in ( iret_12_2__cascade_greatest (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) (iret_11_3__fact_ids wm)
         (\i, e => e) (iret_12_2__fixed_post p dom rows (iret_11_3__fact_ids wm) wm tables rows inv0 (runLive rinv))
     , iret_12_2__cascade_sub (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) )

--@derives [LLOG.2.5]
||| AT A BOUNDARY the well-founded facts are live, and if any live fact is
||| not well-founded, the live facts outside the well-founded set are an
||| unfounded set -- exactly what recompute-and-diff at the boundary would
||| retract, and what the refcount keeps.
export
llog_2_5__boundary_unfounded : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                               Iret_12__run_inv p dom wm tables rows ->
                               ( Iret_12__sub (llog_2_5__well_founded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm)) (iret_11_3__fact_ids wm)
                               , (t : Nat) -> iret_12__elem t (iret_11_3__fact_ids wm) = True ->
                                   iret_12__elem t (llog_2_5__well_founded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm)) = False ->
                                   Llog_2_5__unfounded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows)
                                     (iret_12_2__cascade (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
                                     (filter (llog_2_5__outside (llog_2_5__well_founded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm)))
                                             (iret_12_2__cascade (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))) )
llog_2_5__boundary_unfounded p dom wm tables rows rinv =
  ( llog_2_5__wf_sub_all (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm)
  , \t, tl, tw => iret_12_2__cascade_unfounded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) (iret_11_3__fact_ids wm)
                    (\i, e => e) t (fst (iret_12_2__boundary_fixpoint p dom wm tables rows rinv) t tl) tw )

--@derives [IRET.12.3]
||| ON ACYCLIC SUPPORT the live set at a boundary is exactly the
||| well-founded set: recompute-and-diff would change nothing, as the
||| refcount is exact there.
export
iret_12_3__boundary_ranked : (rank : Nat -> Nat) -> (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             Iret_12__run_inv p dom wm tables rows -> Iret_12_3__ranked rank (iret_12_4__justifs rows) ->
                             ( Iret_12__sub (iret_11_3__fact_ids wm) (llog_2_5__well_founded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
                             , Iret_12__sub (llog_2_5__well_founded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm)) (iret_11_3__fact_ids wm) )
iret_12_3__boundary_ranked rank p dom wm tables rows rinv rk =
  let (cw, _) = iret_12_3__ranked_agree rank (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) (iret_11_3__fact_ids wm) rk (\i, e => e)
                  (llog_2_5__wf_sub_all (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
  in let (lc, _) = iret_12_2__boundary_fixpoint p dom wm tables rows rinv
  in (\i, e => cw i (lc i e), llog_2_5__wf_sub_all (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))

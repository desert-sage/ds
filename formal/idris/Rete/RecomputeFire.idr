-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Recompute-and-diff in the fire loop: the step of Rete/RecomputeDiff.idr
||| run after every action rather than only at the pump boundary.
|||
||| NO CLAUSE STATES THIS, as for Rete/RecomputeDiff.idr: the engine is `--@gap`,
||| and what it proves about [LLOG.2.5] is tied there.
|||
||| WHY THE BOUNDARY IS NOT ENOUGH. After an adapter retraction or a TTL
||| sweep nothing fires before the boundary, so a step there is exact. A
||| rule's `withdraw` is different: it can end the last grounded support of
||| a recursive closure in the middle of a pump, and every later firing of
||| that pump sees the unfounded facts the refcount keeps -- and can emit
||| on them. Running the step after every action closes that window.
|||
||| THE ENGINE. Rete/FireLoopTms.idr's, with one change: after each action
||| and its cascade, recompute-and-diff. The pop, the actions and their
||| cascades are unchanged; each result is taken apart and rebuilt as in
||| Rete/FireLoopTms.idr.
|||
||| WHAT IS PROVED, on positive programs:
|||
|||   * one action keeps the firing invariant of Rete/TmsRun.idr, the
|||     firing activation tracked, and leaves every live fact grounded --
|||     well-founded against the state's own table (`gap__action_rd`); so
|||     does the whole RHS, a firing, and every run
|||     (`gap__step_n_rd_inv`);
|||   * from an input with unique ids, every state a run reaches satisfies
|||     the run invariant and is grounded (`llog_2_5__rd_run_grounded`):
|||     [LLOG.2.5], read well-foundedly, at every state between actions;
|||   * on a program [LCYC.3.1.1] admits, the engine takes
|||     exactly the refcount engine's steps (`gap__step_n_rd_certified`),
|||     since the step is the identity there (`gap__rd_certified_identity`);
|||     so it terminates (`gap__rd_certified_terminates`) and changes no
|||     admitted run.
|||
||| The executed trace that separates the two engines -- a `withdraw` mid-
||| pump, and a later rule emitting on the unfounded facts under the
||| refcount but not under this engine -- is in Main.idr's runner, being
||| too large for `Refl`.
|||
||| SCOPE. Positive programs, as for the run invariant. The recursive
||| certificate's termination (`+recursive`) is not here: under
||| [LCYC.3.1.1]'s the step is the identity and termination is inherited.
module Rete.RecomputeFire

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Rete.PumpBoundary
import Rete.RecomputeDiff
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Certificate
import Lcyc.Termination
import Lcyc.TmsTermination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat

%default total

-- ---------------------------------------------------------------------
-- The engine
-- ---------------------------------------------------------------------

--@gap
||| One action: the refcount engine's action and cascade, then
||| recompute-and-diff.
public export
gap__do_action_rd : Lcyc_3_2_1__program -> Nat -> Iret_11__tok -> Lgra_10_1__action -> Iret_12__state -> Iret_12__state
gap__do_action_rd p r tok a s = gap__recompute_diff p (rarc_5_6_7__do_action_tms p r tok a s)

--@gap
public export
gap__do_actions_rd : Lcyc_3_2_1__program -> Nat -> Iret_11__tok -> List Lgra_10_1__action -> Iret_12__state -> Iret_12__state
gap__do_actions_rd p r tok [] s = s
gap__do_actions_rd p r tok (a :: as) s = case gap__do_action_rd p r tok a s of
  MkTms st rows => gap__do_actions_rd p r tok as (MkTms st rows)

--@gap
||| One firing: the refcount engine's selection and pop, then the RHS with
||| the step after every action.
public export
gap__step_rd : Lcyc_3_2_1__program -> Iret_12__state -> Maybe Iret_12__state
gap__step_rd p (MkTms (MkState wm tables) rows) = case ldet_5_1__select_next tables of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (rules p) of
    Nothing => Nothing
    Just rule => case rarc_5_6_5__nth j (iret_11__table_at r tables) of
      Nothing => Nothing
      Just tok => Just (gap__do_actions_rd p r tok (actions rule)
                          (MkTms (MkState wm (idat_6_2_2__mark_fired r j tables)) rows))

--@gap
public export
gap__step_n_rd : Lcyc_3_2_1__program -> Nat -> Iret_12__state -> Maybe Iret_12__state
gap__step_n_rd p Z s = Just s
gap__step_n_rd p (S n) s = case gap__step_rd p s of
  Nothing => Nothing
  Just (MkTms st rows) => gap__step_n_rd p n (MkTms st rows)

--@gap
||| Run to quiescence or out of fuel, counting firings.
public export
gap__run_rd : Lcyc_3_2_1__program -> Nat -> Iret_12__state -> (Iret_12__state, Iret_11_4__halt, Nat)
gap__run_rd p Z s = (s, FuelOut, 0)
gap__run_rd p (S fuel) s = case gap__step_rd p s of
  Nothing => (s, Quiescent, 0)
  Just s' => let (t, h, n) = gap__run_rd p fuel s' in (t, h, S n)

-- ---------------------------------------------------------------------
-- Grounded: every live fact well-founded against the state's own table
-- ---------------------------------------------------------------------

--@derives [LLOG.2.5]
||| Every live fact is in the well-founded set of the state's own table
||| over its live facts: each has a justification grounded in the facts
||| nothing justifies. [LLOG.2.5], read well-foundedly. (The converse, that
||| the well-founded set is live, always holds: `llog_2_5__wf_sub_all`.)
public export
Llog_2_5__grounded : Rarc_5_6_4__wm -> Iret_12_4__table -> Type
Llog_2_5__grounded w rows = Iret_12__sub (iret_11_3__fact_ids w) (gap__rd_wf rows w)

--@derives [LLOG.2.5]
||| The same, of a state.
public export
Llog_2_5__grounded_s : Iret_12__state -> Type
Llog_2_5__grounded_s s = Llog_2_5__grounded (wm (core s)) (deps s)

--@derives [LLOG.2.5]
||| With an empty table every live fact is base, so grounded: the start of
||| a run.
export
llog_2_5__grounded_empty : (w : Rarc_5_6_4__wm) -> Llog_2_5__grounded w []
llog_2_5__grounded_empty w t tl =
  llog_2_5__base_in_wf (iret_12_2__base [] (iret_11_3__fact_ids w)) (iret_12_4__justifs []) (iret_11_3__fact_ids w) t tl
    (iret_12__elem_filter (\i => not (iret_12__elem i (iret_12_4__targets []))) (iret_11_3__fact_ids w) t tl Refl)

-- ---------------------------------------------------------------------
-- The step keeps a tracked activation and grounds the state
-- ---------------------------------------------------------------------

--@gap
||| THE STEP BETWEEN ACTIONS. From a state satisfying the run invariant,
||| with some activation tracked, retracting any list that holds no
||| well-founded id and every live id outside the well-founded set: the
||| run invariant holds after, the activation is still tracked, and every
||| live fact is grounded. No target kinds needed -- the bridge's cascade
||| with a tracked activation (`iret_12_2__cascade_tracked`) does the work,
||| so this holds inside a firing.
export
gap__rd_core : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
               (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
               Iret_12__run_inv p dom wm tables rows -> (v : Iret_12_4__row) -> Iret_7_8__tracked p wm tables v -> (gone : List Nat) ->
               ((t : Nat) -> iret_12__elem t gone = True -> iret_12__elem t (gap__rd_wf rows wm) = False) ->
               ((t : Nat) -> iret_12__elem t (iret_11_3__fact_ids wm) = True -> iret_12__elem t (gap__rd_wf rows wm) = False -> iret_12__elem t gone = True) ->
               (wmF ** (tablesF ** (rowsF **
                 ( gap__rd_after p wm tables rows gone = MkTms (MkState wmF tablesF) rowsF
                 , Iret_12__run_inv p dom wmF tablesF rowsF
                 , Iret_7_8__tracked p wmF tablesF v
                 , Llog_2_5__grounded wmF rowsF ))))
gap__rd_core p pos dom wm tables rows rinv v tr [] hG1 hG2 =
  (wm ** (tables ** (rows ** (Refl, rinv, tr, \t, tl => case iret_12__bool_split (iret_12__elem t (gap__rd_wf rows wm)) of
                                                          Left y => y
                                                          Right n => absurd (hG2 t tl n)))))
gap__rd_core p pos dom wm tables rows rinv v tr (g :: gs) hG1 hG2 =
  let keeps : Iret_4_4__keeps wm (iret_12_2__retract_ids (g :: gs) wm)
      keeps = iret_4_4__keeps_filter wm (runUniq rinv) (\h => not (rarc_5_6_5__elem (fid h) (g :: gs)))
      adds : (h : Lfac_1_7_1__fact) -> Elem h (iret_12_2__retract_ids (g :: gs) wm) -> Either (Elem h wm) (rarc_5_6_4__is_live (fid h) wm = False)
      adds h eh = Left (fst (lcyc_1_1__elem_filter_inv (\x => not (rarc_5_6_5__elem (fid x) (g :: gs))) wm eh))
      rf : (row : Iret_12_4__row) -> Elem row rows ->
           iret_7_8__activation_live (rarc_5_6_5__propagate p (iret_12_2__retract_ids (g :: gs) wm) tables) row = True ->
           Iret_12_4__row_facts p (iret_12_2__retract_ids (g :: gs) wm) row
      rf row e act1 = iret_12_2__entry_read_old p dom wm tables rows rinv (iret_12_2__retract_ids (g :: gs) wm) keeps adds row e
                        (iret_7_8__live_before_propagate p (iret_12_2__retract_ids (g :: gs) wm) tables row act1)
      rl : (row : Iret_12_4__row) -> Elem row rows -> iret_12__all_in (rids row) (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm)) = True ->
           rarc_5_6_4__is_live (rtarget row) (iret_12_2__retract_ids (g :: gs) wm) = True ->
           iret_7_8__activation_live (rarc_5_6_5__propagate p (iret_12_2__retract_ids (g :: gs) wm) tables) row = True
      rl row e al _ = let (act, _) = iret_12__run_row_live p dom wm tables rows rinv row e
                      in iret_7_8__live_after_propagate p pos dom (MkState wm tables) (runCore rinv) (iret_12_2__retract_ids (g :: gs) wm) row
                           (iret_12_2__entry_read_old p dom wm tables rows rinv (iret_12_2__retract_ids (g :: gs) wm) keeps adds row e act) al act
  in case iret_12_2__cascade_tracked p pos dom (iret_12_2__retract_ids (g :: gs) wm) (rarc_5_6_5__propagate p (iret_12_2__retract_ids (g :: gs) wm) tables) rows
            (lcyc_1_1__propagate_inv p dom (MkState wm tables) (runCore rinv) (iret_12_2__retract_ids (g :: gs) wm)
               (lcyc_1_1__all_filter (\h => not (rarc_5_6_5__elem (fid h) (g :: gs))) wm (wmDom (runCore rinv))))
            (iret_4_4__unique_filter wm (runUniq rinv) (\h => not (rarc_5_6_5__elem (fid h) (g :: gs))))
            rf rl v
            (iret_7_8__tracked_retract p pos dom wm tables (runCore rinv) (runUniq rinv) (g :: gs) v tr) of
       (wmF ** (tablesF ** (rowsF ** (eq, invF, fixedF, trF)))) =>
         let sub01 : Iret_12__sub (gap__rd_wf rows wm) (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm))
             sub01 t tw =
               let tl = llog_2_5__wf_sub_all (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) t tw
               in let (f ** (ef, ft)) = iret_12_4__live_id t wm tl
               in let twf : (iret_12__elem (fid f) (gap__rd_wf rows wm) = True)
                      twf = replace {p = \i => iret_12__elem i (gap__rd_wf rows wm) = True} (sym ft) tw
               in let ng : (iret_12__elem (fid f) (g :: gs) = False)
                      ng = iret_12__bool_false_of _ (\ig => lcyc_1_1__bool_not_both _ twf (hG1 (fid f) ig))
               in replace {p = \i => iret_12__elem i (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm)) = True} ft
                    (iret_12_4__id_live f (iret_12_2__retract_ids (g :: gs) wm) (iret_12_2__retract_keeps (g :: gs) wm f ef ng))
             fwd : Iret_12__sub (iret_11_3__fact_ids wmF) (gap__rd_wf rows wm)
             fwd t tl =
               let (f ** (ef, ft)) = iret_12_4__live_id t (iret_12_2__retract_ids (g :: gs) wm) (liveSub invF t tl)
               in let (efw, ng) = iret_12_2__retract_inv (g :: gs) wm f ef
               in case iret_12__bool_split (iret_12__elem (fid f) (gap__rd_wf rows wm)) of
                    Left y => replace {p = \i => iret_12__elem i (gap__rd_wf rows wm) = True} ft y
                    Right n => void (lcyc_1_1__bool_not_both _ (hG2 (fid f) (iret_12_4__id_live f wm efw) n) ng)
             bwd : Iret_12__sub (gap__rd_wf rows wm) (iret_11_3__fact_ids wmF)
             bwd t tw = gfpSub invF t
                          (llog_2_5__wf_in_cascade_of (iret_12_2__base rows (iret_11_3__fact_ids wm))
                             (iret_12_2__base rows (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm)))
                             (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm))
                             sub01
                             (iret_12_2__base_shrink rows (iret_11_3__fact_ids wm) (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm)))
                             t tw)
         in (wmF ** (tablesF ** (rowsF **
              ( eq
              , MkRunInv (coreInv invF) (uniq invF) (\row, e, act => rowFacts invF row (rowsSub invF row e) act) fixedF
              , trF
              , \t, tl => llog_2_5__wf_grow rows rowsF wm wmF (rowsSub invF) (\row, e, a, l => fst (rowLive invF row e a l)) fwd bwd t (fwd t tl) ))))

-- ---------------------------------------------------------------------
-- One action, the RHS, a firing, a run
-- ---------------------------------------------------------------------

--@gap
||| ONE ACTION. From the firing invariant: the refcount engine's action and
||| cascade (`iret_12_2__action_cascade`), then the step; the firing
||| invariant holds again and every live fact is grounded.
export
gap__action_rd : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                 (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                 (tok : Iret_11__tok) -> lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok) ->
                 (a : Lgra_10_1__action) -> Elem a (actions rule) ->
                 (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                 Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm tables rows ->
                 (wmF ** (tablesF ** (rowsF **
                   ( gap__do_action_rd p r tok a (MkTms (MkState wm tables) rows) = MkTms (MkState wmF tablesF) rowsF
                   , Iret_12__fire_inv p dom r (iret_11_3__ids tok) wmF tablesF rowsF
                   , Llog_2_5__grounded wmF rowsF ))))
gap__action_rd p pos dom range r rule nr tok bk bd a ea wm tables rows finv =
  case iret_12_2__action_cascade p pos dom range r rule nr tok bk bd a ea wm tables rows finv of
    (wm1 ** (tables1 ** (wmA ** (tablesA ** (rowsA ** (_, eqA, _, _, finvA)))))) =>
      case gap__rd_core p pos dom wmA tablesA rowsA (fireRun finvA) (MkRow r (iret_11_3__ids tok) 0) (fireTok finvA) (gap__rd_gone rowsA wmA)
             (\t, e => snd (gap__rd_gone_inv rowsA wmA t e)) (gap__rd_gone_of rowsA wmA) of
        (wmF ** (tablesF ** (rowsF ** (eqF, rinvF, trF, grF)))) =>
          (wmF ** (tablesF ** (rowsF ** (trans (cong (gap__recompute_diff p) eqA) eqF, MkFireInv rinvF trF, grF))))

--@gap
||| One more action at the front of an RHS, when the first is known.
export
gap__actions_rd_succ : (p : Lcyc_3_2_1__program) -> (r : Nat) -> (tok : Iret_11__tok) -> (a : Lgra_10_1__action) -> (as : List Lgra_10_1__action) ->
                       (s : Iret_12__state) -> (st : Rarc_5_6_5__state) -> (rows : Iret_12_4__table) ->
                       gap__do_action_rd p r tok a s = MkTms st rows ->
                       gap__do_actions_rd p r tok (a :: as) s = gap__do_actions_rd p r tok as (MkTms st rows)
gap__actions_rd_succ p r tok a as s st rows eq with (gap__do_action_rd p r tok a s)
  gap__actions_rd_succ p r tok a as s st rows eq | (MkTms st' rows') = cong (gap__do_actions_rd p r tok as) eq

--@gap
||| The whole RHS keeps the firing invariant and groundedness.
export
gap__actions_rd_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                      (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                      (tok : Iret_11__tok) -> lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok) ->
                      (as : List Lgra_10_1__action) -> All (\a => Elem a (actions rule)) as ->
                      (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                      Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm tables rows -> Llog_2_5__grounded wm rows ->
                      (wm' ** (tables' ** (rows' **
                        ( gap__do_actions_rd p r tok as (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                        , Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm' tables' rows'
                        , Llog_2_5__grounded wm' rows' ))))
gap__actions_rd_inv p pos dom range r rule nr tok bk bd [] [] wm tables rows finv gr = (wm ** (tables ** (rows ** (Refl, finv, gr))))
gap__actions_rd_inv p pos dom range r rule nr tok bk bd (a :: as) (ea :: eas) wm tables rows finv gr =
  case gap__action_rd p pos dom range r rule nr tok bk bd a ea wm tables rows finv of
    (wm1 ** (tables1 ** (rows1 ** (eq, finv1, gr1)))) =>
      case gap__actions_rd_inv p pos dom range r rule nr tok bk bd as eas wm1 tables1 rows1 finv1 gr1 of
        (wm2 ** (tables2 ** (rows2 ** (eq2, finv2, gr2)))) =>
          (wm2 ** (tables2 ** (rows2 ** (trans (gap__actions_rd_succ p r tok a as (MkTms (MkState wm tables) rows) (MkState wm1 tables1) rows1 eq) eq2, finv2, gr2))))

--@gap
||| One firing keeps the run invariant and groundedness: the pop changes
||| neither working memory nor the table, then the RHS.
export
gap__step_rd_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                   (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                   Iret_12__run_inv p dom wm tables rows -> Llog_2_5__grounded wm rows ->
                   (s' : Iret_12__state) -> gap__step_rd p (MkTms (MkState wm tables) rows) = Just s' ->
                   (Iret_12__run_inv_s p dom s', Llog_2_5__grounded_s s')
gap__step_rd_inv p pos dom range wm tables rows rinv gr s' eq with (ldet_5_1__select_next tables) proof sel
  gap__step_rd_inv p pos dom range wm tables rows rinv gr s' eq | Nothing = absurd eq
  gap__step_rd_inv p pos dom range wm tables rows rinv gr s' eq | (Just (r, j)) with (rarc_5_6_5__nth r (rules p)) proof nr
    gap__step_rd_inv p pos dom range wm tables rows rinv gr s' eq | (Just (r, j)) | Nothing = absurd eq
    gap__step_rd_inv p pos dom range wm tables rows rinv gr s' eq | (Just (r, j)) | (Just rule)
      with (rarc_5_6_5__nth j (iret_11__table_at r tables)) proof ntok
      gap__step_rd_inv p pos dom range wm tables rows rinv gr s' eq | (Just (r, j)) | (Just rule) | Nothing = absurd eq
      gap__step_rd_inv p pos dom range wm tables rows rinv gr s' eq | (Just (r, j)) | (Just rule) | (Just tok) =
        let (ts ** (t ** (nt, njt, _))) = ldet_5_1__select_next_pending tables r j sel
        in let njtok : (rarc_5_6_5__nth j ts = Just tok)
               njtok = replace {p = \tbl => rarc_5_6_5__nth j tbl = Just tok} (iret_11__table_at_nth r tables ts nt) ntok
               bk : (lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule)
               bk = fst (lcyc_1_1__all_lookup (tokOk (runCore rinv) r rule ts nr nt) (lcyc_1_1__nth_elem j ts njtok))
               bd : All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok)
               bd = snd (lcyc_1_1__all_lookup (tokOk (runCore rinv) r rule ts nr nt) (lcyc_1_1__nth_elem j ts njtok))
        in case gap__actions_rd_inv p pos dom range r rule nr tok bk bd (actions rule) (lcyc_1_1__all_from_elem (actions rule) (\a, e => e))
                  wm (idat_6_2_2__mark_fired r j tables) rows (iret_11_4__fire_start p pos dom wm tables rows rinv r j rule nr ts nt tok njtok) gr of
             (wm' ** (tables' ** (rows' ** (eq', finv', gr')))) =>
               replace {p = \s => (Iret_12__run_inv_s p dom s, Llog_2_5__grounded_s s)} (trans (sym eq') (iret_11_4__just_inj eq)) (fireRun finv', gr')

--@gap
||| Every state of a run keeps the run invariant and groundedness.
export
gap__step_n_rd_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom -> (n : Nat) ->
                     (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                     Iret_12__run_inv p dom wm tables rows -> Llog_2_5__grounded wm rows ->
                     (s' : Iret_12__state) -> gap__step_n_rd p n (MkTms (MkState wm tables) rows) = Just s' ->
                     (Iret_12__run_inv_s p dom s', Llog_2_5__grounded_s s')
gap__step_n_rd_inv p pos dom range Z wm tables rows rinv gr s' eq =
  replace {p = \s => (Iret_12__run_inv_s p dom s, Llog_2_5__grounded_s s)} (iret_11_4__just_inj eq) (rinv, gr)
gap__step_n_rd_inv p pos dom range (S n) wm tables rows rinv gr s' eq with (gap__step_rd p (MkTms (MkState wm tables) rows)) proof st
  gap__step_n_rd_inv p pos dom range (S n) wm tables rows rinv gr s' eq | Nothing = absurd eq
  gap__step_n_rd_inv p pos dom range (S n) wm tables rows rinv gr s' eq | (Just (MkTms (MkState wm1 tables1) rows1)) =
    let (rinv1, gr1) = gap__step_rd_inv p pos dom range wm tables rows rinv gr (MkTms (MkState wm1 tables1) rows1) st
    in gap__step_n_rd_inv p pos dom range n wm1 tables1 rows1 rinv1 gr1 s' eq

--@derives [LLOG.2.5]
||| [LLOG.2.5] AT EVERY STATE OF EVERY RUN. From an input with unique ids,
||| every state the engine with recompute-and-diff reaches satisfies the
||| run invariant, and every live fact in it has a justification grounded
||| in the facts nothing justifies -- including after a rule's `withdraw`
||| in the middle of a pump, where the refcount engine can keep an
||| unfounded closure live for the rest of the pump.
export
llog_2_5__rd_run_grounded : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                            (wm0 : Rarc_5_6_4__wm) -> Lcyc_1_1__inv p dom (rarc_5_6_5__init_state p wm0) -> Iret_4_4__unique wm0 ->
                            (n : Nat) -> (s' : Iret_12__state) -> gap__step_n_rd p n (rarc_5_6_5__init_tms p wm0) = Just s' ->
                            (Iret_12__run_inv_s p dom s', Llog_2_5__grounded_s s')
llog_2_5__rd_run_grounded p pos dom range wm0 inv uniq n s' eq =
  gap__step_n_rd_inv p pos dom range n wm0 (rarc_5_6_5__propagate p wm0 (map (const []) (rules p))) []
    (rarc_5_6_5__init_tms_inv p dom wm0 inv uniq) (llog_2_5__grounded_empty wm0) s' eq

-- ---------------------------------------------------------------------
-- On the admitted fragment the two engines are one
-- ---------------------------------------------------------------------

--@gap
||| One action of a certified program: the step after it changes nothing,
||| so the action is the refcount engine's; the firing invariant and the
||| termination measure's data carry on.
export
gap__action_rd_certified : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                           ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                           (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                           (tok : Iret_11__tok) -> lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok) ->
                           (a : Lgra_10_1__action) -> Elem a (actions rule) ->
                           (wm0 : Rarc_5_6_4__wm) -> (tables0 : List (List Iret_11__tok)) ->
                           (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                           Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm tables rows -> Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm tables rows ->
                           (wm' ** (tables' ** (rows' **
                             ( gap__do_action_rd p r tok a (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                             , rarc_5_6_7__do_action_tms p r tok a (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                             , Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm' tables' rows'
                             , Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm' tables' rows' ))))
gap__action_rd_certified p pos ct dom litsIn r rule nr tok bk bd a ea wm0 tables0 wm tables rows finv fm =
  case lcyc_3_1_1__action_measure p pos ct dom litsIn r rule nr tok bk bd a ea wm0 tables0 wm tables rows finv fm of
    (wmA ** (tablesA ** (rowsA ** (eqA, finvA, fmA)))) =>
      (wmA ** (tablesA ** (rowsA **
        ( trans (cong (gap__recompute_diff p) eqA) (gap__rd_certified_identity p ct dom (MkTms (MkState wmA tablesA) rowsA) (fireRun finvA) (fmKind fmA))
        , eqA, finvA, fmA ))))

--@gap
||| The whole RHS of a certified program: the two engines agree.
export
gap__actions_rd_certified : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                            ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                            (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                            (tok : Iret_11__tok) -> lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok) ->
                            (as : List Lgra_10_1__action) -> All (\a => Elem a (actions rule)) as ->
                            (wm0 : Rarc_5_6_4__wm) -> (tables0 : List (List Iret_11__tok)) ->
                            (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm tables rows -> Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm tables rows ->
                            gap__do_actions_rd p r tok as (MkTms (MkState wm tables) rows) = rarc_5_6_7__do_actions_tms p r tok as (MkTms (MkState wm tables) rows)
gap__actions_rd_certified p pos ct dom litsIn r rule nr tok bk bd [] [] wm0 tables0 wm tables rows finv fm = Refl
gap__actions_rd_certified p pos ct dom litsIn r rule nr tok bk bd (a :: as) (ea :: eas) wm0 tables0 wm tables rows finv fm =
  case gap__action_rd_certified p pos ct dom litsIn r rule nr tok bk bd a ea wm0 tables0 wm tables rows finv fm of
    (wm1 ** (tables1 ** (rows1 ** (eqR, eqT, finv1, fm1)))) =>
      trans (gap__actions_rd_succ p r tok a as (MkTms (MkState wm tables) rows) (MkState wm1 tables1) rows1 eqR)
        (trans (gap__actions_rd_certified p pos ct dom litsIn r rule nr tok bk bd as eas wm0 tables0 wm1 tables1 rows1 finv1 fm1)
               (sym (rarc_5_6_7__actions_tms_succ p r tok a as (MkTms (MkState wm tables) rows) (MkState wm1 tables1) rows1 eqT)))

--@gap
||| One firing of a certified program: the two engines agree.
export
gap__step_rd_certified : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                         ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                         (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                         Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                         gap__step_rd p (MkTms (MkState wm tables) rows) = iret_11_4__step_tms p (MkTms (MkState wm tables) rows)
gap__step_rd_certified p pos ct dom litsIn wm tables rows rinv rk with (ldet_5_1__select_next tables) proof sel
  gap__step_rd_certified p pos ct dom litsIn wm tables rows rinv rk | Nothing = Refl
  gap__step_rd_certified p pos ct dom litsIn wm tables rows rinv rk | (Just (r, j)) with (rarc_5_6_5__nth r (rules p)) proof nr
    gap__step_rd_certified p pos ct dom litsIn wm tables rows rinv rk | (Just (r, j)) | Nothing = Refl
    gap__step_rd_certified p pos ct dom litsIn wm tables rows rinv rk | (Just (r, j)) | (Just rule)
      with (rarc_5_6_5__nth j (iret_11__table_at r tables)) proof ntok
      gap__step_rd_certified p pos ct dom litsIn wm tables rows rinv rk | (Just (r, j)) | (Just rule) | Nothing = Refl
      gap__step_rd_certified p pos ct dom litsIn wm tables rows rinv rk | (Just (r, j)) | (Just rule) | (Just tok) =
        let (ts ** (t ** (nt, njt, pt))) = ldet_5_1__select_next_pending tables r j sel
        in let njtok : (rarc_5_6_5__nth j ts = Just tok)
               njtok = replace {p = \tbl => rarc_5_6_5__nth j tbl = Just tok} (iret_11__table_at_nth r tables ts nt) ntok
               okTok : Iret_7_4__tok_ok rule dom tok
               okTok = lcyc_1_1__all_lookup (tokOk (runCore rinv) r rule ts nr nt) (lcyc_1_1__nth_elem j ts njtok)
               fm0 : Lcyc_3_1_1__fire_measure p ct dom r wm (idat_6_2_2__mark_fired r j tables) wm (idat_6_2_2__mark_fired r j tables) rows
               fm0 = MkFireMeasure (\j', _ => (Refl, Refl), Right (Refl, Refl))
                       (\row, e, _ => idat_6_2_2__mark_keeps_live r j tables row (fst (iret_12__run_row_live p dom wm tables rows rinv row e)))
                       rk
        in cong Just (gap__actions_rd_certified p pos ct dom litsIn r rule nr tok (fst okTok) (snd okTok) (actions rule)
                        (lcyc_1_1__all_from_elem (actions rule) (\a, e => e))
                        wm (idat_6_2_2__mark_fired r j tables) wm (idat_6_2_2__mark_fired r j tables) rows
                        (iret_11_4__fire_start p pos dom wm tables rows rinv r j rule nr ts nt tok njtok) fm0)

--@gap
||| ON THE ADMITTED FRAGMENT THE TWO ENGINES ARE ONE. From an invariant
||| state of a positive program certified as [LCYC.3.1.1] admits it, the
||| engine with recompute-and-diff after every action takes exactly the
||| refcount engine's steps, however many.
export
gap__step_n_rd_certified : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                           ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) -> (n : Nat) ->
                           (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                           Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                           gap__step_n_rd p n (MkTms (MkState wm tables) rows) = iret_11_4__step_n_tms p n (MkTms (MkState wm tables) rows)
gap__step_n_rd_certified p pos ct dom litsIn Z wm tables rows rinv rk = Refl
gap__step_n_rd_certified p pos ct dom litsIn (S n) wm tables rows rinv rk with (gap__step_rd p (MkTms (MkState wm tables) rows)) proof eR
  gap__step_n_rd_certified p pos ct dom litsIn (S n) wm tables rows rinv rk | Nothing with (iret_11_4__step_tms p (MkTms (MkState wm tables) rows)) proof eT
    gap__step_n_rd_certified p pos ct dom litsIn (S n) wm tables rows rinv rk | Nothing | Nothing = Refl
    gap__step_n_rd_certified p pos ct dom litsIn (S n) wm tables rows rinv rk | Nothing | (Just s) =
      absurd (trans (sym eR) (trans (gap__step_rd_certified p pos ct dom litsIn wm tables rows rinv rk) eT))
  gap__step_n_rd_certified p pos ct dom litsIn (S n) wm tables rows rinv rk | (Just (MkTms (MkState w1 t1) r1)) with (iret_11_4__step_tms p (MkTms (MkState wm tables) rows)) proof eT
    gap__step_n_rd_certified p pos ct dom litsIn (S n) wm tables rows rinv rk | (Just (MkTms (MkState w1 t1) r1)) | Nothing =
      absurd (trans (sym eT) (trans (sym (gap__step_rd_certified p pos ct dom litsIn wm tables rows rinv rk)) eR))
    gap__step_n_rd_certified p pos ct dom litsIn (S n) wm tables rows rinv rk | (Just (MkTms (MkState w1 t1) r1)) | (Just (MkTms (MkState w2 t2) r2)) =
      let same : (MkTms (MkState w1 t1) r1 = MkTms (MkState w2 t2) r2)
          same = iret_11_4__just_inj (trans (sym eR) (trans (gap__step_rd_certified p pos ct dom litsIn wm tables rows rinv rk) eT))
      in let (_, rinv2, rk2) = lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk (MkTms (MkState w2 t2) r2) eT
      in replace {p = \x => gap__step_n_rd p n x = iret_11_4__step_n_tms p n (MkTms (MkState w2 t2) r2)} (sym same)
           (gap__step_n_rd_certified p pos ct dom litsIn n w2 t2 r2 rinv2 rk2)

--@gap
||| AND SO IT TERMINATES there: a positive program certified as
||| [LCYC.3.1.1] admits it reaches an empty agenda from every input with
||| unique ids on the engine with recompute-and-diff after every action --
||| `lcyc_1_1__certified_terminates_tms`, carried across the agreement.
export
gap__rd_certified_terminates : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) ->
                               (wm0 : Rarc_5_6_4__wm) -> Iret_4_4__unique wm0 ->
                               (n : Nat ** gap__step_n_rd p n (rarc_5_6_5__init_tms p wm0) = Nothing)
gap__rd_certified_terminates p pos ct wm0 uniq =
  let (n ** done) = lcyc_1_1__certified_terminates_tms p pos ct wm0 uniq
  in (n ** trans (gap__step_n_rd_certified p pos ct (lcyc_1_1__dom_of (lcyc_3_1_1__tms_to_core p ct) wm0) (\x, e => lcyc_1_1__elem_append_left e) n
                    wm0 (rarc_5_6_5__propagate p wm0 (map (const []) (rules p))) []
                    (rarc_5_6_5__init_tms_inv p (lcyc_1_1__dom_of (lcyc_3_1_1__tms_to_core p ct) wm0) wm0 (lcyc_1_1__init_inv p (lcyc_3_1_1__tms_to_core p ct) wm0) uniq)
                    (\row, e => absurd e))
                 done)

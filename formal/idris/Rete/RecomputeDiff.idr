-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Recompute-and-diff at the pump boundary: a truth-maintenance step for
||| recursive strata --
||| recompute the well-founded set over them after each action and retract
||| the difference -- on Rete/FireLoopTms.idr's engine, stated at the state
||| Rete/PumpBoundary.idr characterises.
|||
||| NO CLAUSE STATES THIS. [IRET.12.2] states the well-founded obligation
||| of [LLOG.2.5] and keeps the justification count as libds's mechanism,
||| correct because [LCYC.3.1.1] makes support acyclic. So the step and what is only about it are `--@gap`; what it
||| proves about [LLOG.2.5] is tied there, and `iret_12_3__certified_ranked`
||| is tied to [IRET.12.2] as well: it is the clause's own sentence, "on
||| every program [LCYC.3.1.1] admits, support is acyclic", on the engine.
|||
||| THE STEP. At a state between actions, take the engine's own table as
||| justifications and the live facts no row targets as base, as
||| Rete/PumpBoundary.idr does; compute the well-founded set over the live
||| facts; retract every live fact outside it, propagate, and let the
||| cascade of [IRET.12.2] drop the rows the retraction ended. A step that
||| finds nothing to retract touches nothing. The recompute is over the
||| table rather than over the rules: at a state between actions every row
||| is a live activation of a current match, so the table holds what a
||| recompute from the surviving inputs would derive among the live facts.
|||
||| WHAT IS PROVED, on a positive program, from a state satisfying the run
||| invariant of Rete/TmsRun.idr:
|||
|||   * the step keeps the run invariant and the target kinds
|||     (`gap__rd_inv`), so it can sit at any boundary of a canonical
|||     replay;
|||   * afterwards the live facts are EXACTLY the well-founded set of the
|||     table over the live facts before (`llog_2_5__rd_exact`): [LLOG.2.5]
|||     holds, with "justification" read as a grounded one;
|||   * the diff is retractions only, and every survivor is the same fact
|||     with the same id (`gap__rd_facts_sub`); an explicit-kind fact is
|||     never retracted (`gap__rd_explicit_kept`);
|||   * what the step retracts is an unfounded set among the live facts
|||     (`llog_2_5__rd_gone_unfounded`) and holds every such set
|||     (`llog_2_5__rd_gone_greatest`): it is the greatest unfounded set,
|||     exactly what the refcount keeps and [LLOG.2.5] does not;
|||   * one step suffices: the state after is a fixpoint of the step
|||     (`gap__rd_idempotent`), since the rows the cascade keeps still ground
|||     every surviving fact;
|||   * on acyclic support it is the identity on the whole state
|||     (`gap__rd_ranked_identity`), and the certificate GIVES
|||     acyclic support: at every state between actions of a run of a
|||     program [LCYC.3.1.1] admits, the table is ranked
|||     (`iret_12_3__certified_ranked`). So the step changes no run of an
|||     admitted program (`gap__rd_certified_identity`,
|||     `gap__rd_canonical_identity`);
|||   * executed on Lcyc/TmsWitnesses.idr's reach run, where the refcount
|||     keeps both Reach facts on each other alone, the step retracts both
|||     (`llog_2_5__rd_reach_engine`).
|||
||| SCOPE. The step runs at a boundary. After an adapter retraction or a
||| TTL sweep that is the moment §5.2 names, since neither is inside a
||| firing; after a rule's `withdraw` the unfounded facts stay visible to
||| the rest of that pump, and the faithful placement -- after every
||| action's cascade -- is Rete/RecomputeFire.idr. Positive programs only,
||| as for the run invariant; stratified negation (§4.2 condition 3) is not
||| modelled.
module Rete.RecomputeDiff

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Rete.PumpBoundary
import Lcyc.Lemmas
import Lcyc.Certificate
import Lcyc.Termination
import Lcyc.TmsTermination
import Lcyc.Witnesses
import Lcyc.TmsWitnesses
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat

%default total

-- ---------------------------------------------------------------------
-- The step
-- ---------------------------------------------------------------------

--@gap
||| The well-founded set of the engine's own table over the live facts,
||| the facts no row targets as base.
public export
gap__rd_wf : Iret_12_4__table -> Rarc_5_6_4__wm -> List Nat
gap__rd_wf rows wm = llog_2_5__well_founded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm)

--@gap
||| What the step retracts: the live ids outside that set.
public export
gap__rd_gone : Iret_12_4__table -> Rarc_5_6_4__wm -> List Nat
gap__rd_gone rows wm = filter (llog_2_5__outside (gap__rd_wf rows wm)) (iret_11_3__fact_ids wm)

--@gap
||| Nothing to retract touches nothing; otherwise retract, propagate, and
||| let the cascade drop the rows the retraction ended.
public export
gap__rd_after : Lcyc_3_2_1__program -> Rarc_5_6_4__wm -> List (List Iret_11__tok) -> Iret_12_4__table -> List Nat -> Iret_12__state
gap__rd_after p wm tables rows [] = MkTms (MkState wm tables) rows
gap__rd_after p wm tables rows (g :: gs) =
  iret_12_2__phase p (MkTms (MkState (iret_12_2__retract_ids (g :: gs) wm) (rarc_5_6_5__propagate p (iret_12_2__retract_ids (g :: gs) wm) tables)) rows)

--@gap
||| THE STEP: recompute the well-founded set from the table and commit the
||| net difference.
public export
gap__recompute_diff : Lcyc_3_2_1__program -> Iret_12__state -> Iret_12__state
gap__recompute_diff p (MkTms (MkState wm tables) rows) = gap__rd_after p wm tables rows (gap__rd_gone rows wm)

-- ---------------------------------------------------------------------
-- Retracting a list of ids
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| The two membership tests on ids agree.
export
iret_12_2__elem_agree : (x : Nat) -> (xs : List Nat) -> rarc_5_6_5__elem x xs = iret_12__elem x xs
iret_12_2__elem_agree x [] = Refl
iret_12_2__elem_agree x (y :: ys) with (y == x)
  iret_12_2__elem_agree x (y :: ys) | True = Refl
  iret_12_2__elem_agree x (y :: ys) | False = iret_12_2__elem_agree x ys

--@derives [IRET.12.2]
||| A fact whose id is not retracted survives the retraction.
export
iret_12_2__retract_keeps : (gone : List Nat) -> (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                           iret_12__elem (fid f) gone = False -> Elem f (iret_12_2__retract_ids gone wm)
iret_12_2__retract_keeps gone wm f ef ng =
  lcyc_1_1__elem_filter_fwd (\g => not (rarc_5_6_5__elem (fid g) gone)) wm ef
    (iret_12__not_false _ (trans (iret_12_2__elem_agree (fid f) gone) ng))

--@derives [IRET.12.2]
||| A survivor of the retraction was live, and its id was not retracted.
export
iret_12_2__retract_inv : (gone : List Nat) -> (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> Elem f (iret_12_2__retract_ids gone wm) ->
                         (Elem f wm, iret_12__elem (fid f) gone = False)
iret_12_2__retract_inv gone wm f e =
  let (ef, nt) = lcyc_1_1__elem_filter_inv (\g => not (rarc_5_6_5__elem (fid g) gone)) wm e
  in (ef, trans (sym (iret_12_2__elem_agree (fid f) gone)) (iret_12__not_true _ nt))

--@derives [IRET.12.2]
||| Retracting ids is an external change in Rete/PumpBoundary.idr's sense,
||| so the cascade after it keeps the run invariant and the target kinds,
||| only removes facts, and keeps explicit-kind facts.
export
iret_12_2__retract_cascade : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                             (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> (gone : List Nat) ->
                             (wmF ** (tablesF ** (rowsF **
                               ( iret_12_2__phase p (MkTms (MkState (iret_12_2__retract_ids gone wm) (rarc_5_6_5__propagate p (iret_12_2__retract_ids gone wm) tables)) rows)
                                   = MkTms (MkState wmF tablesF) rowsF
                               , Iret_12__run_inv p dom wmF tablesF rowsF
                               , Iret_12_4__run_kind p wmF rowsF
                               , (f : Lfac_1_7_1__fact) -> Elem f wmF -> Elem f (iret_12_2__retract_ids gone wm)
                               , (f : Lfac_1_7_1__fact) -> Elem f (iret_12_2__retract_ids gone wm) -> life p (fkind f) = Explicit -> Elem f wmF ))))
iret_12_2__retract_cascade p pos dom wm tables rows rinv rk gone =
  iret_12_2__external_cascade p pos dom wm tables rows rinv rk (iret_12_2__retract_ids gone wm)
    (lcyc_1_1__all_filter (\g => not (rarc_5_6_5__elem (fid g) gone)) wm (wmDom (runCore rinv)))
    (iret_4_4__keeps_filter wm (runUniq rinv) (\g => not (rarc_5_6_5__elem (fid g) gone)))
    (\g, eg => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (rarc_5_6_5__elem (fid h) gone)) wm eg)))
    (iret_4_4__unique_filter wm (runUniq rinv) (\g => not (rarc_5_6_5__elem (fid g) gone)))

--@derives [IRET.12.2]
||| And that cascade ends in the bridge's cascade invariant relative to
||| the rows and the ids that survived the retraction.
export
iret_12_2__retract_final : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                           (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                           Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> (gone : List Nat) ->
                           (wmF ** (tablesF ** (rowsF **
                             ( iret_12_2__phase p (MkTms (MkState (iret_12_2__retract_ids gone wm) (rarc_5_6_5__propagate p (iret_12_2__retract_ids gone wm) tables)) rows)
                                 = MkTms (MkState wmF tablesF) rowsF
                             , Iret_12_2__cascade_inv p dom rows (iret_11_3__fact_ids (iret_12_2__retract_ids gone wm)) wmF tablesF rowsF ))))
iret_12_2__retract_final p pos dom wm tables rows rinv rk gone =
  iret_12_2__external_final p pos dom wm tables rows rinv rk (iret_12_2__retract_ids gone wm)
    (lcyc_1_1__all_filter (\g => not (rarc_5_6_5__elem (fid g) gone)) wm (wmDom (runCore rinv)))
    (iret_4_4__keeps_filter wm (runUniq rinv) (\g => not (rarc_5_6_5__elem (fid g) gone)))
    (\g, eg => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (rarc_5_6_5__elem (fid h) gone)) wm eg)))
    (iret_4_4__unique_filter wm (runUniq rinv) (\g => not (rarc_5_6_5__elem (fid g) gone)))

--@derives [IRET.12.2]
||| And that cascade keeps Rete/Refcount.idr's cascade of the rows over
||| the ids that survived the retraction.
export
iret_12_2__retract_gfp : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                         (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                         Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> (gone : List Nat) ->
                         Iret_12__sub (iret_12_2__cascade (iret_12_2__base rows (iret_11_3__fact_ids (iret_12_2__retract_ids gone wm))) (iret_12_4__justifs rows)
                                                          (iret_11_3__fact_ids (iret_12_2__retract_ids gone wm)))
                                      (iret_11_3__fact_ids (core (iret_12_2__phase p (MkTms (MkState (iret_12_2__retract_ids gone wm)
                                                                   (rarc_5_6_5__propagate p (iret_12_2__retract_ids gone wm) tables)) rows))).wm)
iret_12_2__retract_gfp p pos dom wm tables rows rinv rk gone =
  iret_12_2__external_gfp p pos dom wm tables rows rinv rk (iret_12_2__retract_ids gone wm)
    (lcyc_1_1__all_filter (\g => not (rarc_5_6_5__elem (fid g) gone)) wm (wmDom (runCore rinv)))
    (iret_4_4__keeps_filter wm (runUniq rinv) (\g => not (rarc_5_6_5__elem (fid g) gone)))
    (\g, eg => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (rarc_5_6_5__elem (fid h) gone)) wm eg)))
    (iret_4_4__unique_filter wm (runUniq rinv) (\g => not (rarc_5_6_5__elem (fid g) gone)))

-- ---------------------------------------------------------------------
-- The fixpoint lemmas the step needs
-- ---------------------------------------------------------------------

--@derives [LLOG.2.5]
--@derives [IRET.12.2]
||| The cascade keeps every well-founded fact even over a smaller live set
||| and a different base, provided the well-founded facts are all live
||| there and a base fact that is still live is still base. Generalises
||| `llog_2_5__wf_in_cascade`, where the two bases coincide.
export
llog_2_5__wf_in_cascade_of : (base0, base1 : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, live : List Iret_12__fact) ->
                             Iret_12__sub (llog_2_5__well_founded base0 js univ) live ->
                             ((u : Iret_12__fact) -> iret_12__elem u base0 = True -> iret_12__elem u live = True -> iret_12__elem u base1 = True) ->
                             Iret_12__sub (llog_2_5__well_founded base0 js univ) (iret_12_2__cascade base1 js live)
llog_2_5__wf_in_cascade_of base0 base1 js univ live sub hb =
  iret_12_2__cascade_greatest base1 js live (llog_2_5__well_founded base0 js univ) sub post
  where
    post : Iret_12__sub (llog_2_5__well_founded base0 js univ) (iret_12_2__cascade_step base1 js (llog_2_5__well_founded base0 js univ))
    post u uw =
      let (uIn, pu) = iret_12__elem_filter_inv (\v => iret_12__elem v base0 || iret_12__supported js (llog_2_5__well_founded base0 js univ) v) univ u
                        (replace {p = \k => iret_12__elem u k = True} (sym (llog_2_5__wf_fixed base0 js univ)) uw)
      in iret_12__elem_filter (\v => iret_12__elem v base1 || iret_12__supported js (llog_2_5__well_founded base0 js univ) v)
                              (llog_2_5__well_founded base0 js univ) u uw
           (case iret_12__or_inv _ _ pu of
              Left b0 => iret_12__or_true_l _ _ (hb u b0 (sub u uw))
              Right s => iret_12__or_true_r _ _ s)

--@derives [IRET.12.2]
||| A base fact still live after a retraction is still base: the rows are
||| the same, so nothing new targets it.
export
iret_12_2__base_shrink : (rows : Iret_12_4__table) -> (ids0, ids1 : List Nat) -> (u : Nat) ->
                         iret_12__elem u (iret_12_2__base rows ids0) = True -> iret_12__elem u ids1 = True ->
                         iret_12__elem u (iret_12_2__base rows ids1) = True
iret_12_2__base_shrink rows ids0 ids1 u b0 u1 =
  let (_, nt) = iret_12__elem_filter_inv (\i => not (iret_12__elem i (iret_12_4__targets rows))) ids0 u b0
  in iret_12__elem_filter (\i => not (iret_12__elem i (iret_12_4__targets rows))) ids1 u u1 nt

--@gap
||| A live id outside the well-founded set is retracted.
export
gap__rd_gone_of : (rows : Iret_12_4__table) -> (wm : Rarc_5_6_4__wm) -> (t : Nat) ->
                  iret_12__elem t (iret_11_3__fact_ids wm) = True -> iret_12__elem t (gap__rd_wf rows wm) = False ->
                  iret_12__elem t (gap__rd_gone rows wm) = True
gap__rd_gone_of rows wm t tl tw = iret_12__elem_filter (llog_2_5__outside (gap__rd_wf rows wm)) (iret_11_3__fact_ids wm) t tl (iret_12__not_false _ tw)

--@gap
||| A retracted id was live and outside the well-founded set.
export
gap__rd_gone_inv : (rows : Iret_12_4__table) -> (wm : Rarc_5_6_4__wm) -> (t : Nat) -> iret_12__elem t (gap__rd_gone rows wm) = True ->
                   (iret_12__elem t (iret_11_3__fact_ids wm) = True, iret_12__elem t (gap__rd_wf rows wm) = False)
gap__rd_gone_inv rows wm t e =
  let (tl, o) = iret_12__elem_filter_inv (llog_2_5__outside (gap__rd_wf rows wm)) (iret_11_3__fact_ids wm) t e
  in (tl, iret_12__not_true _ o)

-- ---------------------------------------------------------------------
-- The invariant
-- ---------------------------------------------------------------------

--@gap
||| Whatever list is retracted, the end of the step keeps the run invariant
||| and the target kinds.
export
gap__rd_after_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                    (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                    Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> (gone : List Nat) ->
                    (Iret_12__run_inv_s p dom (gap__rd_after p wm tables rows gone), Iret_12_4__run_kind_s p (gap__rd_after p wm tables rows gone))
gap__rd_after_inv p pos dom wm tables rows rinv rk [] = (rinv, rk)
gap__rd_after_inv p pos dom wm tables rows rinv rk (g :: gs) =
  case iret_12_2__retract_cascade p pos dom wm tables rows rinv rk (g :: gs) of
    (wmF ** (tablesF ** (rowsF ** (eq, rinvF, rkF, _, _)))) =>
      replace {p = \x => (Iret_12__run_inv_s p dom x, Iret_12_4__run_kind_s p x)} (sym eq) (rinvF, rkF)

--@gap
||| THE STEP KEEPS THE RUN INVARIANT and the target kinds, so it can sit
||| at any boundary of a canonical replay.
export
gap__rd_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
              (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
              Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
              ( Iret_12__run_inv_s p dom (gap__recompute_diff p (MkTms (MkState wm tables) rows))
              , Iret_12_4__run_kind_s p (gap__recompute_diff p (MkTms (MkState wm tables) rows)) )
gap__rd_inv p pos dom wm tables rows rinv rk = gap__rd_after_inv p pos dom wm tables rows rinv rk (gap__rd_gone rows wm)

-- ---------------------------------------------------------------------
-- Exactness: the live facts after are the well-founded set
-- ---------------------------------------------------------------------

--@derives [LLOG.2.5]
||| For any list retracted that holds no well-founded id and every live id
||| outside the well-founded set, the live ids after are exactly the
||| well-founded set: nothing it holds is retracted by the cascade that
||| follows, since it is self-supported among the survivors and its base
||| facts stay base.
export
llog_2_5__rd_after_exact : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                           (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                           Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> (gone : List Nat) ->
                           ((t : Nat) -> iret_12__elem t gone = True -> iret_12__elem t (gap__rd_wf rows wm) = False) ->
                           ((t : Nat) -> iret_12__elem t (iret_11_3__fact_ids wm) = True -> iret_12__elem t (gap__rd_wf rows wm) = False -> iret_12__elem t gone = True) ->
                           ( Iret_12__sub (iret_11_3__fact_ids (core (gap__rd_after p wm tables rows gone)).wm) (gap__rd_wf rows wm)
                           , Iret_12__sub (gap__rd_wf rows wm) (iret_11_3__fact_ids (core (gap__rd_after p wm tables rows gone)).wm) )
llog_2_5__rd_after_exact p pos dom wm tables rows rinv rk [] hG1 hG2 =
  ( \t, tl => case iret_12__bool_split (iret_12__elem t (gap__rd_wf rows wm)) of
                Left y => y
                Right n => absurd (hG2 t tl n)
  , llog_2_5__wf_sub_all (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) )
llog_2_5__rd_after_exact p pos dom wm tables rows rinv rk (g :: gs) hG1 hG2 =
  case iret_12_2__retract_cascade p pos dom wm tables rows rinv rk (g :: gs) of
    (wmF ** (tablesF ** (rowsF ** (eq, _, _, subF, _)))) =>
      let -- every well-founded id survives the retraction
          sub01 : Iret_12__sub (gap__rd_wf rows wm) (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm))
          sub01 t tw =
            let tl = llog_2_5__wf_sub_all (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) t tw
            in let (f ** (ef, ft)) = iret_12_4__live_id t wm tl
            in let twf : (iret_12__elem (fid f) (gap__rd_wf rows wm) = True)
                   twf = replace {p = \i => iret_12__elem i (gap__rd_wf rows wm) = True} (sym ft) tw
            in let ng : (iret_12__elem (fid f) (g :: gs) = False)
                   ng = iret_12__bool_false_of _ (\ig => lcyc_1_1__bool_not_both _ twf (hG1 (fid f) ig))
            in replace {p = \i => iret_12__elem i (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm)) = True} ft
                 (iret_12_4__id_live f (iret_12_2__retract_ids (g :: gs) wm) (iret_12_2__retract_keeps (g :: gs) wm f ef ng))
          -- every id live after is well-founded
          subWmF : Iret_12__sub (iret_11_3__fact_ids wmF) (gap__rd_wf rows wm)
          subWmF t tl =
            let (f ** (ef, ft)) = iret_12_4__live_id t wmF tl
            in let (efw, ng) = iret_12_2__retract_inv (g :: gs) wm f (subF f ef)
            in case iret_12__bool_split (iret_12__elem (fid f) (gap__rd_wf rows wm)) of
                 Left y => replace {p = \i => iret_12__elem i (gap__rd_wf rows wm) = True} ft y
                 Right n => void (lcyc_1_1__bool_not_both _ (hG2 (fid f) (iret_12_4__id_live f wm efw) n) ng)
      in ( replace {p = \x => Iret_12__sub (iret_11_3__fact_ids (core x).wm) (gap__rd_wf rows wm)} (sym eq) subWmF
         , \t, tw => iret_12_2__retract_gfp p pos dom wm tables rows rinv rk (g :: gs) t
                       (llog_2_5__wf_in_cascade_of (iret_12_2__base rows (iret_11_3__fact_ids wm))
                          (iret_12_2__base rows (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm)))
                          (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm))
                          sub01
                          (iret_12_2__base_shrink rows (iret_11_3__fact_ids wm) (iret_11_3__fact_ids (iret_12_2__retract_ids (g :: gs) wm)))
                          t tw) )

--@derives [LLOG.2.5]
||| THE STEP IS EXACT. After recompute-and-diff the live facts are exactly
||| the well-founded set of the table over the live facts before: every
||| live fact has a justification grounded in the facts nothing justifies,
||| and every fact so grounded is live. [LLOG.2.5] with "the last
||| justification" read as the last grounded one, the reading that is the
||| contract.
export
llog_2_5__rd_exact : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                     (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                     Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                     ( Iret_12__sub (iret_11_3__fact_ids (core (gap__recompute_diff p (MkTms (MkState wm tables) rows))).wm) (gap__rd_wf rows wm)
                     , Iret_12__sub (gap__rd_wf rows wm) (iret_11_3__fact_ids (core (gap__recompute_diff p (MkTms (MkState wm tables) rows))).wm) )
llog_2_5__rd_exact p pos dom wm tables rows rinv rk =
  llog_2_5__rd_after_exact p pos dom wm tables rows rinv rk (gap__rd_gone rows wm)
    (\t, e => snd (gap__rd_gone_inv rows wm t e))
    (gap__rd_gone_of rows wm)

-- ---------------------------------------------------------------------
-- The diff: retractions only, explicit facts untouched
-- ---------------------------------------------------------------------

--@gap
||| The end of the step only removes facts, whatever list is retracted.
export
gap__rd_after_sub : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                    (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                    Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> (gone : List Nat) ->
                    (f : Lfac_1_7_1__fact) -> Elem f (core (gap__rd_after p wm tables rows gone)).wm -> Elem f wm
gap__rd_after_sub p pos dom wm tables rows rinv rk [] f e = e
gap__rd_after_sub p pos dom wm tables rows rinv rk (g :: gs) f e =
  case iret_12_2__retract_cascade p pos dom wm tables rows rinv rk (g :: gs) of
    (wmF ** (tablesF ** (rowsF ** (eq, _, _, subF, _)))) =>
      fst (iret_12_2__retract_inv (g :: gs) wm f (subF f (replace {p = \x => Elem f (core x).wm} eq e)))

--@gap
||| THE DIFF IS RETRACTIONS ONLY. Every fact live after the step was live
||| before, as the same fact with the same id: survivors keep their ids,
||| so downstream tokens neither die nor re-create (the recommendation's
||| containment property).
||| `llog_2_5__wf_mono_base` said this of the abstract recompute; this is
||| the engine's step.
export
gap__rd_facts_sub : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                    (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                    Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                    (f : Lfac_1_7_1__fact) -> Elem f (core (gap__recompute_diff p (MkTms (MkState wm tables) rows))).wm -> Elem f wm
gap__rd_facts_sub p pos dom wm tables rows rinv rk = gap__rd_after_sub p pos dom wm tables rows rinv rk (gap__rd_gone rows wm)

--@gap
||| A live explicit-kind fact is base: no row targets it, since a row's
||| target is `logical`.
export
gap__rd_explicit_base : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) ->
                        (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                        Iret_12_4__run_kind p wm rows ->
                        (f : Lfac_1_7_1__fact) -> Elem f wm -> life p (fkind f) = Explicit ->
                        iret_12__elem (fid f) (iret_12_2__base rows (iret_11_3__fact_ids wm)) = True
gap__rd_explicit_base p dom wm tables rows rk f ef ex =
  case iret_12__bool_split (iret_12__elem (fid f) (iret_12_2__base rows (iret_11_3__fact_ids wm))) of
    Left b => b
    Right nb => case iret_12_2__base_row rows (iret_11_3__fact_ids wm) (fid f) (iret_12_4__id_live f wm ef) nb of
      (row ** (er, ti)) => let (rule ** (_, kf)) = rk row er
                           in void (snd (kf f ef (sym ti)) ex)

--@gap
||| An explicit-kind fact whose id is not retracted is live at the end of
||| the step, whatever list is retracted.
export
gap__rd_after_explicit : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                         (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                         Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> (gone : List Nat) ->
                         (f : Lfac_1_7_1__fact) -> Elem f wm -> life p (fkind f) = Explicit -> iret_12__elem (fid f) gone = False ->
                         Elem f (core (gap__rd_after p wm tables rows gone)).wm
gap__rd_after_explicit p pos dom wm tables rows rinv rk [] f ef ex ng = ef
gap__rd_after_explicit p pos dom wm tables rows rinv rk (g :: gs) f ef ex ng =
  case iret_12_2__retract_cascade p pos dom wm tables rows rinv rk (g :: gs) of
    (wmF ** (tablesF ** (rowsF ** (eq, _, _, _, keptF)))) =>
      replace {p = \x => Elem f (core x).wm} (sym eq) (keptF f (iret_12_2__retract_keeps (g :: gs) wm f ef ng) ex)

--@gap
||| AN EXPLICIT FACT IS NEVER RETRACTED by the step: it is base, hence
||| well-founded, hence not in the diff, and the cascade after keeps
||| explicit facts. A TTL fact, an adapter's explicit input: the step
||| reaches only `logical` facts, as [LLOG.15.2] requires of truth
||| maintenance.
export
gap__rd_explicit_kept : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                        (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                        Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                        (f : Lfac_1_7_1__fact) -> Elem f wm -> life p (fkind f) = Explicit ->
                        Elem f (core (gap__recompute_diff p (MkTms (MkState wm tables) rows))).wm
gap__rd_explicit_kept p pos dom wm tables rows rinv rk f ef ex =
  let fw : (iret_12__elem (fid f) (gap__rd_wf rows wm) = True)
      fw = llog_2_5__base_in_wf (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) (fid f)
             (iret_12_4__id_live f wm ef) (gap__rd_explicit_base p dom wm tables rows rk f ef ex)
  in gap__rd_after_explicit p pos dom wm tables rows rinv rk (gap__rd_gone rows wm) f ef ex
       (iret_12__bool_false_of _ (\ig => lcyc_1_1__bool_not_both _ fw (snd (gap__rd_gone_inv rows wm (fid f) ig))))

-- ---------------------------------------------------------------------
-- What the diff is: the greatest unfounded set among the live facts
-- ---------------------------------------------------------------------

--@derives [LLOG.2.5]
||| WHAT THE STEP RETRACTS IS AN UNFOUNDED SET among the live facts,
||| whenever it retracts anything: no base fact is in it, and every
||| justification of one of its members whose antecedents are live uses
||| another member. Mutual support with nothing under it -- the facts the
||| refcount keeps (`llog_2_5__boundary_unfounded`) and [LLOG.2.5] does not.
export
llog_2_5__rd_gone_unfounded : (rows : Iret_12_4__table) -> (wm : Rarc_5_6_4__wm) -> (t0 : Nat) -> iret_12__elem t0 (gap__rd_gone rows wm) = True ->
                              Llog_2_5__unfounded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) (gap__rd_gone rows wm)
llog_2_5__rd_gone_unfounded rows wm t0 t0g =
  ( iret_12__nonempty t0 (gap__rd_gone rows wm) t0g
  , \t, tg => let (tl, tnw) = gap__rd_gone_inv rows wm t tg
              in iret_12__bool_false_of _ (\tb => lcyc_1_1__bool_not_both _
                   (llog_2_5__base_in_wf (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) t tl tb) tnw)
  , \t, tg, j, ej, tj, aj =>
      let (tl, tnw) = gap__rd_gone_inv rows wm t tg
      in let notAll : (iret_12__all_in (ante j) (gap__rd_wf rows wm) = False)
             notAll = iret_12__bool_false_of _ (\aw => lcyc_1_1__bool_not_both _
                        (llog_2_5__wf_closed (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) t tl
                           (replace {p = \v => iret_12__supported (iret_12_4__justifs rows) (gap__rd_wf rows wm) v = True} tj
                              (iret_12_1__supported_of (iret_12_4__justifs rows) (gap__rd_wf rows wm) j ej aw)))
                        tnw)
      in let (a ** (ea, anw)) = iret_12__all_in_false (ante j) (gap__rd_wf rows wm) notAll
      in (a ** (ea, gap__rd_gone_of rows wm a (iret_12__all_in_elem (ante j) (iret_11_3__fact_ids wm) aj a ea) anw)) )

--@derives [LLOG.2.5]
||| AND IT HOLDS EVERY UNFOUNDED SET among the live facts: a live fact in
||| any unfounded set is not well-founded (`llog_2_5__unfounded_disagrees`),
||| so the step retracts it. The diff is the greatest unfounded set -- no
||| more is retracted than must be, and no unfounded support survives.
export
llog_2_5__rd_gone_greatest : (rows : Iret_12_4__table) -> (wm : Rarc_5_6_4__wm) -> (u : List Nat) ->
                             Llog_2_5__unfounded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) u ->
                             Iret_12__sub u (iret_11_3__fact_ids wm) -> Iret_12__sub u (gap__rd_gone rows wm)
llog_2_5__rd_gone_greatest rows wm u (ne, ufree, uheld) uLive t tu =
  gap__rd_gone_of rows wm t (uLive t tu)
    (llog_2_5__unfounded_disagrees (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) (iret_11_3__fact_ids wm) u
       (llog_2_5__wf_sub_all (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
       ( ne, ufree
       , \x, xu, j, ej, tj, ac => uheld x xu j ej tj
           (iret_12__all_in_sub (ante j)
              (iret_12_2__cascade (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
              (iret_11_3__fact_ids wm)
              (iret_12_2__cascade_sub (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
              ac) )
       t tu)

-- ---------------------------------------------------------------------
-- One step suffices: the state after is a fixpoint of the step
-- ---------------------------------------------------------------------

--@gap
||| A filter no member passes is empty.
export
gap__rd_filter_none : (q : Nat -> Bool) -> (xs : List Nat) -> ((x : Nat) -> iret_12__elem x xs = True -> q x = False) -> filter q xs = []
gap__rd_filter_none q [] h = Refl
gap__rd_filter_none q (x :: xs) h with (q x) proof qx
  gap__rd_filter_none q (x :: xs) h | True = absurd (trans (sym qx) (h x (iret_12__elem_head x xs)))
  gap__rd_filter_none q (x :: xs) h | False = gap__rd_filter_none q xs (\y, ey => h y (iret_12__elem_tail x y xs ey))

--@gap
||| Nothing to retract, nothing touched.
export
gap__rd_after_nil : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                    (gone : List Nat) -> gone = [] -> gap__rd_after p wm tables rows gone = MkTms (MkState wm tables) rows
gap__rd_after_nil p wm tables rows gone prf = rewrite prf in Refl

--@derives [IRET.12.4]
||| A justification read off the table is a row's.
export
iret_12_4__row_justif : (rows : Iret_12_4__table) -> (j : Iret_12_1__justif) -> Elem j (iret_12_4__justifs rows) ->
                        (row ** (Elem row rows, ante j = rids row, target j = rtarget row))
iret_12_4__row_justif rows j e =
  case lcyc_1_1__elem_map_inv (\row => MkJustif (rids row) (rtarget row)) rows e of
    (row ** (er, eq)) => (row ** (er, rewrite sym eq in Refl, rewrite sym eq in Refl))

--@derives [IRET.12.4]
||| A row of the table is a justification.
export
iret_12_4__justif_of_row : (rows : Iret_12_4__table) -> (row : Iret_12_4__row) -> Elem row rows ->
                           Elem (MkJustif (rids row) (rtarget row)) (iret_12_4__justifs rows)
iret_12_4__justif_of_row rows row e = lcyc_1_1__elem_map_fwd (\r => MkJustif (rids r) (rtarget r)) e

--@derives [IRET.12.4]
||| A row's target is among the table's targets.
export
iret_12_4__target_of : (rows : Iret_12_4__table) -> (row : Iret_12_4__row) -> Elem row rows ->
                       iret_12__elem (rtarget row) (iret_12_4__targets rows) = True
iret_12_4__target_of rows row e = iret_12__elem_true (rtarget row) (iret_12_4__targets rows) (lcyc_1_1__elem_map_fwd rtarget e)

--@derives [IRET.12.2]
||| A base fact stays base when rows are dropped and it is still live.
export
iret_12_2__base_sub_rows : (rows, rowsF : Iret_12_4__table) -> ((row : Iret_12_4__row) -> Elem row rowsF -> Elem row rows) ->
                           (ids0, ids1 : List Nat) -> (t : Nat) ->
                           iret_12__elem t (iret_12_2__base rows ids0) = True -> iret_12__elem t ids1 = True ->
                           iret_12__elem t (iret_12_2__base rowsF ids1) = True
iret_12_2__base_sub_rows rows rowsF rsub ids0 ids1 t b0 t1 =
  case iret_12__bool_split (iret_12__elem t (iret_12_2__base rowsF ids1)) of
    Left b => b
    Right nb =>
      let (row ** (er, rt)) = iret_12_2__base_row rowsF ids1 t t1 nb
      in let inT = replace {p = \i => iret_12__elem i (iret_12_4__targets rows) = True} rt (iret_12_4__target_of rows row (rsub row er))
      in let (_, nt) = iret_12__elem_filter_inv (\i => not (iret_12__elem i (iret_12_4__targets rows))) ids0 t b0
      in void (lcyc_1_1__bool_not_both _ inT (iret_12__not_true _ nt))

--@derives [LLOG.2.5]
||| The well-founded set survives the step's own bookkeeping: if the live
||| ids after are exactly the old well-founded set, and the rows kept are
||| drawn from the old ones and include every old row whose antecedents
||| and target are live, then the old well-founded set is within the new
||| one -- the rows that grounded it are still there.
export
llog_2_5__wf_grow : (rows, rowsF : Iret_12_4__table) -> (w0, w1 : Rarc_5_6_4__wm) ->
                    ((row : Iret_12_4__row) -> Elem row rowsF -> Elem row rows) ->
                    ((row : Iret_12_4__row) -> Elem row rows -> iret_12__all_in (rids row) (iret_11_3__fact_ids w1) = True ->
                       rarc_5_6_4__is_live (rtarget row) w1 = True -> Elem row rowsF) ->
                    Iret_12__sub (iret_11_3__fact_ids w1) (gap__rd_wf rows w0) ->
                    Iret_12__sub (gap__rd_wf rows w0) (iret_11_3__fact_ids w1) ->
                    Iret_12__sub (gap__rd_wf rows w0) (gap__rd_wf rowsF w1)
llog_2_5__wf_grow rows rowsF w0 w1 rsub rkeep fwd bwd =
  llog_2_5__wf_least (iret_12_2__base rows (iret_11_3__fact_ids w0)) (iret_12_4__justifs rows) (iret_11_3__fact_ids w0) (gap__rd_wf rowsF w1)
    (\t, tIn, tb =>
       let t1 = bwd t (llog_2_5__base_in_wf (iret_12_2__base rows (iret_11_3__fact_ids w0)) (iret_12_4__justifs rows) (iret_11_3__fact_ids w0) t tIn tb)
       in llog_2_5__base_in_wf (iret_12_2__base rowsF (iret_11_3__fact_ids w1)) (iret_12_4__justifs rowsF) (iret_11_3__fact_ids w1) t t1
            (iret_12_2__base_sub_rows rows rowsF rsub (iret_11_3__fact_ids w0) (iret_11_3__fact_ids w1) t tb t1))
    (\t, tIn, ts =>
       let (j ** (ej, tj, aj)) = iret_12_1__supported_inv (iret_12_4__justifs rows) (gap__rd_wf rowsF w1) t ts
       in let (row ** (er, aeq, teq)) = iret_12_4__row_justif rows j ej
       in let newSub : Iret_12__sub (gap__rd_wf rowsF w1) (iret_11_3__fact_ids w1)
              newSub = llog_2_5__wf_sub_all (iret_12_2__base rowsF (iret_11_3__fact_ids w1)) (iret_12_4__justifs rowsF) (iret_11_3__fact_ids w1)
       in let ajNew : (iret_12__all_in (rids row) (gap__rd_wf rowsF w1) = True)
              ajNew = replace {p = \as => iret_12__all_in as (gap__rd_wf rowsF w1) = True} aeq aj
       in let aj1 = iret_12__all_in_sub (rids row) (gap__rd_wf rowsF w1) (iret_11_3__fact_ids w1) newSub ajNew
       in let ajOld = iret_12__all_in_sub (ante j) (gap__rd_wf rowsF w1) (gap__rd_wf rows w0) (\x, e => fwd x (newSub x e)) aj
       in let tOld : (iret_12__elem t (gap__rd_wf rows w0) = True)
              tOld = llog_2_5__wf_closed (iret_12_2__base rows (iret_11_3__fact_ids w0)) (iret_12_4__justifs rows) (iret_11_3__fact_ids w0) t tIn
                       (replace {p = \v => iret_12__supported (iret_12_4__justifs rows) (gap__rd_wf rows w0) v = True} tj
                          (iret_12_1__supported_of (iret_12_4__justifs rows) (gap__rd_wf rows w0) j ej ajOld))
       in let t1 = bwd t tOld
       in let tr : (rtarget row = t)
              tr = trans (sym teq) tj
       in let (g ** (eg, gid)) = iret_12_4__live_id t w1 t1
       in let liveT = replace {p = \i => rarc_5_6_4__is_live i w1 = True} (trans gid (sym tr)) (rarc_5_6_4__is_live_of g w1 eg)
       in let erF = rkeep row er aj1 liveT
       in let sNew = iret_12_1__supported_of (iret_12_4__justifs rowsF) (gap__rd_wf rowsF w1) (MkJustif (rids row) (rtarget row))
                       (iret_12_4__justif_of_row rowsF row erF) ajNew
       in llog_2_5__wf_closed (iret_12_2__base rowsF (iret_11_3__fact_ids w1)) (iret_12_4__justifs rowsF) (iret_11_3__fact_ids w1) t t1
            (replace {p = \v => iret_12__supported (iret_12_4__justifs rowsF) (gap__rd_wf rowsF w1) v = True} tr sNew))

--@gap
||| Whatever list satisfying the exactness premises is retracted, the step
||| after it changes nothing.
export
gap__rd_after_idem : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                     (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                     Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> (gone : List Nat) ->
                     ((t : Nat) -> iret_12__elem t gone = True -> iret_12__elem t (gap__rd_wf rows wm) = False) ->
                     ((t : Nat) -> iret_12__elem t (iret_11_3__fact_ids wm) = True -> iret_12__elem t (gap__rd_wf rows wm) = False -> iret_12__elem t gone = True) ->
                     gap__recompute_diff p (gap__rd_after p wm tables rows gone) = gap__rd_after p wm tables rows gone
gap__rd_after_idem p pos dom wm tables rows rinv rk [] hG1 hG2 =
  gap__rd_after_nil p wm tables rows (gap__rd_gone rows wm)
    (gap__rd_filter_none (llog_2_5__outside (gap__rd_wf rows wm)) (iret_11_3__fact_ids wm)
       (\x, ex => cong not (fst (llog_2_5__rd_after_exact p pos dom wm tables rows rinv rk [] hG1 hG2) x ex)))
gap__rd_after_idem p pos dom wm tables rows rinv rk (g :: gs) hG1 hG2 =
  case iret_12_2__retract_final p pos dom wm tables rows rinv rk (g :: gs) of
    (wmF ** (tablesF ** (rowsF ** (eq, invF)))) =>
      let exact = llog_2_5__rd_after_exact p pos dom wm tables rows rinv rk (g :: gs) hG1 hG2
      in let fwdF : Iret_12__sub (iret_11_3__fact_ids wmF) (gap__rd_wf rows wm)
             fwdF = replace {p = \x => Iret_12__sub (iret_11_3__fact_ids (core x).wm) (gap__rd_wf rows wm)} eq (fst exact)
      in let bwdF : Iret_12__sub (gap__rd_wf rows wm) (iret_11_3__fact_ids wmF)
             bwdF = replace {p = \x => Iret_12__sub (gap__rd_wf rows wm) (iret_11_3__fact_ids (core x).wm)} eq (snd exact)
      in let grow = llog_2_5__wf_grow rows rowsF wm wmF (rowsSub invF) (\row, e, a, l => fst (rowLive invF row e a l)) fwdF bwdF
      in replace {p = \x => gap__recompute_diff p x = x} (sym eq)
           (gap__rd_after_nil p wmF tablesF rowsF (gap__rd_gone rowsF wmF)
              (gap__rd_filter_none (llog_2_5__outside (gap__rd_wf rowsF wmF)) (iret_11_3__fact_ids wmF)
                 (\x, ex => cong not (grow x (fwdF x ex)))))

--@gap
||| ONE STEP SUFFICES. The state after recompute-and-diff is a fixpoint of
||| it: the rows the cascade kept still ground every surviving fact, so
||| nothing unfounded remains to retract and the step is never iterated.
export
gap__rd_idempotent : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                     (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                     Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                     gap__recompute_diff p (gap__recompute_diff p (MkTms (MkState wm tables) rows)) = gap__recompute_diff p (MkTms (MkState wm tables) rows)
gap__rd_idempotent p pos dom wm tables rows rinv rk =
  gap__rd_after_idem p pos dom wm tables rows rinv rk (gap__rd_gone rows wm)
    (\t, e => snd (gap__rd_gone_inv rows wm t e))
    (gap__rd_gone_of rows wm)

-- ---------------------------------------------------------------------
-- On acyclic support the step is invisible
-- ---------------------------------------------------------------------

--@gap
||| ON ACYCLIC SUPPORT THE STEP IS THE IDENTITY, on the whole state: the
||| live set is already the well-founded set (`iret_12_3__boundary_ranked`),
||| so there is nothing to retract and no event, token or row moves.
||| Every program [LCYC.3.1.1] admits today has acyclic support, so adding
||| the step to the engine changes none of their runs -- the recommendation's
||| containment property, as a theorem.
export
gap__rd_ranked_identity : (rank : Nat -> Nat) -> (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) ->
                          (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                          Iret_12__run_inv p dom wm tables rows -> Iret_12_3__ranked rank (iret_12_4__justifs rows) ->
                          gap__recompute_diff p (MkTms (MkState wm tables) rows) = MkTms (MkState wm tables) rows
gap__rd_ranked_identity rank p dom wm tables rows rinv rk =
  gap__rd_after_nil p wm tables rows (gap__rd_gone rows wm)
    (gap__rd_filter_none (llog_2_5__outside (gap__rd_wf rows wm)) (iret_11_3__fact_ids wm)
       (\x, ex => cong not (fst (iret_12_3__boundary_ranked rank p dom wm tables rows rinv rk) x ex)))

-- ---------------------------------------------------------------------
-- The certificate gives acyclic support, so the step is
-- invisible on every run it admits
-- ---------------------------------------------------------------------

--@derives [IRET.12.3]
||| The larger of two naturals, by structure, so its lemmas are inductions.
public export
iret_12_3__max : Nat -> Nat -> Nat
iret_12_3__max Z b = b
iret_12_3__max (S a) Z = S a
iret_12_3__max (S a) (S b) = S (iret_12_3__max a b)

--@derives [IRET.12.3]
export
iret_12_3__max_left : (a, b : Nat) -> LTE a (iret_12_3__max a b)
iret_12_3__max_left Z b = LTEZero
iret_12_3__max_left (S a) Z = reflexive
iret_12_3__max_left (S a) (S b) = LTESucc (iret_12_3__max_left a b)

--@derives [IRET.12.3]
export
iret_12_3__max_right : (a, b : Nat) -> LTE b (iret_12_3__max a b)
iret_12_3__max_right Z b = reflexive
iret_12_3__max_right (S a) Z = LTEZero
iret_12_3__max_right (S a) (S b) = LTESucc (iret_12_3__max_right a b)

--@derives [IRET.12.3]
export
iret_12_3__max_lub : (a, b, c : Nat) -> LTE a c -> LTE b c -> LTE (iret_12_3__max a b) c
iret_12_3__max_lub Z b c _ hb = hb
iret_12_3__max_lub (S a) Z c ha _ = ha
iret_12_3__max_lub (S a) (S b) Z ha _ = absurd ha
iret_12_3__max_lub (S a) (S b) (S c) (LTESucc ha) (LTESucc hb) = LTESucc (iret_12_3__max_lub a b c ha hb)

--@derives [IRET.12.3]
||| What one rule contributes to a kind's level: one more than its stratum
||| if it emits the kind, nothing otherwise.
public export
iret_12_3__level_of : Lcyc_3_1__strata -> Nat -> Lgra_6_1__rule -> Nat -> Nat
iret_12_3__level_of s idx r k = if rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r) then S (strat s idx) else 0

--@derives [IRET.12.3]
||| A kind's level: one more than the highest stratum of a rule emitting
||| it, zero for a kind no rule emits. Rules indexed from `idx`.
public export
iret_12_3__level_from : Lcyc_3_1__strata -> Nat -> List Lgra_6_1__rule -> Nat -> Nat
iret_12_3__level_from s idx [] k = 0
iret_12_3__level_from s idx (r :: rs) k = iret_12_3__max (iret_12_3__level_of s idx r k) (iret_12_3__level_from s (S idx) rs k)

--@derives [IRET.12.3]
export
iret_12_3__level_of_emit : (s : Lcyc_3_1__strata) -> (idx : Nat) -> (r : Lgra_6_1__rule) -> (k : Nat) ->
                           rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r) = True -> iret_12_3__level_of s idx r k = S (strat s idx)
iret_12_3__level_of_emit s idx r k e with (rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r)) proof q
  iret_12_3__level_of_emit s idx r k e | True = Refl
  iret_12_3__level_of_emit s idx r k e | False = absurd e

--@derives [IRET.12.3]
export
iret_12_3__level_of_bound : (s : Lcyc_3_1__strata) -> (idx : Nat) -> (r : Lgra_6_1__rule) -> (k, b : Nat) ->
                            (rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r) = True -> LTE (S (strat s idx)) b) ->
                            LTE (iret_12_3__level_of s idx r k) b
iret_12_3__level_of_bound s idx r k b h with (rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r)) proof q
  iret_12_3__level_of_bound s idx r k b h | True = h Refl
  iret_12_3__level_of_bound s idx r k b h | False = LTEZero

--@derives [IRET.12.3]
||| An emitter's stratum is below the kind's level.
export
iret_12_3__level_up : (s : Lcyc_3_1__strata) -> (idx : Nat) -> (rs : List Lgra_6_1__rule) -> (j : Nat) -> (r : Lgra_6_1__rule) ->
                      rarc_5_6_5__nth j rs = Just r -> (k : Nat) -> rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r) = True ->
                      LTE (S (strat s (idx + j))) (iret_12_3__level_from s idx rs k)
iret_12_3__level_up s idx [] j r prf k e = absurd prf
iret_12_3__level_up s idx (r' :: rs) Z r prf k e =
  let e' = replace {p = \x => rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds x) = True} (sym (iret_11_4__just_inj prf)) e
  in replace {p = \n => LTE (S (strat s n)) (iret_12_3__level_from s idx (r' :: rs) k)} (sym (plusZeroRightNeutral idx))
       (replace {p = \v => LTE (S (strat s idx)) (iret_12_3__max v (iret_12_3__level_from s (S idx) rs k))} (sym (iret_12_3__level_of_emit s idx r' k e'))
          (iret_12_3__max_left (S (strat s idx)) (iret_12_3__level_from s (S idx) rs k)))
iret_12_3__level_up s idx (r' :: rs) (S j) r prf k e =
  replace {p = \n => LTE (S (strat s n)) (iret_12_3__level_from s idx (r' :: rs) k)} (plusSuccRightSucc idx j)
    (transitive (iret_12_3__level_up s (S idx) rs j r prf k e)
       (iret_12_3__max_right (iret_12_3__level_of s idx r' k) (iret_12_3__level_from s (S idx) rs k)))

--@derives [IRET.12.3]
||| A bound on every emitter's stratum bounds the kind's level.
export
iret_12_3__level_down : (s : Lcyc_3_1__strata) -> (idx : Nat) -> (rs : List Lgra_6_1__rule) -> (k, b : Nat) ->
                        ((j : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth j rs = Just r -> rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r) = True ->
                           LTE (S (strat s (idx + j))) b) ->
                        LTE (iret_12_3__level_from s idx rs k) b
iret_12_3__level_down s idx [] k b h = LTEZero
iret_12_3__level_down s idx (r :: rs) k b h =
  iret_12_3__max_lub (iret_12_3__level_of s idx r k) (iret_12_3__level_from s (S idx) rs k) b
    (iret_12_3__level_of_bound s idx r k b
       (\e => replace {p = \n => LTE (S (strat s n)) b} (plusZeroRightNeutral idx) (h Z r Refl e)))
    (iret_12_3__level_down s (S idx) rs k b
       (\j, q, nq, e => replace {p = \n => LTE (S (strat s n)) b} (sym (plusSuccRightSucc idx j)) (h (S j) q nq e)))

--@derives [IRET.12.3]
||| A fact's rank: its kind's level, zero for an id no live fact carries.
public export
iret_12_3__rank_of : Lcyc_3_1__strata -> List Lgra_6_1__rule -> Maybe Lfac_1_7_1__fact -> Nat
iret_12_3__rank_of s rs Nothing = 0
iret_12_3__rank_of s rs (Just f) = iret_12_3__level_from s 0 rs (fkind f)

--@derives [IRET.12.3]
public export
iret_12_3__rank : Lcyc_3_1__strata -> List Lgra_6_1__rule -> Rarc_5_6_4__wm -> Nat -> Nat
iret_12_3__rank s rs wm i = iret_12_3__rank_of s rs (rarc_5_6_4__lookup_fact i wm)

--@derives [LCYC.3.1.1]
||| Under the certificate an emitter of a kind sits in a strictly
||| lower stratum than any reader of it: no lower by edge monotonicity, and
||| not the same, since no stratum reads what it emits.
export
lcyc_3_1_1__emit_below_read : (p : Lcyc_3_2_1__program) -> (ct : Lcyc_3_1_1__certified_tms p) ->
                              (ri, rj : Nat) -> (r, q : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just r -> rarc_5_6_5__nth rj (rules p) = Just q ->
                              (k : Nat) -> rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r) = True -> rarc_5_6_5__elem k (lcyc_3_2_2__read_kinds q) = True ->
                              LT (strat (tmsStrata ct) ri) (strat (tmsStrata ct) rj)
lcyc_3_1_1__emit_below_read p ct ri rj r q nr nq k ek rk =
  case isLTE (strat (tmsStrata ct) rj) (strat (tmsStrata ct) ri) of
    No nge => notLTEImpliesGT nge
    Yes ge => void (lcyc_1_1__bool_not_both _
                (lcyc_1_1__elem_concat_map lcyc_3_2_2__read_kinds (lcyc_3_1__rules_in (tmsStrata ct) (strat (tmsStrata ct) rj) (rules p))
                   (lcyc_3_1__rules_in_elem (tmsStrata ct) (rules p) (strat (tmsStrata ct) rj) rj q nq Refl) k rk)
                (lcyc_3_1_1__own_reads_none (tmsStrata ct) (rules p) (tmsEdgeMono ct) (tmsNoEmitRead ct) (strat (tmsStrata ct) rj) k
                   (ri ** (r ** (nr, ek, ge)))))

--@derives [IRET.12.3]
||| An antecedent of a live row ranks no higher than the row's stratum: a
||| dead id ranks zero, and a live one is a fact the row's rule read, whose
||| every emitter is in a lower stratum.
export
iret_12_3__ante_bound : (p : Lcyc_3_2_1__program) -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                        (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                        Iret_12__run_inv p dom wm tables rows ->
                        (row : Iret_12_4__row) -> Elem row rows -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth (rrule row) (rules p) = Just rule ->
                        (a : Nat) -> Elem a (rids row) ->
                        LTE (iret_12_3__rank_of (tmsStrata ct) (rules p) (rarc_5_6_4__lookup_fact a wm)) (strat (tmsStrata ct) (rrule row))
iret_12_3__ante_bound p ct dom wm tables rows rinv row er rule nr a ea with (rarc_5_6_4__lookup_fact a wm) proof la
  iret_12_3__ante_bound p ct dom wm tables rows rinv row er rule nr a ea | Nothing = LTEZero
  iret_12_3__ante_bound p ct dom wm tables rows rinv row er rule nr a ea | Just h =
    let (eh, hid) = rarc_5_6_4__lookup_elem a wm h la
    in let (act, _) = iret_12__run_row_live p dom wm tables rows rinv row er
    in let (r' ** (fs ** (nr', idsEq, kindsEq, _, allLive))) = runFacts rinv row er act
    in let rr : (r' = rule)
           rr = iret_11_4__just_inj (trans (sym nr') nr)
    in let (f ** (ef, fa)) = lcyc_1_1__elem_map_inv fid fs (replace {p = \is => Elem a is} (sym idsEq) ea)
    in let fl : (rarc_5_6_4__is_live (fid f) wm = True)
           fl = replace {p = \i => rarc_5_6_4__is_live i wm = True} (trans hid (sym fa)) (rarc_5_6_4__is_live_of h wm eh)
    in let fh : (f = h)
           fh = runUniq rinv f h (indexAll ef allLive fl) eh (trans fa (sym hid))
    in let inPos : Elem (fkind h) (posKinds rule)
           inPos = replace {p = \x => Elem (fkind h) (posKinds x)} rr
                     (replace {p = \ks => Elem (fkind h) ks} kindsEq
                        (replace {p = \x => Elem (fkind x) (lcyc_3_2_2__kinds_of fs)} fh (lcyc_1_1__elem_map_fwd fkind ef)))
    in let readK : (rarc_5_6_5__elem (fkind h) (lcyc_3_2_2__read_kinds rule) = True)
           readK = lcyc_1_1__elem_l_append_left (fkind h) (posKinds rule) (iret_7_9__neg_kinds rule) (lcyc_1_1__elem_l_true (fkind h) (posKinds rule) inPos)
    in iret_12_3__level_down (tmsStrata ct) 0 (rules p) (fkind h) (strat (tmsStrata ct) (rrule row))
         (\ri, q, nq, ek => lcyc_3_1_1__emit_below_read p ct ri (rrule row) q rule nq nr (fkind h) ek readK)

--@derives [IRET.12.3]
--@derives [LCYC.3.1.1]
--@derives [IRET.12.2]
||| THE CERTIFICATE GIVES ACYCLIC SUPPORT. At every state a run
||| of a program certified as [LCYC.3.1.1] admits it reaches between
||| actions, the engine's table is ranked: rank a fact by one more than
||| the highest stratum emitting its kind, and every antecedent of every
||| row ranks strictly below the row's target. So no admitted program reaches
||| the difference.
export
iret_12_3__certified_ranked : (p : Lcyc_3_2_1__program) -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                              (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                              Iret_12_3__ranked (\i => iret_12_3__rank (tmsStrata ct) (rules p) wm i) (iret_12_4__justifs rows)
iret_12_3__certified_ranked p ct dom wm tables rows rinv rk j ej a ea =
  let (row ** (er, aeq, teq)) = iret_12_4__row_justif rows j ej
  in let (_, tlive) = iret_12__run_row_live p dom wm tables rows rinv row er
  in let (g ** (eg, gi)) = rarc_5_6_4__is_live_inv (rtarget row) wm tlive
  in let (h ** lk) = rarc_5_6_4__lookup_some g wm eg
  in let (eh, hid) = rarc_5_6_4__lookup_elem (fid g) wm h lk
  in let lkT : (rarc_5_6_4__lookup_fact (target j) wm = Just h)
         lkT = replace {p = \i => rarc_5_6_4__lookup_fact i wm = Just h} (trans gi (sym teq)) lk
  in let (rule ** (nr, kf)) = rk row er
  in let (ekT, _) = kf h eh (trans hid gi)
  in let upT = iret_12_3__level_up (tmsStrata ct) 0 (rules p) (rrule row) rule nr (fkind h) ekT
  in let tgt : LTE (S (strat (tmsStrata ct) (rrule row))) (iret_12_3__rank_of (tmsStrata ct) (rules p) (rarc_5_6_4__lookup_fact (target j) wm))
         tgt = replace {p = \m => LTE (S (strat (tmsStrata ct) (rrule row))) (iret_12_3__rank_of (tmsStrata ct) (rules p) m)} (sym lkT) upT
  in transitive
       (LTESucc (iret_12_3__ante_bound p ct dom wm tables rows rinv row er rule nr a (replace {p = \as => Elem a as} aeq ea)))
       tgt

--@gap
||| ON EVERY PROGRAM [LCYC.3.1.1] ADMITS, THE STEP IS THE IDENTITY, at
||| every state between actions: the table is ranked, so there is nothing
||| unfounded to retract. Adding recompute-and-diff to the engine changes
||| no run of an admitted program -- the recommendation's containment,
||| for the whole admitted fragment rather than an assumed ranking.
export
gap__rd_certified_identity : (p : Lcyc_3_2_1__program) -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                             (s : Iret_12__state) -> Iret_12__run_inv_s p dom s -> Iret_12_4__run_kind_s p s ->
                             gap__recompute_diff p s = s
gap__rd_certified_identity p ct dom (MkTms (MkState wm tables) rows) rinv rk =
  gap__rd_ranked_identity (\i => iret_12_3__rank (tmsStrata ct) (rules p) wm i) p dom wm tables rows rinv
    (iret_12_3__certified_ranked p ct dom wm tables rows rinv rk)

--@gap
||| And so at the end of every canonical replay of a certified positive
||| program, from any invariant start: the step does nothing there.
export
gap__rd_canonical_identity : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                             ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                             (s : Iret_12__state) -> (evs : List Rarc_5_6_1__event) -> (s' : Iret_12__state) ->
                             Lfst_9_2_1__canonical p s evs s' -> All (Rarc_5_6_1__event_in_dom dom) evs ->
                             Iret_12__run_inv_s p dom s -> Iret_12_4__run_kind_s p s ->
                             gap__recompute_diff p s' = s'
gap__rd_canonical_identity p pos ct dom litsIn s evs s' canon evd rinv rk =
  let (rinv', rk') = lfst_9_2_1__canonical_inv p pos ct dom litsIn s evs s' canon evd rinv rk
  in gap__rd_certified_identity p ct dom s' rinv' rk'

-- ---------------------------------------------------------------------
-- Executed on the engine: the reach run the refcount gets wrong
-- ---------------------------------------------------------------------

--@derives [LLOG.2.5]
||| Executed. Lcyc/TmsWitnesses.idr's reach run (`iret_12_2__reach_engine_run`)
||| ends with the seed withdrawn and both Reach facts live on nothing but
||| each other's justification. Recompute-and-diff at that boundary
||| retracts both, the cascade drops both rows, and what is left is the
||| two edges with every table empty -- the answer [LLOG.2.5] gives and the
||| refcount does not.
|||
||| Checked in stages, each its own `Refl`, as Lcyc/TmsWitnesses.idr's runs
||| are: the diff, the retraction, the propagation, the cascade.
export
llog_2_5__rd_reach_engine :
  gap__recompute_diff Lcyc.TmsWitnesses.iret_12_1__reach_prog
    (MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1]
                    [[], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] True False], []])
           [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3])
  = MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1] [[], [], []]) []
llog_2_5__rd_reach_engine =
  trans (cong (gap__rd_after Lcyc.TmsWitnesses.iret_12_1__reach_prog
                 [MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1]
                 [[], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] True False], []]
                 [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3]) gone)
    (replace {p = \x => iret_12_2__phase Lcyc.TmsWitnesses.iret_12_1__reach_prog
                          (MkTms (MkState x (rarc_5_6_5__propagate Lcyc.TmsWitnesses.iret_12_1__reach_prog x
                                               [[], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] True False], []]))
                                 [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3])
                        = MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1] [[], [], []]) []}
             (sym retracted)
             (replace {p = \t => iret_12_2__phase Lcyc.TmsWitnesses.iret_12_1__reach_prog
                                   (MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1] t) [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3])
                                 = MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1] [[], [], []]) []}
                      (sym propagated) cascaded))
  where
    gone : gap__rd_gone [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3] [MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1] = [3, 4]
    gone = Refl
    retracted : iret_12_2__retract_ids [3, 4] [MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1] = [MkFact 1 5 1 2, MkFact 2 5 2 1]
    retracted = Refl
    propagated : rarc_5_6_5__propagate Lcyc.TmsWitnesses.iret_12_1__reach_prog [MkFact 1 5 1 2, MkFact 2 5 2 1]
                   [[], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] True False], []]
                 = [[], [], []]
    propagated = Refl
    cascaded : iret_12_2__phase Lcyc.TmsWitnesses.iret_12_1__reach_prog
                 (MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1] [[], [], []]) [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3])
               = MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1] [[], [], []]) []
    cascaded = Refl

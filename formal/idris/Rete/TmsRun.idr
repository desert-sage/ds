-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The engine-level invariant: every state of a run with truth
||| maintenance satisfies the bridge's premises, so at every action of
||| every firing the cascade is Rete/Refcount.idr's cascade of the table
||| the action recorded.
|||
||| NORMATIVE COMPANION, on the same mechanisms as Rete/FireLoopTms.idr and
||| Rete/TmsBridge.idr.
|||
||| WHAT IS PROVED. Between actions of a run (`Iret_12__run_inv`): the
||| core invariant, unique fact ids [IRET.4.4], every live row reads as a
||| match, and every row is live -- the cascade that ended the last action
||| ran to its fixpoint. Within a firing (`Iret_12__fire_inv`) the firing
||| activation is tracked too: its reading holds, and it is live whenever
||| its antecedents are, which is what `lfac_2_5_3__fresh_id`'s avoid list
||| is for. The invariant holds initially (`rarc_5_6_5__init_tms_inv`),
||| through every action (`iret_12_2__action_cascade`, which also delivers
||| the bridge's two inclusions for that action), every firing
||| (`iret_11_4__step_tms_inv`) and every run (`iret_11_4__step_n_tms_inv`,
||| `iret_12__run_inv_holds`, and `iret_12__run_inv_certified` for a
||| certified program).
|||
||| PREMISES. Positive programs, as for the bridge. Emitted values in the
||| domain (`Lcyc_3_1_1__range p dom`, which a certificate provides), as
||| the core invariant needs. Unique ids in the input. The id counter is
||| modelled by `lfac_2_5_3__fresh_id` (smallest free id):
||| `lfac_2_5_3__fresh_id_free` is the pigeonhole that it never hands out a
||| live or bound id, which is what [IRET.4.4]'s monotonic counter provides
||| in DS, and `Iret_4_4__keeps` is the consequence every transition of a
||| run has: the id of a surviving fact identifies it.
module Rete.TmsRun

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.Refcount
import Rete.TmsBridge
import Rete.RunFold
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Certificate
import Lcyc.Termination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- Small lemmas
-- ---------------------------------------------------------------------

--@derives [IRET.12]
export
iret_12__tms_inj : {st, st' : Rarc_5_6_5__state} -> {r, r' : Iret_12_4__table} -> MkTms st r = MkTms st' r' -> (st = st', r = r')
iret_12__tms_inj Refl = (Refl, Refl)

--@derives [RARC.5.6.5]
export
rarc_5_6_5__state_inj : {w, w' : Rarc_5_6_4__wm} -> {t, t' : List (List Iret_11__tok)} -> MkState w t = MkState w' t' -> (w = w', t = t')
rarc_5_6_5__state_inj Refl = (Refl, Refl)

--@derives [IRET.12]
export
iret_12__elem_singleton : {x, y : a} -> Elem x [y] -> x = y
iret_12__elem_singleton Here = Refl
iret_12__elem_singleton (There e) = absurd e

--@derives [IRET.12]
export
iret_12__not_of_true : (b : Bool) -> b = True -> not b = False
iret_12__not_of_true True _ = Refl
iret_12__not_of_true False prf = absurd prf

--@derives [IRET.12]
export
iret_12__or_false_split : (a, b : Bool) -> (a || b) = False -> (a = False, b = False)
iret_12__or_false_split True _ prf = absurd prf
iret_12__or_false_split False b prf = (Refl, prf)

--@derives [IRET.12]
export
iret_12__lte_zero : LTE n Z -> n = Z
iret_12__lte_zero LTEZero = Refl

--@derives [IRET.12]
export
iret_12__length_append : (xs, ys : List a) -> length (xs ++ ys) = length xs + length ys
iret_12__length_append [] ys = Refl
iret_12__length_append (x :: xs) ys = cong S (iret_12__length_append xs ys)

--@derives [IRET.12]
||| The order on Nat as a Bool, with the three facts the fresh-id search
||| needs.
public export
iret_12__lte_b : Nat -> Nat -> Bool
iret_12__lte_b Z _ = True
iret_12__lte_b (S _) Z = False
iret_12__lte_b (S a) (S b) = iret_12__lte_b a b

--@derives [IRET.12]
export
iret_12__lte_b_refl : (c : Nat) -> iret_12__lte_b c c = True
iret_12__lte_b_refl Z = Refl
iret_12__lte_b_refl (S c) = iret_12__lte_b_refl c

--@derives [IRET.12]
export
iret_12__lte_b_succ_self : (c : Nat) -> iret_12__lte_b (S c) c = False
iret_12__lte_b_succ_self Z = Refl
iret_12__lte_b_succ_self (S c) = iret_12__lte_b_succ_self c

--@derives [IRET.12]
export
iret_12__lte_b_succ : (c, x : Nat) -> iret_12__lte_b (S c) x = True -> iret_12__lte_b c x = True
iret_12__lte_b_succ Z x _ = Refl
iret_12__lte_b_succ (S c) Z prf = absurd prf
iret_12__lte_b_succ (S c) (S x) prf = iret_12__lte_b_succ c x prf

--@derives [IRET.12]
||| A member survives `set_at`, itself or transformed.
export
iret_12__elem_set_at : (j : Nat) -> (f : a -> a) -> (xs : List a) -> Elem x xs ->
                       Either (Elem x (rarc_5_6_5__set_at j f xs)) (Elem (f x) (rarc_5_6_5__set_at j f xs))
iret_12__elem_set_at j f [] e = absurd e
iret_12__elem_set_at Z f (x :: xs) Here = Right Here
iret_12__elem_set_at Z f (y :: xs) (There e) = Left (There e)
iret_12__elem_set_at (S n) f (x :: xs) Here = Left Here
iret_12__elem_set_at (S n) f (y :: xs) (There e) = case iret_12__elem_set_at n f xs e of
  Left l => Left (There l)
  Right r => Right (There r)

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE ENGINE'S RUN IS THE ONE FOLD at its step (Rete/RunFold.idr's
||| `iret_11_4__run_by`), by induction on the fuel. The two unfoldings below
||| are RunFold's through it.
export
iret_11_4__run_tms_by : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (s : Iret_12__state) ->
                        iret_11_4__run_tms p fuel s = iret_11_4__run_by (iret_11_4__step_tms p) fuel s
iret_11_4__run_tms_by p Z s = Refl
iret_11_4__run_tms_by p (S fuel) s with (iret_11_4__step_tms p s)
  iret_11_4__run_tms_by p (S fuel) s | Nothing = Refl
  iret_11_4__run_tms_by p (S fuel) s | (Just s') with (iret_11_4__run_by (iret_11_4__step_tms p) fuel s') proof rr
    iret_11_4__run_tms_by p (S fuel) s | (Just s') | (t, h, n) = rewrite trans (iret_11_4__run_tms_by p fuel s') rr in Refl

--@derives [IRET.11.4]
||| The engine's run on an empty agenda: one more unit of fuel changes nothing.
export
iret_11_4__run_tms_nothing : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (s : Iret_12__state) -> iret_11_4__step_tms p s = Nothing ->
                             iret_11_4__run_tms p (S fuel) s = (s, Quiescent, 0)
iret_11_4__run_tms_nothing p fuel s eq =
  trans (iret_11_4__run_tms_by p (S fuel) s) (iret_11_4__run_by_nothing (iret_11_4__step_tms p) fuel s eq)

--@derives [IRET.11.4]
||| The engine's run, unfolded by one firing.
export
iret_11_4__run_tms_just : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (s, s' : Iret_12__state) -> iret_11_4__step_tms p s = Just s' ->
                          (t : Iret_12__state) -> (h : Iret_11_4__halt) -> (n : Nat) -> iret_11_4__run_tms p fuel s' = (t, h, n) ->
                          iret_11_4__run_tms p (S fuel) s = (t, h, S n)
iret_11_4__run_tms_just p fuel s s' eq t h n rr =
  trans (iret_11_4__run_tms_by p (S fuel) s)
        (iret_11_4__run_by_just (iret_11_4__step_tms p) fuel s s' eq t h n (trans (sym (iret_11_4__run_tms_by p fuel s')) rr))

-- ---------------------------------------------------------------------
-- What a phase does to the core state
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
export
iret_12_2__phase_after_core_shape : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (kept : Iret_12_4__table) -> (gone : List Nat) ->
                                    (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> (rows' : Iret_12_4__table) ->
                                    iret_12_2__phase_after p wm tables kept gone = MkTms (MkState wm' tables') rows' ->
                                    Either (wm' = wm, tables' = tables)
                                           (g : List Nat ** (wm' = iret_12_2__retract_ids g wm, tables' = rarc_5_6_5__propagate p (iret_12_2__retract_ids g wm) tables))
iret_12_2__phase_after_core_shape p wm tables kept [] wm' tables' rows' eq =
  let (se, _) = iret_12__tms_inj eq in let (we, te) = rarc_5_6_5__state_inj se in Left (sym we, sym te)
iret_12_2__phase_after_core_shape p wm tables kept (g :: gs) wm' tables' rows' eq =
  let (se, _) = iret_12__tms_inj eq in let (we, te) = rarc_5_6_5__state_inj se in Right ((g :: gs) ** (sym we, sym te))

--@derives [IRET.12.2]
||| What a phase does to the core state: nothing, or a retraction and its
||| propagation.
export
iret_12_2__phase_core_shape : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> (rows' : Iret_12_4__table) ->
                              iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows' ->
                              Either (wm' = wm, tables' = tables)
                                     (g : List Nat ** (wm' = iret_12_2__retract_ids g wm, tables' = rarc_5_6_5__propagate p (iret_12_2__retract_ids g wm) tables))
iret_12_2__phase_core_shape p wm tables rows wm' tables' rows' eq with (iret_12_2__ended (MkState wm tables) rows)
  iret_12_2__phase_core_shape p wm tables rows wm' tables' rows' eq | [] =
    let (se, _) = iret_12__tms_inj eq in let (we, te) = rarc_5_6_5__state_inj se in Left (sym we, sym te)
  iret_12_2__phase_core_shape p wm tables rows wm' tables' rows' eq | (x :: xs) =
    iret_12_2__phase_after_core_shape p wm tables (iret_12_2__kept (MkState wm tables) rows)
      (iret_12_2__zeroed (x :: xs) (iret_12_2__kept (MkState wm tables) rows)) wm' tables' rows' eq

-- ---------------------------------------------------------------------
-- A tracked activation through a cascade
-- ---------------------------------------------------------------------

--@derives [IRET.7.8]
||| An activation tracked through a cascade: its reading holds, and it is
||| live whenever its antecedents all are. Its target is irrelevant; the
||| firing activation is tracked as `MkRow r ids 0`.
public export
Iret_7_8__tracked : Lcyc_3_2_1__program -> Rarc_5_6_4__wm -> List (List Iret_11__tok) -> Iret_12_4__row -> Type
Iret_7_8__tracked p wm tables v =
  (Iret_12_4__row_facts p wm v, iret_12__all_in (rids v) (iret_11_3__fact_ids wm) = True -> iret_7_8__activation_live tables v = True)

--@derives [IRET.7.8]
||| A retraction and its propagation keep a tracked activation.
export
iret_7_8__tracked_retract : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) ->
                            Lcyc_1_1__inv p dom (MkState wm tables) -> Iret_4_4__unique wm -> (gone : List Nat) -> (v : Iret_12_4__row) ->
                            Iret_7_8__tracked p wm tables v ->
                            Iret_7_8__tracked p (iret_12_2__retract_ids gone wm) (rarc_5_6_5__propagate p (iret_12_2__retract_ids gone wm) tables) v
iret_7_8__tracked_retract p pos dom wm tables inv uniq gone v (rf, lv) =
  let rf' : Iret_12_4__row_facts p (iret_12_2__retract_ids gone wm) v
      rf' = iret_12_4__row_facts_retract gone wm uniq p v rf
  in (rf', \al => iret_7_8__live_after_propagate p pos dom (MkState wm tables) inv (iret_12_2__retract_ids gone wm) v rf' al
                    (lv (iret_12__all_in_sub (rids v) _ _ (iret_12_2__live_before gone wm) al)))

--@derives [IRET.12.2]
||| One phase keeps a tracked activation.
export
iret_12_2__phase_tracked : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                           (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                           Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows ->
                           (v : Iret_12_4__row) -> Iret_7_8__tracked p wm tables v ->
                           (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> (rows' : Iret_12_4__table) ->
                           iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows' ->
                           Iret_7_8__tracked p wm' tables' v
iret_12_2__phase_tracked p pos dom rows0 live0 wm tables rows inv v tr wm' tables' rows' eq =
  case iret_12_2__phase_core_shape p wm tables rows wm' tables' rows' eq of
    Left (we, te) => replace {p = \w => Iret_7_8__tracked p w tables' v} (sym we) (replace {p = \t => Iret_7_8__tracked p wm t v} (sym te) tr)
    Right (gone ** (we, te)) =>
      replace {p = \w => Iret_7_8__tracked p w tables' v} (sym we)
        (replace {p = \t => Iret_7_8__tracked p (iret_12_2__retract_ids gone wm) t v} (sym te)
           (iret_7_8__tracked_retract p pos dom wm tables (coreInv inv) (uniq inv) gone v tr))

--@derives [IRET.12.2]
||| And so does any number of phases, alongside the cascade invariant.
export
iret_12_2__phase_n_tracked : (n : Nat) -> (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                             (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows -> (v : Iret_12_4__row) -> Iret_7_8__tracked p wm tables v ->
                             (wm' ** (tables' ** (rows' **
                               ( iret_12_2__phase_n n p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                               , Iret_12_2__cascade_inv p dom rows0 live0 wm' tables' rows'
                               , Iret_7_8__tracked p wm' tables' v ))))
iret_12_2__phase_n_tracked Z p pos dom rows0 live0 wm tables rows inv v tr = (wm ** (tables ** (rows ** (Refl, inv, tr))))
iret_12_2__phase_n_tracked (S n) p pos dom rows0 live0 wm tables rows inv v tr =
  case iret_12_2__phase_preserves p pos dom rows0 live0 wm tables rows inv of
    (wm1 ** (tables1 ** (rows1 ** (eq, inv1)))) =>
      case iret_12_2__phase_n_tracked n p pos dom rows0 live0 wm1 tables1 rows1 inv1 v
             (iret_12_2__phase_tracked p pos dom rows0 live0 wm tables rows inv v tr wm1 tables1 rows1 eq) of
        (wm2 ** (tables2 ** (rows2 ** (eq2, inv2, tr2)))) =>
          (wm2 ** (tables2 ** (rows2 ** (trans (iret_12_2__phase_n_succ n p (MkTms (MkState wm tables) rows) (MkState wm1 tables1) rows1 eq) eq2, inv2, tr2))))

--@derives [IRET.12.2]
||| THE BRIDGE WITH A TRACKED ACTIVATION: the bridge's cascade, whose
||| final state satisfies the cascade invariant and ends nothing, and a
||| tracked activation stays tracked.
export
iret_12_2__cascade_tracked : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                             (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             Lcyc_1_1__inv p dom (MkState wm tables) -> Iret_4_4__unique wm ->
                             ((row : Iret_12_4__row) -> Elem row rows -> iret_7_8__activation_live tables row = True -> Iret_12_4__row_facts p wm row) ->
                             ((row : Iret_12_4__row) -> Elem row rows -> iret_12__all_in (rids row) (iret_11_3__fact_ids wm) = True ->
                                rarc_5_6_4__is_live (rtarget row) wm = True -> iret_7_8__activation_live tables row = True) ->
                             (v : Iret_12_4__row) -> Iret_7_8__tracked p wm tables v ->
                             (wmF ** (tablesF ** (rowsF **
                               ( iret_12_2__phase p (MkTms (MkState wm tables) rows) = MkTms (MkState wmF tablesF) rowsF
                               , Iret_12_2__cascade_inv p dom rows (iret_11_3__fact_ids wm) wmF tablesF rowsF
                               , iret_12_2__ended (MkState wmF tablesF) rowsF = []
                               , Iret_7_8__tracked p wmF tablesF v ))))
iret_12_2__cascade_tracked p pos dom wm tables rows cinv uq rf rl v tr =
  let inv0 : Iret_12_2__cascade_inv p dom rows (iret_11_3__fact_ids wm) wm tables rows
      inv0 = MkCascadeInv cinv uq (\row, e => e) (\i, e => e) rf (\row, e, al, tl => (e, rl row e al tl))
               (iret_12_2__cascade_sub (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
               (iret_12_2__base_row rows (iret_11_3__fact_ids wm))
  in case iret_12_2__phase_n_tracked (S (length rows)) p pos dom rows (iret_11_3__fact_ids wm) wm tables rows inv0 v tr of
       (wmF ** (tablesF ** (rowsF ** (eq, invF, trF)))) =>
         (wmF ** (tablesF ** (rowsF **
           ( eq
           , invF
           , replace {p = \x => iret_12_2__ended (core x) (deps x) = []} eq
               (iret_12_2__phase_n_fixed (S (length rows)) p wm tables rows (iret_12__lte_succ_self (length rows)))
           , trF ))))

-- ---------------------------------------------------------------------
-- Ids identify facts across a change of working memory
-- ---------------------------------------------------------------------

--@derives [IRET.4.4]
||| A fact live before whose id is live after is itself live after. Every
||| transition of a run has this shape, since a fresh id is never a live
||| one; it is what makes an id stand for a fact across the change.
public export
Iret_4_4__keeps : Rarc_5_6_4__wm -> Rarc_5_6_4__wm -> Type
Iret_4_4__keeps wm wm' = (f : Lfac_1_7_1__fact) -> Elem f wm -> rarc_5_6_4__is_live (fid f) wm' = True -> Elem f wm'

--@derives [IRET.4.4]
export
iret_4_4__keeps_filter : (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (q : Lfac_1_7_1__fact -> Bool) -> Iret_4_4__keeps wm (filter q wm)
iret_4_4__keeps_filter wm uniq q f ef isl = case rarc_5_6_4__is_live_inv (fid f) (filter q wm) isl of
  (g ** (eg, eq)) => replace {p = \x => Elem x (filter q wm)} (sym (uniq f g ef (fst (lcyc_1_1__elem_filter_inv q wm eg)) (sym eq))) eg

--@derives [IRET.4.4]
export
iret_4_4__keeps_append : (wm : Rarc_5_6_4__wm) -> (new : Lfac_1_7_1__fact) -> Iret_4_4__keeps wm (wm ++ [new])
iret_4_4__keeps_append wm new f ef _ = lcyc_1_1__elem_append_left ef

--@derives [IRET.4.4]
export
iret_4_4__keeps_replace : (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (old, new : Lfac_1_7_1__fact) -> rarc_5_6_4__is_live (fid new) wm = False ->
                          Iret_4_4__keeps wm (rarc_5_6_4__remove_exact old wm ++ [new])
iret_4_4__keeps_replace wm uniq old new fresh f ef isl = case rarc_5_6_4__is_live_inv (fid f) (rarc_5_6_4__remove_exact old wm ++ [new]) isl of
  (g ** (eg, eq)) => case lcyc_1_1__elem_append_inv (rarc_5_6_4__remove_exact old wm) eg of
    Left er => lcyc_1_1__elem_append_left
                 (replace {p = \x => Elem x (rarc_5_6_4__remove_exact old wm)}
                          (sym (uniq f g ef (fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h old)) wm er)) (sym eq))) er)
    Right en => void (lcyc_1_1__bool_not_both _
                        (replace {p = \j => rarc_5_6_4__is_live j wm = True} (sym (trans (sym (cong fid (iret_12__elem_singleton en))) eq)) (rarc_5_6_4__is_live_of f wm ef))
                        fresh)

--@derives [IRET.4.4]
export
iret_4_4__unique_filter : (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (q : Lfac_1_7_1__fact -> Bool) -> Iret_4_4__unique (filter q wm)
iret_4_4__unique_filter wm uniq q f g ef eg eq = uniq f g (fst (lcyc_1_1__elem_filter_inv q wm ef)) (fst (lcyc_1_1__elem_filter_inv q wm eg)) eq

--@derives [IRET.4.4]
export
iret_4_4__unique_append : (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (new : Lfac_1_7_1__fact) -> rarc_5_6_4__is_live (fid new) wm = False ->
                          Iret_4_4__unique (wm ++ [new])
iret_4_4__unique_append wm uniq new fresh f g ef eg eq = case (lcyc_1_1__elem_append_inv wm ef, lcyc_1_1__elem_append_inv wm eg) of
  (Left ef', Left eg') => uniq f g ef' eg' eq
  (Left ef', Right en) => void (lcyc_1_1__bool_not_both _
                                 (replace {p = \j => rarc_5_6_4__is_live j wm = True} (trans eq (cong fid (iret_12__elem_singleton en))) (rarc_5_6_4__is_live_of f wm ef'))
                                 fresh)
  (Right en, Left eg') => void (lcyc_1_1__bool_not_both _
                                 (replace {p = \j => rarc_5_6_4__is_live j wm = True} (trans (sym eq) (cong fid (iret_12__elem_singleton en))) (rarc_5_6_4__is_live_of g wm eg'))
                                 fresh)
  (Right en, Right en') => trans (iret_12__elem_singleton en) (sym (iret_12__elem_singleton en'))

--@derives [RARC.5.6.4]
||| Not live in a working memory, not live in any part of it.
export
rarc_5_6_4__is_live_sub : (i : Nat) -> (wm, wm' : Rarc_5_6_4__wm) -> ((g : Lfac_1_7_1__fact) -> Elem g wm' -> Elem g wm) ->
                          rarc_5_6_4__is_live i wm = False -> rarc_5_6_4__is_live i wm' = False
rarc_5_6_4__is_live_sub i wm wm' sub nl = iret_12__bool_false_of _ (\l => case rarc_5_6_4__is_live_inv i wm' l of
  (g ** (eg, eq)) => lcyc_1_1__bool_not_both _ (replace {p = \j => rarc_5_6_4__is_live j wm = True} eq (rarc_5_6_4__is_live_of g wm (sub g eg))) nl)

--@derives [IRET.4.4]
export
iret_4_4__unique_replace : (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (old, new : Lfac_1_7_1__fact) -> rarc_5_6_4__is_live (fid new) wm = False ->
                           Iret_4_4__unique (rarc_5_6_4__remove_exact old wm ++ [new])
iret_4_4__unique_replace wm uniq old new fresh =
  iret_4_4__unique_append (rarc_5_6_4__remove_exact old wm) (iret_4_4__unique_filter wm uniq (\h => not (lfac_2_5_4__same_fact h old))) new
    (rarc_5_6_4__is_live_sub (fid new) wm (rarc_5_6_4__remove_exact old wm)
       (\g, eg => fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h old)) wm eg)) fresh)

-- ---------------------------------------------------------------------
-- The fresh id is free: the pigeonhole
-- ---------------------------------------------------------------------

--@derives [LFAC.2.5.3]
||| The search invariant: with fuel at least the number of excluded values
||| at or above the candidate, the search returns a free value. Every
||| excluded candidate it passes drops one from that count.
export
lfac_2_5_3__fresh_from_free : (fuel, cand : Nat) -> (avoid : List Nat) -> (wm : Rarc_5_6_4__wm) ->
                              LTE (length (filter (iret_12__lte_b cand) (iret_11_3__fact_ids wm ++ avoid))) fuel ->
                              ( rarc_5_6_4__is_live (lfac_2_5_3__fresh_from fuel cand avoid wm) wm = False
                              , rarc_5_6_5__elem (lfac_2_5_3__fresh_from fuel cand avoid wm) avoid = False )
lfac_2_5_3__fresh_from_free Z cand avoid wm lte =
  let none : (x : Nat) -> Elem x (iret_11_3__fact_ids wm ++ avoid) -> iret_12__lte_b cand x = True -> Void
      none x e le = iret_12__elem_nonempty (filter (iret_12__lte_b cand) (iret_11_3__fact_ids wm ++ avoid))
                      (lcyc_1_1__elem_filter_fwd (iret_12__lte_b cand) (iret_11_3__fact_ids wm ++ avoid) e le) (iret_12__lte_zero lte)
  in ( iret_12__bool_false_of _ (\l => case rarc_5_6_4__is_live_inv cand wm l of
         (g ** (eg, eq)) => none cand (lcyc_1_1__elem_append_left (replace {p = \j => Elem j (iret_11_3__fact_ids wm)} eq (lcyc_1_1__elem_map_fwd fid eg))) (iret_12__lte_b_refl cand))
     , iret_12__bool_false_of _ (\a => none cand (lcyc_1_1__elem_append_right (iret_11_3__fact_ids wm) (lcyc_1_1__elem_l_elem cand avoid a)) (iret_12__lte_b_refl cand)) )
lfac_2_5_3__fresh_from_free (S n) cand avoid wm lte with (rarc_5_6_4__is_live cand wm || rarc_5_6_5__elem cand avoid) proof c
  lfac_2_5_3__fresh_from_free (S n) cand avoid wm lte | False = iret_12__or_false_split _ _ c
  lfac_2_5_3__fresh_from_free (S n) cand avoid wm lte | True =
    let inEx : Elem cand (iret_11_3__fact_ids wm ++ avoid)
        inEx = case iret_12__or_inv _ _ c of
          Left l => case rarc_5_6_4__is_live_inv cand wm l of
            (g ** (eg, eq)) => lcyc_1_1__elem_append_left (replace {p = \j => Elem j (iret_11_3__fact_ids wm)} eq (lcyc_1_1__elem_map_fwd fid eg))
          Right a => lcyc_1_1__elem_append_right (iret_11_3__fact_ids wm) (lcyc_1_1__elem_l_elem cand avoid a)
        lt : LT (length (filter (iret_12__lte_b (S cand)) (iret_11_3__fact_ids wm ++ avoid))) (length (filter (iret_12__lte_b cand) (iret_11_3__fact_ids wm ++ avoid)))
        lt = lcyc_1_1__filter_strict (iret_12__lte_b cand) (iret_12__lte_b (S cand)) (iret_12__lte_b_succ cand) (iret_11_3__fact_ids wm ++ avoid) cand inEx
               (iret_12__lte_b_refl cand) (iret_12__lte_b_succ_self cand)
    in lfac_2_5_3__fresh_from_free n (S cand) avoid wm (fromLteSucc (transitive lt lte))

--@derives [LFAC.2.5.3]
--@derives [IRET.4.4]
||| THE FRESH ID IS FREE: neither live nor bound. Among the first
||| |wm| + |avoid| + 1 naturals one is neither a live id nor a bound one,
||| and the search returns the first such. What [IRET.4.4]'s monotonic
||| counter provides, on the model's smallest-free-id.
export
lfac_2_5_3__fresh_id_free : (avoid : List Nat) -> (wm : Rarc_5_6_4__wm) ->
                            ( rarc_5_6_4__is_live (lfac_2_5_3__fresh_id avoid wm) wm = False
                            , rarc_5_6_5__elem (lfac_2_5_3__fresh_id avoid wm) avoid = False )
lfac_2_5_3__fresh_id_free avoid wm =
  lfac_2_5_3__fresh_from_free (S (length wm + length avoid)) 0 avoid wm
    (transitive (iret_12_2__filter_lte (iret_12__lte_b 0) (iret_11_3__fact_ids wm ++ avoid))
       (replace {p = \n => LTE n (S (length wm + length avoid))}
                (sym (trans (iret_12__length_append (iret_11_3__fact_ids wm) avoid) (cong (\n => n + length avoid) (lengthMap wm))))
                (iret_12__lte_succ_self (length wm + length avoid))))

-- ---------------------------------------------------------------------
-- Readings across a change of working memory
-- ---------------------------------------------------------------------

--@derives [IRET.12.4]
||| A row's reading survives a change that keeps the facts of surviving
||| ids and adds only facts with ids outside the row.
export
iret_12_4__row_facts_keeps : (p : Lcyc_3_2_1__program) -> (wm, wm' : Rarc_5_6_4__wm) -> Iret_4_4__keeps wm wm' -> (row : Iret_12_4__row) ->
                             ((g : Lfac_1_7_1__fact) -> Elem g wm' -> Either (Elem g wm) (rarc_5_6_5__elem (fid g) (rids row) = False)) ->
                             Iret_12_4__row_facts p wm row -> Iret_12_4__row_facts p wm' row
iret_12_4__row_facts_keeps p wm wm' keeps row adds (r ** (fs ** (nr, ids, kinds, gd, liv))) =
  (r ** (fs ** (nr, ids, kinds, gd,
    lcyc_1_1__all_from_elem fs (\f, ef, isl =>
      case rarc_5_6_4__is_live_inv (fid f) wm' isl of
        (g ** (eg, eq)) => case adds g eg of
          Left egw => keeps f (lcyc_1_1__all_lookup liv ef (replace {p = \j => rarc_5_6_4__is_live j wm = True} eq (rarc_5_6_4__is_live_of g wm egw))) isl
          Right nb => void (lcyc_1_1__elem_l_false_not (fid g) (rids row) nb
                              (replace {p = \j => Elem j (rids row)} (sym eq) (replace {p = \l => Elem (fid f) l} ids (lcyc_1_1__elem_map_fwd fid ef))))))))

--@derives [IRET.12]
||| An id not live is not among ids that are all live.
export
iret_12__all_in_not_live : (ids : List Nat) -> (wm : Rarc_5_6_4__wm) -> iret_12__all_in ids (iret_11_3__fact_ids wm) = True -> (i : Nat) ->
                           rarc_5_6_4__is_live i wm = False -> rarc_5_6_5__elem i ids = False
iret_12__all_in_not_live ids wm al i nl = iret_12__bool_false_of _ (\e =>
  case iret_12_4__live_id i wm (iret_12__all_in_elem ids (iret_11_3__fact_ids wm) al i (lcyc_1_1__elem_l_elem i ids e)) of
    (g ** (eg, eq)) => lcyc_1_1__bool_not_both _ (replace {p = \j => rarc_5_6_4__is_live j wm = True} eq (rarc_5_6_4__is_live_of g wm eg)) nl)

--@derives [IRET.12]
||| Ids all live after a change that added no fact with one of them were
||| all live before.
export
iret_12__all_in_back : (ids : List Nat) -> (wm, wm' : Rarc_5_6_4__wm) ->
                       ((g : Lfac_1_7_1__fact) -> Elem g wm' -> Either (Elem g wm) (rarc_5_6_5__elem (fid g) ids = False)) ->
                       iret_12__all_in ids (iret_11_3__fact_ids wm') = True -> iret_12__all_in ids (iret_11_3__fact_ids wm) = True
iret_12__all_in_back ids wm wm' adds al = iret_12__all_in_from ids (iret_11_3__fact_ids wm) (\i, ei =>
  case iret_12_4__live_id i wm' (iret_12__all_in_elem ids (iret_11_3__fact_ids wm') al i ei) of
    (g ** (eg, eq)) => case adds g eg of
      Left egw => replace {p = \j => iret_12__elem j (iret_11_3__fact_ids wm) = True} eq (iret_12_4__id_live g wm egw)
      Right nb => void (lcyc_1_1__elem_l_false_not (fid g) ids nb (replace {p = \j => Elem j ids} (sym eq) ei)))

--@derives [IRET.10.2]
||| A row of the table after a record is an old row or the recorded one,
||| whose target is a live fact of the emitted kind.
export
iret_10_2__record_elem : (p : Lcyc_3_2_1__program) -> (r : Nat) -> (ids : List Nat) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) ->
                         (wm : Rarc_5_6_4__wm) -> (rows : Iret_12_4__table) -> (row : Iret_12_4__row) ->
                         Elem row (iret_10_2__record p r ids bound a wm rows) ->
                         Either (Elem row rows)
                                (f : Lfac_1_7_1__fact ** (Elem f wm, row = MkRow r ids (fid f),
                                  (k : Nat ** (v : List Lfac_1_7_1__fact -> (Nat, Nat) ** (a = Emit k v, fkind f = k, Not (life p k = Explicit))))))
iret_10_2__record_elem p r ids bound (Withdraw _) wm rows row e = Left e
iret_10_2__record_elem p r ids bound (Emit k v) wm rows row e with (life p k) proof le
  iret_10_2__record_elem p r ids bound (Emit k v) wm rows row e | Explicit = Left e
  iret_10_2__record_elem p r ids bound (Emit k v) wm rows row e | Relation with (iret_19_1__find_relation k (fst (v bound)) (snd (v bound)) wm) proof fr
    iret_10_2__record_elem p r ids bound (Emit k v) wm rows row e | Relation | Nothing = Left e
    iret_10_2__record_elem p r ids bound (Emit k v) wm rows row e | Relation | (Just f) = case lcyc_1_1__elem_append_inv rows e of
      Left e' => Left e'
      Right e1 => let (q, ef) = lcyc_1_1__find_just _ wm fr
                  in Right (f ** (ef, iret_12__elem_singleton e1,
                             (k ** (v ** (Refl, lcyc_1_1__nat_eq_true (fkind f) k (lcyc_1_1__and_true_l _ _ q),
                                          \ex => lscp_1_3__relation_not_explicit (trans (sym le) ex))))))
  iret_10_2__record_elem p r ids bound (Emit k v) wm rows row e | Entity with (iret_19_1__find_entity k (fst (v bound)) wm) proof fe
    iret_10_2__record_elem p r ids bound (Emit k v) wm rows row e | Entity | Nothing = Left e
    iret_10_2__record_elem p r ids bound (Emit k v) wm rows row e | Entity | (Just f) = case lcyc_1_1__elem_append_inv rows e of
      Left e' => Left e'
      Right e1 => let (q, ef) = lcyc_1_1__find_just _ wm fe
                  in Right (f ** (ef, iret_12__elem_singleton e1,
                             (k ** (v ** (Refl, lcyc_1_1__nat_eq_true (fkind f) k (lcyc_1_1__and_true_l _ _ q),
                                          \ex => lscp_1_3__entity_not_explicit (trans (sym le) ex))))))

--@derives [IDAT.6.2.2]
||| Marking a token fired ends no activation.
export
idat_6_2_2__mark_keeps_live : (r, j : Nat) -> (tables : List (List Iret_11__tok)) -> (row : Iret_12_4__row) ->
                              iret_7_8__activation_live tables row = True -> iret_7_8__activation_live (idat_6_2_2__mark_fired r j tables) row = True
idat_6_2_2__mark_keeps_live r j tables row act with (rarc_5_6_5__nth (rrule row) tables) proof nt
  idat_6_2_2__mark_keeps_live r j tables row act | Nothing = absurd act
  idat_6_2_2__mark_keeps_live r j tables row act | (Just ts) = case decEq r (rrule row) of
    Yes req =>
      let nt' : (rarc_5_6_5__nth (rrule row) (rarc_5_6_5__set_at r (idat_6_2_2__mark_at j) tables) = Just (idat_6_2_2__mark_at j ts))
          nt' = replace {p = \x => rarc_5_6_5__nth (rrule row) (rarc_5_6_5__set_at x (idat_6_2_2__mark_at j) tables) = Just (idat_6_2_2__mark_at j ts)} (sym req)
                  (trans (lcyc_1_1__nth_set_at_eq (rrule row) (idat_6_2_2__mark_at j) tables) (cong (map (idat_6_2_2__mark_at j)) nt))
      in let (t ** (te, ok)) = iret_12_2__any_true (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) ts act
      in let okM : (((iret_11_3__ids (idat_6_2_2__mark_t t) == rids row) && (fired (idat_6_2_2__mark_t t) && not (blocked (idat_6_2_2__mark_t t)))) = True)
             okM = iret_7_8__live_token_ok row (idat_6_2_2__mark_t t) (lcyc_1_1__list_nat_eq_true _ _ (lcyc_1_1__and_true_l _ _ ok)) Refl
                     (lcyc_1_1__not_true_is_false _ (lcyc_1_1__and_true_r _ _ (lcyc_1_1__and_true_r _ _ ok)))
      in replace {p = \tbl => rarc_5_6_5__any (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) tbl = True}
                 (sym (iret_11__table_at_nth (rrule row) (rarc_5_6_5__set_at r (idat_6_2_2__mark_at j) tables) (idat_6_2_2__mark_at j ts) nt'))
                 (case iret_12__elem_set_at j idat_6_2_2__mark_t ts te of
                    Left tl => lcyc_1_1__any_elem (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) (idat_6_2_2__mark_at j ts) tl ok
                    Right tr => lcyc_1_1__any_elem (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) (idat_6_2_2__mark_at j ts) tr okM)
    No neq =>
      replace {p = \m => rarc_5_6_5__any (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) (iret_11__from_maybe m) = True}
              (sym (lcyc_1_1__nth_set_at_neq r (rrule row) neq (idat_6_2_2__mark_at j) tables))
              (replace {p = \m => rarc_5_6_5__any (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) (iret_11__from_maybe m) = True} (sym nt) act)

-- `lcyc_3_1_1__emit_in_dom` and `lcyc_3_1_1__range_widen`, once here, are
-- Lcyc/Termination.idr's: the core engine's action step uses them too.

-- ---------------------------------------------------------------------
-- One core action
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.7]
||| What a core action that changed working memory did to it: kept every
||| surviving id's fact, added at most facts with an id neither live
||| before nor bound by the firing token, left ids unique, and touched
||| only one kind, one the rule writes.
public export
record Rarc_5_6_7__action_shape (rule : Lgra_6_1__rule) (bound : List Lfac_1_7_1__fact) (a : Lgra_10_1__action) (wm : Rarc_5_6_4__wm) (wm' : Rarc_5_6_4__wm) where
  constructor MkActionShape
  shKeeps : Iret_4_4__keeps wm wm'
  shAdds  : (g : Lfac_1_7_1__fact) -> Elem g wm' ->
            Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False, rarc_5_6_5__elem (fid g) (iret_11_3__fact_ids bound) = False)
  shUniq  : Iret_4_4__unique wm'
  shFrame : (k : Nat ** (rarc_5_6_5__elem k (lcyc_3_2_2__write_kinds rule) = True, Rarc_5_6_4__frame k wm wm'))
  shMint  : (g : Lfac_1_7_1__fact) -> Elem g wm' ->
            Either (Elem g wm)
                   (k : Nat ** (v : List Lfac_1_7_1__fact -> (Nat, Nat) **
                     (a = Emit k v, g = MkFact (lfac_2_5_3__fresh_id (iret_11_3__fact_ids bound) wm) k (fst (v bound)) (snd (v bound)))))

--@derives [RARC.5.6.7]
||| An action that changed nothing.
export
rarc_5_6_7__action_noop : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (rule : Lgra_6_1__rule) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) ->
                          (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> Lcyc_1_1__inv p dom (MkState wm tables) ->
                          (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> MkState wm tables = MkState wm' tables' ->
                          ( Lcyc_1_1__inv p dom (MkState wm' tables')
                          , Either (wm' = wm, tables' = tables) (Rarc_5_6_7__action_shape rule bound a wm wm', tables' = rarc_5_6_5__propagate p wm' tables) )
rarc_5_6_7__action_noop p dom rule bound a wm tables inv wm' tables' eq =
  let (we, te) = rarc_5_6_5__state_inj eq
  in ( replace {p = \t => Lcyc_1_1__inv p dom (MkState wm' t)} te (replace {p = \w => Lcyc_1_1__inv p dom (MkState w tables)} we inv)
     , Left (sym we, sym te) )

--@derives [IRET.19.1]
||| A successful assert: the invariant holds after propagation, and the
||| change has the action shape -- the new fact's id is fresh and unbound.
export
iret_19_1__emit_core : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                       (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                       (bound : List Lfac_1_7_1__fact) -> All (\f => Elem (lfac_2_5_1__val f) dom) bound ->
                       (k : Nat) -> (v : List Lfac_1_7_1__fact -> (Nat, Nat)) -> Elem (Emit k v) (actions rule) ->
                       (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> Lcyc_1_1__inv p dom (MkState wm tables) -> Iret_4_4__unique wm ->
                       (w' : Rarc_5_6_4__wm) ->
                       iret_19_1__assert_fact (life p k) (iret_11_3__fact_ids bound) k (fst (v bound)) (snd (v bound)) wm = Just w' ->
                       (Lcyc_1_1__inv p dom (MkState w' (rarc_5_6_5__propagate p w' tables)), Rarc_5_6_7__action_shape rule bound (Emit k v) wm w')
iret_19_1__emit_core p dom range r rule nr bound bd k v ea wm tables inv uniq w' af =
  let inDom : Elem (fst (v bound), snd (v bound)) dom
      inDom = replace {p = \x => Elem x dom} (sym (lcyc_1_1__pair_eta (v bound))) (lcyc_3_1_1__emit_in_dom p dom range r rule nr bound bd k v ea)
      wk : (rarc_5_6_5__elem k (lcyc_3_2_2__write_kinds rule) = True)
      wk = lcyc_1_1__elem_l_append_left k (lcyc_3_2_2__emit_kinds rule) (lcyc_3_2_2__withdraw_kinds rule) (lcyc_3_2_2__emit_kinds_has rule k v ea)
      fr : Rarc_5_6_4__frame k wm w'
      fr = iret_19_1__emit_frame (life p k) (iret_11_3__fact_ids bound) k (fst (v bound)) (snd (v bound)) wm w' af
  in let (fresh, notBound) = lfac_2_5_3__fresh_id_free (iret_11_3__fact_ids bound) wm
  in case iret_19_1__emit_shape (life p k) (iret_11_3__fact_ids bound) k (fst (v bound)) (snd (v bound)) wm w' af of
       Left eq =>
         ( lcyc_1_1__propagate_inv p dom (MkState wm tables) inv w'
             (replace {p = \w => All (\f => Elem (lfac_2_5_1__val f) dom) w} (sym eq) (lcyc_1_1__all_append (wmDom inv) [inDom]))
         , replace {p = \w => Rarc_5_6_7__action_shape rule bound (Emit k v) wm w} (sym eq)
             (MkActionShape (iret_4_4__keeps_append wm _)
                (\g, eg => case lcyc_1_1__elem_append_inv wm eg of
                   Left e => Left e
                   Right e1 => Right (replace {p = \x => (rarc_5_6_4__is_live (fid x) wm = False, rarc_5_6_5__elem (fid x) (iret_11_3__fact_ids bound) = False)}
                                              (sym (iret_12__elem_singleton e1)) (fresh, notBound)))
                (iret_4_4__unique_append wm uniq _ fresh)
                (k ** (wk, replace {p = \w => Rarc_5_6_4__frame k wm w} eq fr))
                (\g, eg => case lcyc_1_1__elem_append_inv wm eg of
                   Left e => Left e
                   Right e1 => Right (k ** (v ** (Refl, iret_12__elem_singleton e1))))) )
       Right (old ** (_, eq)) =>
         ( lcyc_1_1__propagate_inv p dom (MkState wm tables) inv w'
             (replace {p = \w => All (\f => Elem (lfac_2_5_1__val f) dom) w} (sym eq)
                (lcyc_1_1__all_append (lcyc_1_1__all_filter (\g => not (lfac_2_5_4__same_fact g old)) wm (wmDom inv)) [inDom]))
         , replace {p = \w => Rarc_5_6_7__action_shape rule bound (Emit k v) wm w} (sym eq)
             (MkActionShape (iret_4_4__keeps_replace wm uniq old _ fresh)
                (\g, eg => case lcyc_1_1__elem_append_inv (rarc_5_6_4__remove_exact old wm) eg of
                   Left e => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h old)) wm e))
                   Right e1 => Right (replace {p = \x => (rarc_5_6_4__is_live (fid x) wm = False, rarc_5_6_5__elem (fid x) (iret_11_3__fact_ids bound) = False)}
                                              (sym (iret_12__elem_singleton e1)) (fresh, notBound)))
                (iret_4_4__unique_replace wm uniq old _ fresh)
                (k ** (wk, replace {p = \w => Rarc_5_6_4__frame k wm w} eq fr))
                (\g, eg => case lcyc_1_1__elem_append_inv (rarc_5_6_4__remove_exact old wm) eg of
                   Left e => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h old)) wm e))
                   Right e1 => Right (k ** (v ** (Refl, iret_12__elem_singleton e1))))) )

--@derives [RARC.5.6.7]
||| One core action from an invariant state with unique ids: the invariant
||| holds after, and working memory is unchanged with the tables, or
||| changed as `Rarc_5_6_7__action_shape` says and propagated.
export
rarc_5_6_7__action_core : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                          (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                          (bound : List Lfac_1_7_1__fact) -> lcyc_3_2_2__kinds_of bound = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) bound ->
                          (a : Lgra_10_1__action) -> Elem a (actions rule) ->
                          (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> Lcyc_1_1__inv p dom (MkState wm tables) -> Iret_4_4__unique wm ->
                          (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) ->
                          rarc_5_6_7__do_action p bound a (MkState wm tables) = MkState wm' tables' ->
                          ( Lcyc_1_1__inv p dom (MkState wm' tables')
                          , Either (wm' = wm, tables' = tables) (Rarc_5_6_7__action_shape rule bound a wm wm', tables' = rarc_5_6_5__propagate p wm' tables) )
rarc_5_6_7__action_core p dom range r rule nr bound bk bd (Emit k v) ea wm tables inv uniq wm' tables' da
  with (iret_19_1__assert_fact (life p k) (iret_11_3__fact_ids bound) k (fst (v bound)) (snd (v bound)) wm) proof af
  rarc_5_6_7__action_core p dom range r rule nr bound bk bd (Emit k v) ea wm tables inv uniq wm' tables' da | Nothing =
    rarc_5_6_7__action_noop p dom rule bound (Emit k v) wm tables inv wm' tables' da
  rarc_5_6_7__action_core p dom range r rule nr bound bk bd (Emit k v) ea wm tables inv uniq wm' tables' da | (Just w') =
    let (we, te) = rarc_5_6_5__state_inj da
    in let (inv', sh) = iret_19_1__emit_core p dom range r rule nr bound bd k v ea wm tables inv uniq w' af
    in let te' : (rarc_5_6_5__propagate p wm' tables = tables')
           te' = replace {p = \w => rarc_5_6_5__propagate p w tables = tables'} we te
    in replace {p = \t => (Lcyc_1_1__inv p dom (MkState wm' t), Either (wm' = wm, t = tables) (Rarc_5_6_7__action_shape rule bound (Emit k v) wm wm', t = rarc_5_6_5__propagate p wm' tables))} te'
         (replace {p = \w => (Lcyc_1_1__inv p dom (MkState w (rarc_5_6_5__propagate p w tables)), Either (w = wm, rarc_5_6_5__propagate p w tables = tables) (Rarc_5_6_7__action_shape rule bound (Emit k v) wm w, rarc_5_6_5__propagate p w tables = rarc_5_6_5__propagate p w tables))} we
            (inv', Right (sh, Refl)))
rarc_5_6_7__action_core p dom range r rule nr bound bk bd (Withdraw idx) ea wm tables inv uniq wm' tables' da with (rarc_5_6_5__nth idx bound) proof nb
  rarc_5_6_7__action_core p dom range r rule nr bound bk bd (Withdraw idx) ea wm tables inv uniq wm' tables' da | Nothing =
    rarc_5_6_7__action_noop p dom rule bound (Withdraw idx) wm tables inv wm' tables' da
  rarc_5_6_7__action_core p dom range r rule nr bound bk bd (Withdraw idx) ea wm tables inv uniq wm' tables' da | (Just f)
    with (lscp_2_1_1__withdraw_fact f wm) proof wf
    rarc_5_6_7__action_core p dom range r rule nr bound bk bd (Withdraw idx) ea wm tables inv uniq wm' tables' da | (Just f) | Nothing =
      rarc_5_6_7__action_noop p dom rule bound (Withdraw idx) wm tables inv wm' tables' da
    rarc_5_6_7__action_core p dom range r rule nr bound bk bd (Withdraw idx) ea wm tables inv uniq wm' tables' da | (Just f) | (Just w') =
      let (we, te) = rarc_5_6_5__state_inj da
      in let (sh, _) = lscp_2_1_1__withdraw_shape f wm w' wf
      in let te' : (rarc_5_6_5__propagate p wm' tables = tables')
             te' = replace {p = \w => rarc_5_6_5__propagate p w tables = tables'} we te
             inv' : Lcyc_1_1__inv p dom (MkState w' (rarc_5_6_5__propagate p w' tables))
             inv' = lcyc_1_1__propagate_inv p dom (MkState wm tables) inv w'
                      (replace {p = \w => All (\g => Elem (lfac_2_5_1__val g) dom) w} (sym sh)
                         (lcyc_1_1__all_filter (\g => not (lfac_2_5_4__same_fact g f)) wm (wmDom inv)))
             wk : (rarc_5_6_5__elem (fkind f) (lcyc_3_2_2__write_kinds rule) = True)
             wk = lcyc_1_1__elem_l_append_right (fkind f) (lcyc_3_2_2__emit_kinds rule) (lcyc_3_2_2__withdraw_kinds rule)
                    (lcyc_3_2_2__withdraw_kinds_has rule idx (fkind f) ea (iret_7_4__bound_kind bound (posKinds rule) bk idx f nb))
             shape : Rarc_5_6_7__action_shape rule bound (Withdraw idx) wm w'
             shape = replace {p = \w => Rarc_5_6_7__action_shape rule bound (Withdraw idx) wm w} (sym sh)
                       (MkActionShape (iret_4_4__keeps_filter wm uniq (\g => not (lfac_2_5_4__same_fact g f)))
                          (\g, eg => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h f)) wm eg)))
                          (iret_4_4__unique_filter wm uniq (\g => not (lfac_2_5_4__same_fact g f)))
                          (fkind f ** (wk, rarc_5_6_4__frame_remove f wm))
                          (\g, eg => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h f)) wm eg))))
         in replace {p = \t => (Lcyc_1_1__inv p dom (MkState wm' t), Either (wm' = wm, t = tables) (Rarc_5_6_7__action_shape rule bound (Withdraw idx) wm wm', t = rarc_5_6_5__propagate p wm' tables))} te'
              (replace {p = \w => (Lcyc_1_1__inv p dom (MkState w (rarc_5_6_5__propagate p w tables)), Either (w = wm, rarc_5_6_5__propagate p w tables = tables) (Rarc_5_6_7__action_shape rule bound (Withdraw idx) wm w, rarc_5_6_5__propagate p w tables = rarc_5_6_5__propagate p w tables))} we
                 (inv', Right (shape, Refl)))

-- ---------------------------------------------------------------------
-- The run invariant and the firing invariant
-- ---------------------------------------------------------------------

--@derives [IRET.12]
||| What holds of the engine state between actions of a run: the core
||| invariant, unique ids, every live row reads as a match, and every row
||| is live -- the cascade that ended the last action ran to its fixpoint.
public export
record Iret_12__run_inv (p : Lcyc_3_2_1__program) (dom : List (Nat, Nat)) (wm : Rarc_5_6_4__wm) (tables : List (List Iret_11__tok)) (rows : Iret_12_4__table) where
  constructor MkRunInv
  runCore  : Lcyc_1_1__inv p dom (MkState wm tables)
  runUniq  : Iret_4_4__unique wm
  runFacts : (row : Iret_12_4__row) -> Elem row rows -> iret_7_8__activation_live tables row = True -> Iret_12_4__row_facts p wm row
  runLive  : iret_12_2__ended (MkState wm tables) rows = []

--@derives [IRET.12]
||| The same, of a state.
public export
Iret_12__run_inv_s : Lcyc_3_2_1__program -> List (Nat, Nat) -> Iret_12__state -> Type
Iret_12__run_inv_s p dom s = Iret_12__run_inv p dom (wm (core s)) (toks (core s)) (deps s)

--@derives [IRET.12]
||| Within a firing, between its actions: the run invariant, and the
||| firing activation (rule `r`, identity `ids`) tracked.
public export
record Iret_12__fire_inv (p : Lcyc_3_2_1__program) (dom : List (Nat, Nat)) (r : Nat) (ids : List Nat)
                         (wm : Rarc_5_6_4__wm) (tables : List (List Iret_11__tok)) (rows : Iret_12_4__table) where
  constructor MkFireInv
  fireRun : Iret_12__run_inv p dom wm tables rows
  fireTok : Iret_7_8__tracked p wm tables (MkRow r ids 0)

--@derives [IRET.12]
||| Between actions every row is live with a live target.
export
iret_12__run_row_live : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                        Iret_12__run_inv p dom wm tables rows -> (row : Iret_12_4__row) -> Elem row rows ->
                        (iret_7_8__activation_live tables row = True, rarc_5_6_4__is_live (rtarget row) wm = True)
iret_12__run_row_live p dom wm tables rows rinv row e =
  let q : ((iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm) = True)
      q = lcyc_1_1__not_false_is_true _ (iret_12__filter_nil_all (\row => not (iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm)) rows (runLive rinv) row e)
  in (lcyc_1_1__and_true_l _ _ q, lcyc_1_1__and_true_r _ _ q)

--@derives [IRET.12.2]
||| An old row live before the action reads as a match in the new working
||| memory: its ids were all live, so no added fact carries one of them.
export
iret_12_2__entry_read_old : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            Iret_12__run_inv p dom wm tables rows -> (wm1 : Rarc_5_6_4__wm) -> Iret_4_4__keeps wm wm1 ->
                            ((g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)) ->
                            (row : Iret_12_4__row) -> Elem row rows -> iret_7_8__activation_live tables row = True -> Iret_12_4__row_facts p wm1 row
iret_12_2__entry_read_old p dom wm tables rows rinv wm1 keeps adds row e act =
  case runFacts rinv row e act of
    (r0 ** (fs0 ** (nr0, ids0, kinds0, gd0, liv0))) =>
      let al : (iret_12__all_in (rids row) (iret_11_3__fact_ids wm) = True)
          al = iret_7_8__live_activation_facts p dom (MkState wm tables) (runCore rinv) row r0 nr0 act
      in iret_12_4__row_facts_keeps p wm wm1 keeps row
           (\g, eg => case adds g eg of
              Left x => Left x
              Right nl => Right (iret_12__all_in_not_live (rids row) wm al (fid g) nl))
           (r0 ** (fs0 ** (nr0, ids0, kinds0, gd0, liv0)))

--@derives [IRET.12.2]
||| A live activation whose antecedents stay live is live after the
||| action's propagation, if there was one.
export
iret_12_2__entry_live_after : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) ->
                              Lcyc_1_1__inv p dom (MkState wm tables) -> (wm1 : Rarc_5_6_4__wm) -> (tables1 : List (List Iret_11__tok)) ->
                              Either (tables1 = tables) (tables1 = rarc_5_6_5__propagate p wm1 tables) ->
                              (row : Iret_12_4__row) -> Iret_12_4__row_facts p wm1 row -> iret_12__all_in (rids row) (iret_11_3__fact_ids wm1) = True ->
                              iret_7_8__activation_live tables row = True -> iret_7_8__activation_live tables1 row = True
iret_12_2__entry_live_after p pos dom wm tables inv wm1 tables1 (Left te) row rf al act =
  replace {p = \t => iret_7_8__activation_live t row = True} (sym te) act
iret_12_2__entry_live_after p pos dom wm tables inv wm1 tables1 (Right te) row rf al act =
  replace {p = \t => iret_7_8__activation_live t row = True} (sym te) (iret_7_8__live_after_propagate p pos dom (MkState wm tables) inv wm1 row rf al act)

--@derives [IRET.12.2]
||| A live activation after the action's propagation, if any, was live before.
export
iret_12_2__entry_live_before : (p : Lcyc_3_2_1__program) -> (wm1 : Rarc_5_6_4__wm) -> (tables, tables1 : List (List Iret_11__tok)) ->
                               Either (tables1 = tables) (tables1 = rarc_5_6_5__propagate p wm1 tables) ->
                               (row : Iret_12_4__row) -> iret_7_8__activation_live tables1 row = True -> iret_7_8__activation_live tables row = True
iret_12_2__entry_live_before p wm1 tables tables1 (Left te) row act = replace {p = \t => iret_7_8__activation_live t row = True} te act
iret_12_2__entry_live_before p wm1 tables tables1 (Right te) row act =
  iret_7_8__live_before_propagate p wm1 tables row (replace {p = \t => iret_7_8__activation_live t row = True} te act)

--@derives [IRET.12.2]
||| THE CASCADE ENTRY. After a core action and its record, from a state
||| satisfying the firing invariant, the bridge's premises hold: every
||| live row reads as a match, every row whose antecedents and target are
||| live is live, and the firing activation is still tracked.
export
iret_12_2__cascade_entry : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (r : Nat) -> (ids : List Nat) ->
                           (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> Iret_12__fire_inv p dom r ids wm tables rows ->
                           (wm1 : Rarc_5_6_4__wm) -> (tables1 : List (List Iret_11__tok)) -> Iret_4_4__keeps wm wm1 ->
                           ((g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False, rarc_5_6_5__elem (fid g) ids = False)) ->
                           Either (tables1 = tables) (tables1 = rarc_5_6_5__propagate p wm1 tables) ->
                           (rows1 : Iret_12_4__table) -> ((row : Iret_12_4__row) -> Elem row rows1 -> Either (Elem row rows) (t : Nat ** row = MkRow r ids t)) ->
                           ( (row : Iret_12_4__row) -> Elem row rows1 -> iret_7_8__activation_live tables1 row = True -> Iret_12_4__row_facts p wm1 row
                           , (row : Iret_12_4__row) -> Elem row rows1 -> iret_12__all_in (rids row) (iret_11_3__fact_ids wm1) = True ->
                               rarc_5_6_4__is_live (rtarget row) wm1 = True -> iret_7_8__activation_live tables1 row = True
                           , Iret_7_8__tracked p wm1 tables1 (MkRow r ids 0) )
iret_12_2__cascade_entry p pos dom r ids wm tables rows finv wm1 tables1 keeps adds te rows1 elemR =
  let (tokRead, tokLive) = fireTok finv
  in let adds' : (g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)
         adds' g eg = case adds g eg of
           Left x => Left x
           Right (nl, _) => Right nl
         addsTok : (g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g wm) (rarc_5_6_5__elem (fid g) ids = False)
         addsTok g eg = case adds g eg of
           Left x => Left x
           Right (_, nb) => Right nb
         readTok : Iret_12_4__row_facts p wm1 (MkRow r ids 0)
         readTok = iret_12_4__row_facts_keeps p wm wm1 keeps (MkRow r ids 0) addsTok tokRead
         liveTok : iret_12__all_in ids (iret_11_3__fact_ids wm1) = True -> iret_7_8__activation_live tables1 (MkRow r ids 0) = True
         liveTok al1 = iret_12_2__entry_live_after p pos dom wm tables (runCore (fireRun finv)) wm1 tables1 te (MkRow r ids 0) readTok al1
                         (tokLive (iret_12__all_in_back ids wm wm1 addsTok al1))
  in ( \row, e1, act1 => case elemR row e1 of
         Left e => iret_12_2__entry_read_old p dom wm tables rows (fireRun finv) wm1 keeps adds' row e (iret_12_2__entry_live_before p wm1 tables tables1 te row act1)
         Right (t ** eq) => replace {p = \x => Iret_12_4__row_facts p wm1 x} (sym eq) readTok
     , \row, e1, al1, tl1 => case elemR row e1 of
         Left e => let (act, tl) = iret_12__run_row_live p dom wm tables rows (fireRun finv) row e
                   in iret_12_2__entry_live_after p pos dom wm tables (runCore (fireRun finv)) wm1 tables1 te row
                        (iret_12_2__entry_read_old p dom wm tables rows (fireRun finv) wm1 keeps adds' row e act) al1 act
         Right (t ** eq) => replace {p = \x => iret_7_8__activation_live tables1 x = True} (sym eq)
                              (liveTok (replace {p = \x => iret_12__all_in (rids x) (iret_11_3__fact_ids wm1) = True} eq al1))
     , (readTok, liveTok) )

-- ---------------------------------------------------------------------
-- One action, one firing, one run
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
--@derives [RARC.5.6.7]
||| AT EVERY ACTION OF EVERY RUN, THE BRIDGE APPLIES. From a state
||| satisfying the firing invariant, one action with truth maintenance:
||| the core action gives (wm1, tables1), the record gives the table rows1,
||| and the cascade from there ends in a state whose live ids are exactly
||| Rete/Refcount.idr's cascade of rows1 over the ids live in wm1, with the
||| never-justified ones as base -- and the firing invariant holds again.
export
iret_12_2__action_cascade : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                            (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                            (tok : Iret_11__tok) -> lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok) ->
                            (a : Lgra_10_1__action) -> Elem a (actions rule) ->
                            (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm tables rows ->
                            (wm1 ** (tables1 ** (wmF ** (tablesF ** (rowsF **
                              ( rarc_5_6_7__do_action p (tfacts tok) a (MkState wm tables) = MkState wm1 tables1
                              , rarc_5_6_7__do_action_tms p r tok a (MkTms (MkState wm tables) rows) = MkTms (MkState wmF tablesF) rowsF
                              , Iret_12__sub (iret_11_3__fact_ids wmF)
                                  (iret_12_2__cascade (iret_12_2__base (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows) (iret_11_3__fact_ids wm1))
                                                      (iret_12_4__justifs (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows)) (iret_11_3__fact_ids wm1))
                              , Iret_12__sub (iret_12_2__cascade (iret_12_2__base (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows) (iret_11_3__fact_ids wm1))
                                                                 (iret_12_4__justifs (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows)) (iret_11_3__fact_ids wm1))
                                  (iret_11_3__fact_ids wmF)
                              , Iret_12__fire_inv p dom r (iret_11_3__ids tok) wmF tablesF rowsF ))))))
iret_12_2__action_cascade p pos dom range r rule nr tok bk bd a ea wm tables rows finv
  with (rarc_5_6_7__do_action p (tfacts tok) a (MkState wm tables)) proof da
  iret_12_2__action_cascade p pos dom range r rule nr tok bk bd a ea wm tables rows finv | (MkState wm1 tables1) =
    let (inv1, shape) = rarc_5_6_7__action_core p dom range r rule nr (tfacts tok) bk bd a ea wm tables (runCore (fireRun finv)) (runUniq (fireRun finv)) wm1 tables1 da
    in let uniq1 : Iret_4_4__unique wm1
           uniq1 = case shape of
             Left (we, _) => replace {p = \w => Iret_4_4__unique w} (sym we) (runUniq (fireRun finv))
             Right (sh, _) => shUniq sh
           keeps1 : Iret_4_4__keeps wm wm1
           keeps1 = case shape of
             Left (we, _) => replace {p = \w => Iret_4_4__keeps wm w} (sym we) (\f, e, _ => e)
             Right (sh, _) => shKeeps sh
           adds1 : (g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False, rarc_5_6_5__elem (fid g) (iret_11_3__ids tok) = False)
           adds1 = case shape of
             Left (we, _) => \g, eg => Left (replace {p = \w => Elem g w} we eg)
             Right (sh, _) => shAdds sh
           te1 : Either (tables1 = tables) (tables1 = rarc_5_6_5__propagate p wm1 tables)
           te1 = case shape of
             Left (_, te) => Left te
             Right (_, te) => Right te
    in let (rf1, rl1, tr1) = iret_12_2__cascade_entry p pos dom r (iret_11_3__ids tok) wm tables rows finv wm1 tables1 keeps1 adds1 te1
                               (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows)
                               (\row, e => case iret_10_2__record_elem p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows row e of
                                  Left e' => Left e'
                                  Right (f ** (_, eq, _)) => Right (fid f ** eq))
    in case iret_12_2__cascade_tracked p pos dom wm1 tables1 (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows) inv1 uniq1 rf1 rl1
              (MkRow r (iret_11_3__ids tok) 0) tr1 of
         (wmF ** (tablesF ** (rowsF ** (eq, invF, fixedF, trF)))) =>
           (wm1 ** (tables1 ** (wmF ** (tablesF ** (rowsF **
             ( Refl
             , eq
             , iret_12_2__cascade_greatest (iret_12_2__base (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows) (iret_11_3__fact_ids wm1))
                 (iret_12_4__justifs (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows)) (iret_11_3__fact_ids wm1) (iret_11_3__fact_ids wmF)
                 (liveSub invF)
                 (iret_12_2__fixed_post p dom (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows) (iret_11_3__fact_ids wm1) wmF tablesF rowsF invF fixedF)
             , gfpSub invF
             , MkFireInv (MkRunInv (coreInv invF) (uniq invF) (\row, e, act => rowFacts invF row (rowsSub invF row e) act) fixedF) trF ))))))

--@derives [RARC.5.6.7]
||| One more action at the front of an RHS, when the first is known.
export
rarc_5_6_7__actions_tms_succ : (p : Lcyc_3_2_1__program) -> (r : Nat) -> (tok : Iret_11__tok) -> (a : Lgra_10_1__action) -> (as : List Lgra_10_1__action) ->
                               (s : Iret_12__state) -> (st : Rarc_5_6_5__state) -> (rows : Iret_12_4__table) ->
                               rarc_5_6_7__do_action_tms p r tok a s = MkTms st rows ->
                               rarc_5_6_7__do_actions_tms p r tok (a :: as) s = rarc_5_6_7__do_actions_tms p r tok as (MkTms st rows)
rarc_5_6_7__actions_tms_succ p r tok a as s st rows eq with (rarc_5_6_7__do_action_tms p r tok a s)
  rarc_5_6_7__actions_tms_succ p r tok a as s st rows eq | (MkTms st' rows') = cong (rarc_5_6_7__do_actions_tms p r tok as) eq

--@derives [RARC.5.6.7]
||| The whole RHS keeps the firing invariant.
export
rarc_5_6_7__actions_tms_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                              (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                              (tok : Iret_11__tok) -> lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok) ->
                              (as : List Lgra_10_1__action) -> All (\a => Elem a (actions rule)) as ->
                              (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm tables rows ->
                              (wm' ** (tables' ** (rows' **
                                ( rarc_5_6_7__do_actions_tms p r tok as (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                                , Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm' tables' rows' ))))
rarc_5_6_7__actions_tms_inv p pos dom range r rule nr tok bk bd [] [] wm tables rows finv = (wm ** (tables ** (rows ** (Refl, finv))))
rarc_5_6_7__actions_tms_inv p pos dom range r rule nr tok bk bd (a :: as) (ea :: eas) wm tables rows finv =
  case iret_12_2__action_cascade p pos dom range r rule nr tok bk bd a ea wm tables rows finv of
    (wm1 ** (tables1 ** (wmF ** (tablesF ** (rowsF ** (_, eq, _, _, finvF)))))) =>
      case rarc_5_6_7__actions_tms_inv p pos dom range r rule nr tok bk bd as eas wmF tablesF rowsF finvF of
        (wm2 ** (tables2 ** (rows2 ** (eq2, finv2)))) =>
          (wm2 ** (tables2 ** (rows2 ** (trans (rarc_5_6_7__actions_tms_succ p r tok a as (MkTms (MkState wm tables) rows) (MkState wmF tablesF) rowsF eq) eq2, finv2))))

--@derives [IRET.11.4]
||| At the start of a firing, after the pop: the run invariant is kept and
||| the popped activation is tracked -- its reading from the settled
||| table, its liveness from the mark.
export
iret_11_4__fire_start : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                        (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> Iret_12__run_inv p dom wm tables rows ->
                        (r, j : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                        (ts : List Iret_11__tok) -> rarc_5_6_5__nth r tables = Just ts -> (tok : Iret_11__tok) -> rarc_5_6_5__nth j ts = Just tok ->
                        Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm (idat_6_2_2__mark_fired r j tables) rows
iret_11_4__fire_start p pos dom wm tables rows rinv r j rule nr ts nt tok njt =
  let stl : Iret_8_1__settled rule (iret_7_4__match_tuples rule wm) (iret_7_9__neg_facts rule wm) ts
      stl = settled (runCore rinv) r rule ts nr nt
      te : Elem tok ts
      te = lcyc_1_1__nth_elem j ts njt
  in let (_, inNow) = lcyc_1_1__all_lookup (fst stl) te
  in let (fs ** (efs, fsEq)) = lcyc_1_1__elem_map_inv iret_11_3__fact_ids (iret_7_4__match_tuples rule wm) (lcyc_1_1__elem_ll_elem _ _ inNow)
  in let (efs', gd) = lcyc_1_1__elem_filter_inv (guard rule) (iret_7_4__tuples (posKinds rule) wm) efs
  in let reading : Iret_12_4__row_facts p wm (MkRow r (iret_11_3__ids tok) 0)
         reading = (rule ** (fs ** (nr, fsEq, lcyc_1_1__all_lookup (iret_7_4__tuples_kinds (posKinds rule) wm) efs', gd,
                     lcyc_1_1__all_imp fs (\f, e, _ => e) (lcyc_1_1__all_lookup (iret_7_4__tuples_live (posKinds rule) wm) efs'))))
         unbl : (blocked tok = False)
         unbl = iret_8_1__settled_unblocked rule (pos r rule nr) (iret_7_4__match_tuples rule wm) (iret_7_9__neg_facts rule wm) ts stl tok te
         ntM : (rarc_5_6_5__nth r (rarc_5_6_5__set_at r (idat_6_2_2__mark_at j) tables) = Just (idat_6_2_2__mark_at j ts))
         ntM = trans (lcyc_1_1__nth_set_at_eq r (idat_6_2_2__mark_at j) tables) (cong (map (idat_6_2_2__mark_at j)) nt)
         inM : Elem (idat_6_2_2__mark_t tok) (idat_6_2_2__mark_at j ts)
         inM = lcyc_1_1__nth_elem j (idat_6_2_2__mark_at j ts) (trans (lcyc_1_1__nth_set_at_eq j idat_6_2_2__mark_t ts) (cong (map idat_6_2_2__mark_t) njt))
         live : (iret_7_8__activation_live (idat_6_2_2__mark_fired r j tables) (MkRow r (iret_11_3__ids tok) 0) = True)
         live = replace {p = \tbl => rarc_5_6_5__any (\u => (iret_11_3__ids u == iret_11_3__ids tok) && (fired u && not (blocked u))) tbl = True}
                        (sym (iret_11__table_at_nth r (rarc_5_6_5__set_at r (idat_6_2_2__mark_at j) tables) (idat_6_2_2__mark_at j ts) ntM))
                        (lcyc_1_1__any_elem (\u => (iret_11_3__ids u == iret_11_3__ids tok) && (fired u && not (blocked u))) (idat_6_2_2__mark_at j ts) inM
                           (iret_7_8__live_token_ok (MkRow r (iret_11_3__ids tok) 0) (idat_6_2_2__mark_t tok) Refl Refl unbl))
  in MkFireInv
       (MkRunInv (idat_6_2_2__pop_inv p dom (MkState wm tables) (runCore rinv) r j) (runUniq rinv)
          (\row, e, _ => runFacts rinv row e (fst (iret_12__run_row_live p dom wm tables rows rinv row e)))
          (lcyc_1_1__filter_all_false (\row => not (iret_7_8__activation_live (idat_6_2_2__mark_fired r j tables) row && rarc_5_6_4__is_live (rtarget row) wm)) rows
             (lcyc_1_1__all_from_elem rows (\row, e =>
                let (act, tl) = iret_12__run_row_live p dom wm tables rows rinv row e
                in iret_12__not_of_true _ (iret_12__and_both _ _ (idat_6_2_2__mark_keeps_live r j tables row act) tl)))))
       (reading, \_ => live)

--@derives [IRET.11.4]
||| One firing keeps the run invariant.
export
iret_11_4__step_tms_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                          (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> Iret_12__run_inv p dom wm tables rows ->
                          (s' : Iret_12__state) -> iret_11_4__step_tms p (MkTms (MkState wm tables) rows) = Just s' -> Iret_12__run_inv_s p dom s'
iret_11_4__step_tms_inv p pos dom range wm tables rows rinv s' eq with (ldet_5_1__select_next tables) proof sel
  iret_11_4__step_tms_inv p pos dom range wm tables rows rinv s' eq | Nothing = absurd eq
  iret_11_4__step_tms_inv p pos dom range wm tables rows rinv s' eq | (Just (r, j)) with (rarc_5_6_5__nth r (rules p)) proof nr
    iret_11_4__step_tms_inv p pos dom range wm tables rows rinv s' eq | (Just (r, j)) | Nothing = absurd eq
    iret_11_4__step_tms_inv p pos dom range wm tables rows rinv s' eq | (Just (r, j)) | (Just rule)
      with (rarc_5_6_5__nth j (iret_11__table_at r tables)) proof ntok
      iret_11_4__step_tms_inv p pos dom range wm tables rows rinv s' eq | (Just (r, j)) | (Just rule) | Nothing = absurd eq
      iret_11_4__step_tms_inv p pos dom range wm tables rows rinv s' eq | (Just (r, j)) | (Just rule) | (Just tok) =
        let (ts ** (t ** (nt, njt, _))) = ldet_5_1__select_next_pending tables r j sel
        in let njtok : (rarc_5_6_5__nth j ts = Just tok)
               njtok = replace {p = \tbl => rarc_5_6_5__nth j tbl = Just tok} (iret_11__table_at_nth r tables ts nt) ntok
               bk : (lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule)
               bk = fst (lcyc_1_1__all_lookup (tokOk (runCore rinv) r rule ts nr nt) (lcyc_1_1__nth_elem j ts njtok))
               bd : All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok)
               bd = snd (lcyc_1_1__all_lookup (tokOk (runCore rinv) r rule ts nr nt) (lcyc_1_1__nth_elem j ts njtok))
        in case rarc_5_6_7__actions_tms_inv p pos dom range r rule nr tok bk bd (actions rule) (lcyc_1_1__all_from_elem (actions rule) (\a, e => e))
                  wm (idat_6_2_2__mark_fired r j tables) rows (iret_11_4__fire_start p pos dom wm tables rows rinv r j rule nr ts nt tok njtok) of
             (wm' ** (tables' ** (rows' ** (eq', finv')))) =>
               replace {p = \s => Iret_12__run_inv_s p dom s} (trans (sym eq') (iret_11_4__just_inj eq)) (fireRun finv')

--@derives [IRET.11.4]
||| Every state of a run satisfies the run invariant.
export
iret_11_4__step_n_tms_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom -> (n : Nat) ->
                            (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> Iret_12__run_inv p dom wm tables rows ->
                            (s' : Iret_12__state) -> iret_11_4__step_n_tms p n (MkTms (MkState wm tables) rows) = Just s' -> Iret_12__run_inv_s p dom s'
iret_11_4__step_n_tms_inv p pos dom range Z wm tables rows rinv s' eq = replace {p = \s => Iret_12__run_inv_s p dom s} (iret_11_4__just_inj eq) rinv
iret_11_4__step_n_tms_inv p pos dom range (S n) wm tables rows rinv s' eq with (iret_11_4__step_tms p (MkTms (MkState wm tables) rows)) proof st
  iret_11_4__step_n_tms_inv p pos dom range (S n) wm tables rows rinv s' eq | Nothing = absurd eq
  iret_11_4__step_n_tms_inv p pos dom range (S n) wm tables rows rinv s' eq | (Just (MkTms (MkState wm1 tables1) rows1)) =
    iret_11_4__step_n_tms_inv p pos dom range n wm1 tables1 rows1 (iret_11_4__step_tms_inv p pos dom range wm tables rows rinv (MkTms (MkState wm1 tables1) rows1) st) s' eq

--@derives [RARC.5.6.5]
||| The initial state satisfies the run invariant: the core's initial
||| invariant, unique input ids, and an empty table.
export
rarc_5_6_5__init_tms_inv : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (wm0 : Rarc_5_6_4__wm) ->
                           Lcyc_1_1__inv p dom (rarc_5_6_5__init_state p wm0) -> Iret_4_4__unique wm0 -> Iret_12__run_inv_s p dom (rarc_5_6_5__init_tms p wm0)
rarc_5_6_5__init_tms_inv p dom wm0 inv uniq = MkRunInv inv uniq (\row, e, _ => absurd e) Refl

--@derives [IRET.12]
||| THE RUN INVARIANT HOLDS. From an invariant-satisfying start with unique
||| ids, every state a run reaches satisfies it; so at every action of
||| every firing `iret_12_2__action_cascade` applies, and the live facts
||| after the action are Rete/Refcount.idr's cascade of the table.
export
iret_12__run_inv_holds : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                         (wm0 : Rarc_5_6_4__wm) -> Lcyc_1_1__inv p dom (rarc_5_6_5__init_state p wm0) -> Iret_4_4__unique wm0 ->
                         (n : Nat) -> (s' : Iret_12__state) -> iret_11_4__step_n_tms p n (rarc_5_6_5__init_tms p wm0) = Just s' -> Iret_12__run_inv_s p dom s'
iret_12__run_inv_holds p pos dom range wm0 inv uniq n s' eq =
  iret_11_4__step_n_tms_inv p pos dom range n wm0 (rarc_5_6_5__propagate p wm0 (map (const []) (rules p))) [] (rarc_5_6_5__init_tms_inv p dom wm0 inv uniq) s' eq

--@derives [IRET.12]
--@derives [LCYC.3.1.1]
||| And for a certified program on any input with unique ids, with the
||| certificate's domain: the core's initial invariant and its range.
export
iret_12__run_inv_certified : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (c : Lcyc_3_1_1__certified p) -> (wm0 : Rarc_5_6_4__wm) -> Iret_4_4__unique wm0 ->
                             (n : Nat) -> (s' : Iret_12__state) -> iret_11_4__step_n_tms p n (rarc_5_6_5__init_tms p wm0) = Just s' ->
                             Iret_12__run_inv_s p (lcyc_1_1__dom_of c wm0) s'
iret_12__run_inv_certified p pos c wm0 uniq n s' eq =
  iret_12__run_inv_holds p pos (lcyc_1_1__dom_of c wm0)
    (lcyc_3_1_1__range_widen p (lits c) (lcyc_1_1__dom_of c wm0) (\x, e => lcyc_1_1__elem_append_left e) (range c))
    wm0 (lcyc_1_1__init_inv p c wm0) uniq n s' eq

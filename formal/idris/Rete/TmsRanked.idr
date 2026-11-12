-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The certificate gives acyclic support: on a program certified as
||| [LCYC.3.1.1] admits it, the dependency table of Rete/FireLoopTms.idr's
||| engine is ranked at every state the run invariant covers, so the
||| justification count leaves live exactly the facts [LLOG.2.5] keeps.
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr.
||| [IRET.12.2] states the well-founded obligation of [LLOG.2.5] and keeps
||| the justification count as libds's mechanism: "on every program
||| [LCYC.3.1.1] admits, support is acyclic ... so a count of live
||| justifications decides it". Rete/Refcount.idr proves the count exact on
||| a ranked support graph, for any graph (`iret_12_3__ranked_agree`), and
||| Rete/PumpBoundary.idr carries that to the engine's own table, for any
||| ranking of it (`iret_12_3__boundary_ranked`). This module supplies the
||| ranking, which is the clause's sentence on the engine, and composes the
||| two.
|||
||| THE RANKING. A kind's level is one more than the highest stratum of a
||| rule that emits it, zero for a kind no rule emits
||| (`iret_12_3__level_from`). A fact ranks at its kind's level, and an id
||| no live fact carries ranks zero (`iret_12_3__rank`).
|||
||| WHAT IS PROVED, at a state satisfying Rete/TmsRun.idr's run invariant
||| and Lcyc/TmsTermination.idr's target kinds:
|||
|||   * every antecedent of every row ranks strictly below the row's target
|||     (`iret_12_3__certified_ranked`). The target is a live fact of a kind
|||     the row's rule emits, so it ranks above that rule's stratum; an
|||     antecedent is dead and ranks zero, or is a fact the rule read, whose
|||     every emitter sits in a strictly lower stratum
|||     (`lcyc_3_1_1__emit_below_read`: no lower by edge monotonicity, and
|||     not the same, since no stratum reads what it emits);
|||   * so the live facts are exactly the well-founded set of the table over
|||     them (`iret_12_2__certified_exact`): the count and [LLOG.2.5] agree
|||     there, and no certified program reaches the difference between
|||     them.
|||
||| RELIES ON, and does not establish: that the states of a run satisfy the
||| two invariants. Rete/PumpBoundary.idr proves that a pump and a canonical
||| replay of a positive certified program keep both from a state that has
||| them (`iret_11_4__pump_inv`, `lfst_9_2_1__canonical_inv`).
|||
||| SCOPE. The certificate is kind-level: a program [LCYC.3.1.1] admits
||| only through [LCYC.6.1]'s literal break has none, and these theorems are
||| silent on it (Lcyc/Certificate.idr's header says why). Of a support
||| cycle they say nothing: Rete/Refcount.idr's witnesses and
||| formal/tla/tms_cascade.tla's cycle graph draw one, where the count
||| keeps what the obligation retracts.
module Rete.TmsRanked

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
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat

%default total

-- ---------------------------------------------------------------------
-- The table read as justifications
-- ---------------------------------------------------------------------

--@derives [IRET.12.4]
||| A justification read off the table is a row's.
export
iret_12_4__row_justif : (rows : Iret_12_4__table) -> (j : Iret_12_1__justif) -> Elem j (iret_12_4__justifs rows) ->
                        (row ** (Elem row rows, ante j = rids row, target j = rtarget row))
iret_12_4__row_justif rows j e =
  case lcyc_1_1__elem_map_inv (\row => MkJustif (rids row) (rtarget row)) rows e of
    (row ** (er, eq)) => (row ** (er, rewrite sym eq in Refl, rewrite sym eq in Refl))

-- ---------------------------------------------------------------------
-- A kind's level, and a fact's rank
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

-- ---------------------------------------------------------------------
-- The certificate ranks the table
-- ---------------------------------------------------------------------

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

-- ---------------------------------------------------------------------
-- So the count is exact
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| ON A CERTIFIED PROGRAM THE COUNT DECIDES IT. At a state with the run
||| invariant and the target kinds, the live facts are exactly the
||| well-founded set of the engine's own table over them: every live fact
||| is one no row targets or has a justification grounded in such facts,
||| and every fact of that set is live. The ranking above is the one
||| Rete/PumpBoundary.idr's `iret_12_3__boundary_ranked` asks for, so the
||| clause's "support is acyclic ... so a count of live justifications
||| decides it" is one statement here.
export
iret_12_2__certified_exact : (p : Lcyc_3_2_1__program) -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                             (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                             ( Iret_12__sub (iret_11_3__fact_ids wm) (llog_2_5__well_founded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
                             , Iret_12__sub (llog_2_5__well_founded (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm)) (iret_11_3__fact_ids wm) )
iret_12_2__certified_exact p ct dom wm tables rows rinv rk =
  iret_12_3__boundary_ranked (\i => iret_12_3__rank (tmsStrata ct) (rules p) wm i) p dom wm tables rows rinv
    (iret_12_3__certified_ranked p ct dom wm tables rows rinv rk)

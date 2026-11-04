-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE TERMINATION THEOREM: a certified program (Lcyc/Certificate.idr)
||| quiesces from every input, on the deterministic engine of
||| Rete.FireLoop. One firing strictly lowers the lexicographic
||| measure and preserves the invariant; the measure is well-founded.
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr.
||| The theorem and its measure lemmas derive [LCYC.1.1]; the stratum lemmas
||| derive [LCYC.3.1]; the per-action lemmas derive the clause of the action
||| they are about ([IRET.19.1] assert, [LSCP.2.1.1] withdraw, [RARC.5.6.7]
||| dispatch, [IDAT.6.2.2] the fired flag). The three lemmas that read the
||| certificate's fields (`lcyc_3_1_1__emitted_not_withdrawn`,
||| `lcyc_3_1_1__range_widen`, `lcyc_3_1_1__emit_in_dom`) derive
||| [LCYC.3.1.1] with it. The certificate is wider than that clause (it
||| admits the recursive exception the clause refuses), so
||| `emitted_not_withdrawn` is vacuous for every program the clause admits and its tie is `partial`, as `cert_emit`'s is.
|||
||| WHAT THIS FILE RELIES ON BUT DOES NOT ESTABLISH. The certificate's six
||| fields (Lcyc/Certificate.idr): `edgeMono` and `inRange` for the
||| strata, `certEmit` and `range` for the emits. The well-foundedness of
||| the lexicographic order, `lcyc_1_1__lex_acc` (same file). That the
||| stratification is the compiler's rule graph is argued, not proved
||| anywhere in the lane -- and it is not, where [LCYC.6.1]'s literal
||| break has dropped an edge the kind-level certificate keeps: a program
||| admitted only by the break has no certificate and this theorem does
||| not reach it (Lcyc/Certificate.idr's header).
module Lcyc.Termination

import Rete.FireLoop
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Certificate
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality
import Control.WellFounded

%default total

-- ---------------------------------------------------------------------
-- Small arithmetic
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
||| LT a b, c = d  ⇒  LT (a + c) (b + d)
export
lcyc_1_1__lt_plus_right : {a, b, c, d : Nat} -> LT a b -> c = d -> LT (a + c) (b + d)
lcyc_1_1__lt_plus_right {c} lt Refl = plusLteMonotone lt (reflexive {x = c})

--@derives [LCYC.1.1]
||| a = b, LT c d  ⇒  LT (a + c) (b + d)
export
lcyc_1_1__lt_plus_left : {a, b, c, d : Nat} -> a = b -> LT c d -> LT (a + c) (b + d)
lcyc_1_1__lt_plus_left {a} {c} Refl lt = rewrite plusSuccRightSucc a c in plusLteMonotone (reflexive {x = a}) lt

-- ---------------------------------------------------------------------
-- Indices, strata and their kind sets
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__indexed_from_nth : (n, i : Nat) -> (xs : List a) -> rarc_5_6_5__nth i xs = Just x -> Elem (n + i, x) (lcyc_1_1__indexed_from n xs)
lcyc_1_1__indexed_from_nth n Z (x :: xs) Refl = rewrite plusZeroRightNeutral n in Here
lcyc_1_1__indexed_from_nth n (S i) (y :: xs) prf =
  rewrite sym (plusSuccRightSucc n i) in There (lcyc_1_1__indexed_from_nth (S n) i xs prf)

--@derives [LCYC.1.1]
export
lcyc_1_1__indexed_from_elem : (n : Nat) -> (xs : List a) -> Elem (i, x) (lcyc_1_1__indexed_from n xs) ->
                  (d ** (i = n + d, rarc_5_6_5__nth d xs = Just x))
lcyc_1_1__indexed_from_elem n [] e = absurd e
lcyc_1_1__indexed_from_elem n (y :: xs) Here = (Z ** (sym (plusZeroRightNeutral n), Refl))
lcyc_1_1__indexed_from_elem n (y :: xs) (There e) =
  let (d ** (eq, nd)) = lcyc_1_1__indexed_from_elem (S n) xs e
  in (S d ** (trans eq (plusSuccRightSucc n d), nd))

--@derives [LCYC.3.1]
export
lcyc_3_1__rules_in_elem : (s : Lcyc_3_1__strata) -> (rs : List Lgra_6_1__rule) -> (i, ri : Nat) -> (r : Lgra_6_1__rule) ->
              rarc_5_6_5__nth ri rs = Just r -> strat s ri = i -> Elem r (lcyc_3_1__rules_in s i rs)
lcyc_3_1__rules_in_elem s rs i ri r prf eq =
  lcyc_1_1__elem_map_fwd snd (lcyc_1_1__elem_filter_fwd (\ir => strat s (fst ir) == i) (lcyc_1_1__indexed_from 0 rs)
                    (lcyc_1_1__indexed_from_nth 0 ri rs prf) (rewrite eq in lcyc_1_1__nat_eq_refl i))

--@derives [LCYC.3.1]
export
lcyc_3_1__rules_in_index : (s : Lcyc_3_1__strata) -> (rs : List Lgra_6_1__rule) -> (i : Nat) -> (r : Lgra_6_1__rule) -> Elem r (lcyc_3_1__rules_in s i rs) ->
               (ri ** (rarc_5_6_5__nth ri rs = Just r, strat s ri = i))
lcyc_3_1__rules_in_index s rs i r e =
  let ((ri, r') ** (ef, eqr)) = lcyc_1_1__elem_map_inv snd (filter (\ir => strat s (fst ir) == i) (lcyc_1_1__indexed_from 0 rs)) e
      (ei, pr) = lcyc_1_1__elem_filter_inv (\ir => strat s (fst ir) == i) (lcyc_1_1__indexed_from 0 rs) ef
      (d ** (eqd, nd)) = lcyc_1_1__indexed_from_elem 0 rs ei
  in (ri ** (rewrite eqd in rewrite sym eqr in nd, lcyc_1_1__nat_eq_true (strat s ri) i pr))

--@derives [LCYC.3.1]
export
lcyc_3_1__indices_in_has : (s : Lcyc_3_1__strata) -> (rs : List Lgra_6_1__rule) -> (i, ri : Nat) -> (r : Lgra_6_1__rule) ->
               rarc_5_6_5__nth ri rs = Just r -> strat s ri = i -> Elem ri (lcyc_3_1__indices_in s i rs)
lcyc_3_1__indices_in_has s rs i ri r prf eq =
  lcyc_1_1__elem_map_fwd fst (lcyc_1_1__elem_filter_fwd (\ir => strat s (fst ir) == i) (lcyc_1_1__indexed_from 0 rs)
                    (lcyc_1_1__indexed_from_nth 0 ri rs prf) (rewrite eq in lcyc_1_1__nat_eq_refl i))

--@derives [LCYC.3.1]
export
lcyc_3_1__indices_in_elem : (s : Lcyc_3_1__strata) -> (rs : List Lgra_6_1__rule) -> (i, ri : Nat) -> Elem ri (lcyc_3_1__indices_in s i rs) ->
                (r ** (rarc_5_6_5__nth ri rs = Just r, strat s ri = i))
lcyc_3_1__indices_in_elem s rs i ri e =
  let ((ri', r) ** (ef, eqi)) = lcyc_1_1__elem_map_inv fst (filter (\ir => strat s (fst ir) == i) (lcyc_1_1__indexed_from 0 rs)) e
      (ei, pr) = lcyc_1_1__elem_filter_inv (\ir => strat s (fst ir) == i) (lcyc_1_1__indexed_from 0 rs) ef
      (d ** (eqd, nd)) = lcyc_1_1__indexed_from_elem 0 rs ei
  in (r ** (rewrite sym eqi in rewrite eqd in nd, rewrite sym eqi in lcyc_1_1__nat_eq_true (strat s ri') i pr))

--@derives [LCYC.1.1]
export
lcyc_1_1__map_maybe_elem_fwd : (g : a -> Maybe b) -> (xs : List a) -> Elem x xs -> g x = Just y -> Elem y (mapMaybe g xs)
lcyc_1_1__map_maybe_elem_fwd g (x :: xs) Here gx = rewrite gx in Here
lcyc_1_1__map_maybe_elem_fwd g (z :: xs) (There e) gx with (g z)
  lcyc_1_1__map_maybe_elem_fwd g (z :: xs) (There e) gx | Nothing = lcyc_1_1__map_maybe_elem_fwd g xs e gx
  lcyc_1_1__map_maybe_elem_fwd g (z :: xs) (There e) gx | (Just _) = There (lcyc_1_1__map_maybe_elem_fwd g xs e gx)

--@derives [LCYC.1.1]
export
lcyc_1_1__map_maybe_elem_inv : (g : a -> Maybe b) -> (xs : List a) -> Elem y (mapMaybe g xs) -> (x ** (Elem x xs, g x = Just y))
lcyc_1_1__map_maybe_elem_inv g [] e = absurd e
lcyc_1_1__map_maybe_elem_inv g (x :: xs) e with (g x) proof gx
  lcyc_1_1__map_maybe_elem_inv g (x :: xs) e | Nothing =
    let (x' ** (e', gx')) = lcyc_1_1__map_maybe_elem_inv g xs e in (x' ** (There e', gx'))
  lcyc_1_1__map_maybe_elem_inv g (x :: xs) Here | (Just z) = (x ** (Here, gx))
  lcyc_1_1__map_maybe_elem_inv g (x :: xs) (There e) | (Just z) =
    let (x' ** (e', gx')) = lcyc_1_1__map_maybe_elem_inv g xs e in (x' ** (There e', gx'))

--@derives [LCYC.3.2.2]
export
lcyc_3_2_2__emit_kinds_has : (r : Lgra_6_1__rule) -> (k : Nat) -> (v : List Lfac_1_7_1__fact -> (Nat, Nat)) -> Elem (Emit k v) (actions r) ->
               rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r) = True
lcyc_3_2_2__emit_kinds_has r k v e = lcyc_1_1__elem_l_true k (lcyc_3_2_2__emit_kinds r) (lcyc_1_1__map_maybe_elem_fwd lcyc_3_2_2__emit_kind_of (actions r) e Refl)

--@derives [LCYC.3.2.2]
export
lcyc_3_2_2__withdraw_kinds_has : (r : Lgra_6_1__rule) -> (i, k : Nat) -> Elem (Withdraw i) (actions r) -> rarc_5_6_5__nth i (posKinds r) = Just k ->
                   rarc_5_6_5__elem k (lcyc_3_2_2__withdraw_kinds r) = True
lcyc_3_2_2__withdraw_kinds_has r i k e nk = lcyc_1_1__elem_l_true k (lcyc_3_2_2__withdraw_kinds r) (lcyc_1_1__map_maybe_elem_fwd (lcyc_3_2_2__withdraw_kind_of r) (actions r) e nk)

--@derives [LCYC.3.2.2]
||| A withdrawn kind is matched positively, hence read.
export
lcyc_3_2_2__withdraw_sub_pos : (r : Lgra_6_1__rule) -> (k : Nat) -> rarc_5_6_5__elem k (lcyc_3_2_2__withdraw_kinds r) = True -> Elem k (posKinds r)
lcyc_3_2_2__withdraw_sub_pos r k prf with (lcyc_1_1__map_maybe_elem_inv (lcyc_3_2_2__withdraw_kind_of r) (actions r) (lcyc_1_1__elem_l_elem k (lcyc_3_2_2__withdraw_kinds r) prf))
  lcyc_3_2_2__withdraw_sub_pos r k prf | ((Withdraw i) ** (_, gx)) = lcyc_1_1__nth_elem i (posKinds r) gx
  lcyc_3_2_2__withdraw_sub_pos r k prf | ((Emit _ _) ** (_, gx)) = absurd gx

--@derives [LCYC.3.1]
export
lcyc_3_1__withdraw_of_sub_read : (s : Lcyc_3_1__strata) -> (rs : List Lgra_6_1__rule) -> (i, k : Nat) ->
                    rarc_5_6_5__elem k (lcyc_3_1__withdraw_kinds_of s i rs) = True -> rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s i rs) = True
lcyc_3_1__withdraw_of_sub_read s rs i k prf =
  let (r ** (e, pk)) = lcyc_1_1__elem_concat_map_inv lcyc_3_2_2__withdraw_kinds (lcyc_3_1__rules_in s i rs) k prf
  in lcyc_1_1__elem_concat_map lcyc_3_2_2__read_kinds (lcyc_3_1__rules_in s i rs) e k
       (lcyc_1_1__elem_l_append_left k (posKinds r) (iret_7_9__neg_kinds r) (lcyc_1_1__elem_l_true k (posKinds r) (lcyc_3_2_2__withdraw_sub_pos r k pk)))

--@derives [LCYC.3.1]
||| A rule in stratum j < i never reads a kind a rule of stratum i writes.
export
lcyc_3_1__not_read_below : (s : Lcyc_3_1__strata) -> (rs : List Lgra_6_1__rule) -> Lcyc_3_1__edge_mono s rs ->
               (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri rs = Just r -> (k : Nat) -> rarc_5_6_5__elem k (lcyc_3_2_2__write_kinds r) = True ->
               (rj : Nat) -> (q : Lgra_6_1__rule) -> rarc_5_6_5__nth rj rs = Just q -> LT (strat s rj) (strat s ri) ->
               rarc_5_6_5__elem k (lcyc_3_2_2__read_kinds q) = False
lcyc_3_1__not_read_below s rs mono ri r nr k wk rj q nq lt with (rarc_5_6_5__elem k (lcyc_3_2_2__read_kinds q)) proof e
  lcyc_3_1__not_read_below s rs mono ri r nr k wk rj q nq lt | True =
    absurd (succNotLTEpred (transitive lt (mono ri rj r q nr nq k wk e)))
  lcyc_3_1__not_read_below s rs mono ri r nr k wk rj q nq lt | False = Refl

--@derives [LCYC.3.1]
||| A rule of stratum i does not read a kind the stratum as a whole does not read.
export
lcyc_3_1__not_read_same : (s : Lcyc_3_1__strata) -> (rs : List Lgra_6_1__rule) -> (i, k : Nat) -> rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s i rs) = False ->
              (rj : Nat) -> (q : Lgra_6_1__rule) -> rarc_5_6_5__nth rj rs = Just q -> strat s rj = i -> rarc_5_6_5__elem k (lcyc_3_2_2__read_kinds q) = False
lcyc_3_1__not_read_same s rs i k prf rj q nq eq with (rarc_5_6_5__elem k (lcyc_3_2_2__read_kinds q)) proof e
  lcyc_3_1__not_read_same s rs i k prf rj q nq eq | True =
    absurd (trans (sym (lcyc_1_1__elem_concat_map lcyc_3_2_2__read_kinds (lcyc_3_1__rules_in s i rs) (lcyc_3_1__rules_in_elem s rs i rj q nq eq) k e)) prf)
  lcyc_3_1__not_read_same s rs i k prf rj q nq eq | False = Refl

--@derives [LCYC.3.1]
||| No stratum below the writer's reads what it writes.
export
lcyc_3_1__stratum_below_not_read : (s : Lcyc_3_1__strata) -> (rs : List Lgra_6_1__rule) -> Lcyc_3_1__edge_mono s rs ->
                      (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri rs = Just r -> (k : Nat) -> rarc_5_6_5__elem k (lcyc_3_2_2__write_kinds r) = True ->
                      (j : Nat) -> LT j (strat s ri) -> rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s j rs) = False
lcyc_3_1__stratum_below_not_read s rs mono ri r nr k wk j lt with (rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s j rs)) proof e
  lcyc_3_1__stratum_below_not_read s rs mono ri r nr k wk j lt | True =
    let (q ** (eq, rq)) = lcyc_1_1__elem_concat_map_inv lcyc_3_2_2__read_kinds (lcyc_3_1__rules_in s j rs) k e
        (rj ** (nq, sj)) = lcyc_3_1__rules_in_index s rs j q eq
    in absurd (trans (sym rq) (lcyc_3_1__not_read_below s rs mono ri r nr k wk rj q nq (rewrite sj in lt)))
  lcyc_3_1__stratum_below_not_read s rs mono ri r nr k wk j lt | False = Refl

-- ---------------------------------------------------------------------
-- comp2 under a frame-respecting change and under the pop
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.5]
||| After a WM change of kind k, a rule that does not read k keeps its
||| table (frame + settledness).
export
rarc_5_6_5__table_frame : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (st : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom st ->
             (k : Nat) -> (w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k (wm st) w' ->
             (ri : Nat) -> ((q : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just q -> rarc_5_6_5__elem k (lcyc_3_2_2__read_kinds q) = False) ->
             rarc_5_6_5__nth ri (rarc_5_6_5__propagate p w' (toks st)) = rarc_5_6_5__nth ri (toks st)
rarc_5_6_5__table_frame p dom st inv k w' fr ri notRead with (rarc_5_6_5__nth ri (toks st)) proof nt
  rarc_5_6_5__table_frame p dom st inv k w' fr ri notRead | Nothing =
    lcyc_1_1__nth_zip_with_nothing_r (\r, ts => rarc_5_6_5__prop_rule r w' ts) ri (rules p) (toks st) nt
  rarc_5_6_5__table_frame p dom st inv k w' fr ri notRead | (Just ts) =
    let (q ** nq) = lcyc_1_1__nth_length ri (rules p) (toks st) (tokLen inv) nt
    in rewrite lcyc_1_1__nth_zip_with_just (\r, ts => rarc_5_6_5__prop_rule r w' ts) ri (rules p) (toks st) nq nt in
       rewrite rarc_5_6_5__prop_rule_frame k (wm st) w' fr q (notRead q nq) ts in
       cong Just (iret_8_1__settled_fixed q (iret_7_4__match_tuples q (wm st)) (iret_7_9__neg_facts q (wm st)) ts (settled inv ri q ts nq nt))

--@derives [LCYC.1.1]
export
lcyc_1_1__comp2_ext : (s : Lcyc_3_1__strata) -> (i : Nat) -> (rs : List Lgra_6_1__rule) -> (t, t' : List (List Iret_11__tok)) ->
           ((ri : Nat) -> Elem ri (lcyc_3_1__indices_in s i rs) -> rarc_5_6_5__nth ri t' = rarc_5_6_5__nth ri t) ->
           lcyc_1_1__comp2 s i rs t' = lcyc_1_1__comp2 s i rs t
lcyc_1_1__comp2_ext s i rs t t' same =
  lcyc_1_1__sum_by_ext (\ri => iret_11_3_1__pending_count (iret_11__table_at ri t')) (\ri => iret_11_3_1__pending_count (iret_11__table_at ri t)) (lcyc_3_1__indices_in s i rs)
    (lcyc_1_1__all_from_elem (lcyc_3_1__indices_in s i rs) (\ri, e => cong (\m => iret_11_3_1__pending_count (iret_11__from_maybe m)) (same ri e)))

--@derives [LCYC.1.1]
||| A change to a kind the stratum does not read leaves its comp2 alone.
export
lcyc_1_1__comp2_frame : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (st : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom st ->
             (s : Lcyc_3_1__strata) -> (k : Nat) -> (w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k (wm st) w' -> (j : Nat) ->
             rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s j (rules p)) = False ->
             lcyc_1_1__comp2 s j (rules p) (rarc_5_6_5__propagate p w' (toks st)) = lcyc_1_1__comp2 s j (rules p) (toks st)
lcyc_1_1__comp2_frame p dom st inv s k w' fr j notReadJ =
  lcyc_1_1__comp2_ext s j (rules p) (toks st) (rarc_5_6_5__propagate p w' (toks st))
    (\rj, e => let (q ** (nq, eq)) = lcyc_3_1__indices_in_elem s (rules p) j rj e
               in rarc_5_6_5__table_frame p dom st inv k w' fr rj
                    (\q', nq' => rewrite lcyc_1_1__just_injective (trans (sym nq') nq) in
                                 lcyc_3_1__not_read_same s (rules p) j k notReadJ rj q nq eq))

-- ---------------------------------------------------------------------
-- comp1 under a frame-respecting change, a withdraw, and a relation emit
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
||| Every kind the stratum's measure mentions is one the stratum reads.
export
lcyc_1_1__comp1_frame : (p : Lcyc_3_2_1__program) -> (s : Lcyc_3_1__strata) -> (dom : List (Nat, Nat)) -> (j : Nat) ->
             (k : Nat) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k w w' -> rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s j (rules p)) = False ->
             lcyc_1_1__comp1 p s dom j w' = lcyc_1_1__comp1 p s dom j w
lcyc_1_1__comp1_frame p s dom j k w w' fr notRead =
  cong2 (+)
    (lcyc_1_1__sum_by_ext (\k' => lcyc_1_1__headroom k' dom w') (\k' => lcyc_1_1__headroom k' dom w)
       (filter (\k' => rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of s j (rules p))) (lcyc_3_1__emit_kinds_of s j (rules p)))
       (lcyc_1_1__all_from_elem _ (\k', e => lcyc_1_1__headroom_frame k w w' fr k'
           (neqRead k' (snd (lcyc_1_1__elem_filter_inv (\k' => rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of s j (rules p))) _ e))) dom)))
    (lcyc_1_1__sum_by_ext (\k' => rarc_5_6_4__count_kind k' w') (\k' => rarc_5_6_4__count_kind k' w) (lcyc_3_1__withdraw_kinds_of s j (rules p))
       (lcyc_1_1__all_from_elem _ (\k', e => rarc_5_6_4__count_frame k w w' fr k'
           (neqRead k' (lcyc_3_1__withdraw_of_sub_read s (rules p) j k' (lcyc_1_1__elem_l_true k' _ e))))))
  where
    neqRead : (k' : Nat) -> rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of s j (rules p)) = True -> Not (k' = k)
    neqRead k' rd eq = lcyc_1_1__bool_not_both (rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s j (rules p))) (rewrite sym eq in rd) notRead

--@derives [LCYC.1.1]
export
lcyc_1_1__headroom_append_lte : (k : Nat) -> (dom : List (Nat, Nat)) -> (w : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) ->
                    LTE (lcyc_1_1__headroom k dom (w ++ [f])) (lcyc_1_1__headroom k dom w)
lcyc_1_1__headroom_append_lte k dom w f =
  lcyc_1_1__filter_lte (\d => not (lfac_2_5_1__live_val k d w)) (\d => not (lfac_2_5_1__live_val k d (w ++ [f]))) imp dom
  where
    imp : (d : (Nat, Nat)) -> not (lfac_2_5_1__live_val k d (w ++ [f])) = True -> not (lfac_2_5_1__live_val k d w) = True
    imp d prf with (lfac_2_5_1__live_val k d w) proof lv
      imp d prf | True = absurd (trans (sym prf) (rewrite lfac_2_5_1__live_val_append_mono k d w f lv in Refl))
      imp d prf | False = Refl

--@derives [LCYC.1.1]
||| The headroom sum over a stratum's emitted-and-read kinds never grows on an append.
export
lcyc_1_1__headroom_sum_append_lte : (p : Lcyc_3_2_1__program) -> (s : Lcyc_3_1__strata) -> (dom : List (Nat, Nat)) -> (i : Nat) ->
                       (w : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) ->
                       All (\k' => LTE (lcyc_1_1__headroom k' dom (w ++ [f])) (lcyc_1_1__headroom k' dom w))
                           (filter (\k' => rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of s i (rules p))) (lcyc_3_1__emit_kinds_of s i (rules p)))
lcyc_1_1__headroom_sum_append_lte p s dom i w f = lcyc_1_1__all_from_elem _ (\k', _ => lcyc_1_1__headroom_append_lte k' dom w f)

--@derives [LCYC.1.1]
||| A relation emit of a kind the stratum reads strictly lowers comp1.
export
lcyc_1_1__comp1_emit_lt : (p : Lcyc_3_2_1__program) -> (c : Lcyc_3_1_1__certified p) -> (dom : List (Nat, Nat)) ->
              (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just r ->
              (f : Lfac_1_7_1__fact) -> rarc_5_6_5__elem (fkind f) (lcyc_3_2_2__emit_kinds r) = True ->
              rarc_5_6_5__elem (fkind f) (lcyc_3_1__read_kinds_of (strata c) (strat (strata c) ri) (rules p)) = True ->
              (w : Rarc_5_6_4__wm) -> lfac_2_5_1__live_val (fkind f) (lfac_2_5_1__val f) w = False -> Elem (lfac_2_5_1__val f) dom ->
              LT (lcyc_1_1__comp1 p (strata c) dom (strat (strata c) ri) (w ++ [f]))
                 (lcyc_1_1__comp1 p (strata c) dom (strat (strata c) ri) w)
lcyc_1_1__comp1_emit_lt p c dom ri r nr f ek rk w notLive inDom =
  lcyc_1_1__lt_plus_right
    (lcyc_1_1__sum_by_strict (\k' => lcyc_1_1__headroom k' dom w) (\k' => lcyc_1_1__headroom k' dom (w ++ [f])) _
       (lcyc_1_1__headroom_sum_append_lte p (strata c) dom (strat (strata c) ri) w f)
       (fkind f) kInList (lcyc_1_1__headroom_insert_lt dom w f notLive inDom))
    (lcyc_1_1__sum_by_ext (\k' => rarc_5_6_4__count_kind k' (w ++ [f])) (\k' => rarc_5_6_4__count_kind k' w) (lcyc_3_1__withdraw_kinds_of (strata c) (strat (strata c) ri) (rules p))
       (lcyc_1_1__all_from_elem _ (\k', e => rarc_5_6_4__count_frame (fkind f) w (w ++ [f]) (rarc_5_6_4__frame_append f w) k' (notWd k' e))))
  where
    noWd : rarc_5_6_5__elem (fkind f) (lcyc_3_1__withdraw_kinds_of (strata c) (strat (strata c) ri) (rules p)) = False
    noWd = snd (certEmit c ri r nr (fkind f) ek rk)
    kInList : Elem (fkind f) (filter (\k' => rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of (strata c) (strat (strata c) ri) (rules p)))
                                     (lcyc_3_1__emit_kinds_of (strata c) (strat (strata c) ri) (rules p)))
    kInList = lcyc_1_1__elem_filter_fwd (\k' => rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of (strata c) (strat (strata c) ri) (rules p))) _
                (lcyc_1_1__elem_l_elem (fkind f) _
                   (lcyc_1_1__elem_concat_map lcyc_3_2_2__emit_kinds (lcyc_3_1__rules_in (strata c) (strat (strata c) ri) (rules p))
                      (lcyc_3_1__rules_in_elem (strata c) (rules p) (strat (strata c) ri) ri r nr Refl) (fkind f) ek))
                rk
    notWd : (k' : Nat) -> Elem k' (lcyc_3_1__withdraw_kinds_of (strata c) (strat (strata c) ri) (rules p)) -> Not (k' = fkind f)
    notWd k' e eq = lcyc_1_1__bool_not_both (rarc_5_6_5__elem (fkind f) (lcyc_3_1__withdraw_kinds_of (strata c) (strat (strata c) ri) (rules p)))
                      (rewrite sym eq in lcyc_1_1__elem_l_true k' _ e) noWd

--@derives [LCYC.3.1.1]
||| A kind emitted-and-read in stratum i is not withdrawn in stratum i.
||| Read off `certEmit`; vacuous for every program the clause
||| admits, since it allows no emitted-and-read kind at all.
export
lcyc_3_1_1__emitted_not_withdrawn : (p : Lcyc_3_2_1__program) -> (c : Lcyc_3_1_1__certified p) -> (i, k' : Nat) ->
                      Elem k' (filter (\k' => rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of (strata c) i (rules p))) (lcyc_3_1__emit_kinds_of (strata c) i (rules p))) ->
                      rarc_5_6_5__elem k' (lcyc_3_1__withdraw_kinds_of (strata c) i (rules p)) = False
lcyc_3_1_1__emitted_not_withdrawn p c i k' e =
  let (ek, rk) = lcyc_1_1__elem_filter_inv (\k' => rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of (strata c) i (rules p))) (lcyc_3_1__emit_kinds_of (strata c) i (rules p)) e
      (q ** (eq, eq'')) = lcyc_1_1__elem_concat_map_inv lcyc_3_2_2__emit_kinds (lcyc_3_1__rules_in (strata c) i (rules p)) k' (lcyc_1_1__elem_l_true k' _ ek)
      (rj ** (nq, sj)) = lcyc_3_1__rules_in_index (strata c) (rules p) i q eq
  in rewrite sym sj in snd (certEmit c rj q nq k' eq'' (rewrite sj in rk))

--@derives [LCYC.1.1]
||| A withdraw strictly lowers comp1 of the withdrawing stratum.
export
lcyc_1_1__comp1_withdraw_lt : (p : Lcyc_3_2_1__program) -> (c : Lcyc_3_1_1__certified p) -> (dom : List (Nat, Nat)) ->
                  (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just r ->
                  (f : Lfac_1_7_1__fact) -> rarc_5_6_5__elem (fkind f) (lcyc_3_2_2__withdraw_kinds r) = True ->
                  (w : Rarc_5_6_4__wm) -> rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) w = True ->
                  LT (lcyc_1_1__comp1 p (strata c) dom (strat (strata c) ri) (rarc_5_6_4__remove_exact f w))
                     (lcyc_1_1__comp1 p (strata c) dom (strat (strata c) ri) w)
lcyc_1_1__comp1_withdraw_lt p c dom ri r nr f wk w live =
  lcyc_1_1__lt_plus_left
    (lcyc_1_1__sum_by_ext (\k' => lcyc_1_1__headroom k' dom (rarc_5_6_4__remove_exact f w)) (\k' => lcyc_1_1__headroom k' dom w) _
       (lcyc_1_1__all_from_elem _ (\k', e => lcyc_1_1__headroom_frame (fkind f) w (rarc_5_6_4__remove_exact f w) (rarc_5_6_4__frame_remove f w) k' (notK k' e) dom)))
    (lcyc_1_1__sum_by_strict (\k' => rarc_5_6_4__count_kind k' w) (\k' => rarc_5_6_4__count_kind k' (rarc_5_6_4__remove_exact f w)) _
       (lcyc_1_1__all_from_elem _ (\k', _ => rarc_5_6_4__count_remove_lte f k' w)) (fkind f) (lcyc_1_1__elem_l_elem (fkind f) _ kInW)
       (rarc_5_6_4__count_remove_lt f w live))
  where
    kInW : rarc_5_6_5__elem (fkind f) (lcyc_3_1__withdraw_kinds_of (strata c) (strat (strata c) ri) (rules p)) = True
    kInW = lcyc_1_1__elem_concat_map lcyc_3_2_2__withdraw_kinds (lcyc_3_1__rules_in (strata c) (strat (strata c) ri) (rules p))
             (lcyc_3_1__rules_in_elem (strata c) (rules p) (strat (strata c) ri) ri r nr Refl) (fkind f) wk
    notK : (k' : Nat) -> Elem k' (filter (\k' => rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of (strata c) (strat (strata c) ri) (rules p)))
                                          (lcyc_3_1__emit_kinds_of (strata c) (strat (strata c) ri) (rules p))) ->
           Not (k' = fkind f)
    notK k' e eq = lcyc_1_1__bool_not_both (rarc_5_6_5__elem k' (lcyc_3_1__withdraw_kinds_of (strata c) (strat (strata c) ri) (rules p)))
                     (rewrite eq in kInW) (lcyc_3_1_1__emitted_not_withdrawn p c (strat (strata c) ri) k' e)

-- ---------------------------------------------------------------------
-- Progress through the actions of one firing
-- ---------------------------------------------------------------------

--@spec [LCYC.1.1]
||| Relative to the post-pop state s0: strata below i are untouched, and
||| stratum i has either strictly lowered comp1 or left both of its
||| components alone.
public export
Lcyc_1_1__progress : (p : Lcyc_3_2_1__program) -> Lcyc_3_1_1__certified p -> List (Nat, Nat) -> Nat -> Rarc_5_6_5__state -> Rarc_5_6_5__state -> Type
Lcyc_1_1__progress p c dom i s0 s =
  ( (j : Nat) -> LT j i ->
      ( lcyc_1_1__comp1 p (strata c) dom j (wm s) = lcyc_1_1__comp1 p (strata c) dom j (wm s0)
      , lcyc_1_1__comp2 (strata c) j (rules p) (toks s) = lcyc_1_1__comp2 (strata c) j (rules p) (toks s0) )
  , Either (LT (lcyc_1_1__comp1 p (strata c) dom i (wm s)) (lcyc_1_1__comp1 p (strata c) dom i (wm s0)))
           ( lcyc_1_1__comp1 p (strata c) dom i (wm s) = lcyc_1_1__comp1 p (strata c) dom i (wm s0)
           , lcyc_1_1__comp2 (strata c) i (rules p) (toks s) = lcyc_1_1__comp2 (strata c) i (rules p) (toks s0) ) )

--@derives [LCYC.1.1]
||| Extend progress by a WM change of kind k made by the firing rule:
||| either the change strictly lowered comp1 of its stratum, or its
||| stratum does not read k at all.
export
lcyc_1_1__progress_change : (p : Lcyc_3_2_1__program) -> (c : Lcyc_3_1_1__certified p) -> (dom : List (Nat, Nat)) ->
                 (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just r ->
                 (k : Nat) -> rarc_5_6_5__elem k (lcyc_3_2_2__write_kinds r) = True ->
                 (s0, s : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom s -> Lcyc_1_1__progress p c dom (strat (strata c) ri) s0 s ->
                 (w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k (wm s) w' ->
                 Either (LT (lcyc_1_1__comp1 p (strata c) dom (strat (strata c) ri) w') (lcyc_1_1__comp1 p (strata c) dom (strat (strata c) ri) (wm s)))
                        (rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of (strata c) (strat (strata c) ri) (rules p)) = False) ->
                 Lcyc_1_1__progress p c dom (strat (strata c) ri) s0 (MkState w' (rarc_5_6_5__propagate p w' (toks s)))
lcyc_1_1__progress_change p c dom ri r nr k wk s0 s inv (below, atI) w' fr change =
  ( \j, lt => let (c1, c2) = below j lt
                  nr' = lcyc_3_1__stratum_below_not_read (strata c) (rules p) (edgeMono c) ri r nr k wk j lt
              in ( trans (lcyc_1_1__comp1_frame p (strata c) dom j k (wm s) w' fr nr') c1
                 , trans (lcyc_1_1__comp2_frame p dom s inv (strata c) k w' fr j nr') c2 )
  , case change of
      Left lt => Left (case atI of
                         Left lt0 => transitive lt (lteSuccLeft lt0)
                         Right (eq, _) => rewrite sym eq in lt)
      Right notRead => case atI of
        Left lt0 => Left (rewrite lcyc_1_1__comp1_frame p (strata c) dom (strat (strata c) ri) k (wm s) w' fr notRead in lt0)
        Right (eq, eq2) =>
          Right ( trans (lcyc_1_1__comp1_frame p (strata c) dom (strat (strata c) ri) k (wm s) w' fr notRead) eq
                , trans (lcyc_1_1__comp2_frame p dom s inv (strata c) k w' fr (strat (strata c) ri) notRead) eq2 ) )

-- ---------------------------------------------------------------------
-- What one action does to working memory
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__find_just : (q : a -> Bool) -> (xs : List a) -> rarc_5_6_5__find q xs = Just x -> (q x = True, Elem x xs)
lcyc_1_1__find_just q [] prf = absurd prf
lcyc_1_1__find_just q (y :: xs) prf with (q y) proof qy
  lcyc_1_1__find_just q (y :: xs) Refl | True = (qy, Here)
  lcyc_1_1__find_just q (y :: xs) prf | False = let (px, e) = lcyc_1_1__find_just q xs prf in (px, There e)

--@derives [IRET.19.1]
export
iret_19_1__entity_kind : (k, key : Nat) -> (w : Rarc_5_6_4__wm) -> (old : Lfac_1_7_1__fact) -> iret_19_1__find_entity k key w = Just old -> fkind old = k
iret_19_1__entity_kind k key w old prf =
  lcyc_1_1__nat_eq_true (fkind old) k (lcyc_1_1__and_true_l (fkind old == k) (fkey old == key)
    (fst (lcyc_1_1__find_just (\f => (fkind f == k) && (fkey f == key)) w prf)))

--@derives [LCYC.1.1]
export
lcyc_1_1__pair_eta : (v : (Nat, Nat)) -> (fst v, snd v) = v
lcyc_1_1__pair_eta (a, b) = Refl

--@derives [IRET.19.1]
||| A successful assert appends a fresh fact of kind k, after removing at
||| most one fact of kind k.
export
iret_19_1__emit_shape : (l : Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (w, w' : Rarc_5_6_4__wm) ->
            iret_19_1__assert_fact l avoid k key pay w = Just w' ->
            Either (w' = w ++ [MkFact (lfac_2_5_3__fresh_id avoid w) k key pay])
                   (old ** (fkind old = k, w' = rarc_5_6_4__remove_exact old w ++ [MkFact (lfac_2_5_3__fresh_id avoid w) k key pay]))
iret_19_1__emit_shape Explicit avoid k key pay w w' prf = Left (sym (lcyc_1_1__just_injective prf))
iret_19_1__emit_shape Relation avoid k key pay w w' prf with (iret_19_1__find_relation k key pay w)
  iret_19_1__emit_shape Relation avoid k key pay w w' prf | (Just _) = absurd prf
  iret_19_1__emit_shape Relation avoid k key pay w w' prf | Nothing = Left (sym (lcyc_1_1__just_injective prf))
iret_19_1__emit_shape Entity avoid k key pay w w' prf with (iret_19_1__find_entity k key w) proof fe
  iret_19_1__emit_shape Entity avoid k key pay w w' prf | Nothing = Left (sym (lcyc_1_1__just_injective prf))
  iret_19_1__emit_shape Entity avoid k key pay w w' prf | (Just old) with (fpay old == pay)
    iret_19_1__emit_shape Entity avoid k key pay w w' prf | (Just old) | True = absurd prf
    iret_19_1__emit_shape Entity avoid k key pay w w' prf | (Just old) | False =
      Right (old ** (iret_19_1__entity_kind k key w old fe, sym (lcyc_1_1__just_injective prf)))

--@derives [IRET.19.1]
export
iret_19_1__emit_frame : (l : Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (w, w' : Rarc_5_6_4__wm) ->
            iret_19_1__assert_fact l avoid k key pay w = Just w' -> Rarc_5_6_4__frame k w w'
iret_19_1__emit_frame l avoid k key pay w w' prf = case iret_19_1__emit_shape l avoid k key pay w w' prf of
  Left eq => rewrite eq in rarc_5_6_4__frame_append (MkFact (lfac_2_5_3__fresh_id avoid w) k key pay) w
  Right (old ** (ok, eq)) =>
    rewrite eq in
    rarc_5_6_4__frame_trans k w (rarc_5_6_4__remove_exact old w) (rarc_5_6_4__remove_exact old w ++ [MkFact (lfac_2_5_3__fresh_id avoid w) k key pay])
      (rewrite sym ok in rarc_5_6_4__frame_remove old w)
      (rarc_5_6_4__frame_append (MkFact (lfac_2_5_3__fresh_id avoid w) k key pay) (rarc_5_6_4__remove_exact old w))

--@derives [IRET.19.1]
||| What a successful Relation assert did: appended, and the value was not live.
export
iret_19_1__relation_assert_shape : (avoid : List Nat) -> (k, key, pay : Nat) -> (w, w' : Rarc_5_6_4__wm) ->
                      iret_19_1__assert_fact Relation avoid k key pay w = Just w' ->
                      (w' = w ++ [MkFact (lfac_2_5_3__fresh_id avoid w) k key pay], lfac_2_5_1__live_val k (key, pay) w = False)
iret_19_1__relation_assert_shape avoid k key pay w w' prf with (iret_19_1__find_relation k key pay w) proof fr
  iret_19_1__relation_assert_shape avoid k key pay w w' prf | (Just _) = absurd prf
  iret_19_1__relation_assert_shape avoid k key pay w w' prf | Nothing =
    (sym (lcyc_1_1__just_injective prf), iret_19_1__find_relation_nothing k key pay w fr)

--@derives [LSCP.2.1.1]
export
lscp_2_1_1__withdraw_shape : (f : Lfac_1_7_1__fact) -> (w, w' : Rarc_5_6_4__wm) -> lscp_2_1_1__withdraw_fact f w = Just w' ->
                (w' = rarc_5_6_4__remove_exact f w, rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) w = True)
lscp_2_1_1__withdraw_shape f w w' prf with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) w) proof live
  lscp_2_1_1__withdraw_shape f w w' prf | True = (sym (lcyc_1_1__just_injective prf), Refl)
  lscp_2_1_1__withdraw_shape f w w' prf | False = absurd prf

--@derives [LCYC.3.1.1]
||| A range over some literals is a range over any superset.
export
lcyc_3_1_1__range_widen : (p : Lcyc_3_2_1__program) -> (lits, dom : List (Nat, Nat)) -> ((x : (Nat, Nat)) -> Elem x lits -> Elem x dom) ->
                          Lcyc_3_1_1__range p lits -> Lcyc_3_1_1__range p dom
lcyc_3_1_1__range_widen p lits dom sub rg ri r nr k v ea fs = case rg ri r nr k v ea fs of
  Left e => Left (sub _ e)
  Right e => Right e

--@derives [LCYC.3.1.1]
||| The emitted value lands in `dom`: a literal, or a copy of a bound value.
||| Stated against a range over `dom` itself so that the TMS engine
||| (Rete/TmsRun.idr) can use it too; the certificate's range is widened
||| to `dom` by `lcyc_3_1_1__range_widen` at the call.
export
lcyc_3_1_1__emit_in_dom : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                          (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                          (bound : List Lfac_1_7_1__fact) -> All (\f => Elem (lfac_2_5_1__val f) dom) bound ->
                          (k : Nat) -> (v : List Lfac_1_7_1__fact -> (Nat, Nat)) -> Elem (Emit k v) (actions rule) -> Elem (v bound) dom
lcyc_3_1_1__emit_in_dom p dom range r rule nr bound bd k v ea = case range r rule nr k v ea bound of
  Left e => e
  Right e => case lcyc_1_1__elem_map_inv (\f => lfac_2_5_1__val f) bound e of
    (f ** (ef, eq)) => replace {p = \x => Elem x dom} eq (lcyc_1_1__all_lookup bd ef)

-- ---------------------------------------------------------------------
-- The invariant after a propagation
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__nth_zip_with_inv : (f : a -> b -> c) -> (i : Nat) -> (xs : List a) -> (ys : List b) ->
                rarc_5_6_5__nth i (zipWith f xs ys) = Just z -> (x ** (y ** (rarc_5_6_5__nth i xs = Just x, rarc_5_6_5__nth i ys = Just y, z = f x y)))
lcyc_1_1__nth_zip_with_inv f _ [] ys prf = absurd prf
lcyc_1_1__nth_zip_with_inv f _ (x :: xs) [] prf = absurd prf
lcyc_1_1__nth_zip_with_inv f Z (x :: xs) (y :: ys) Refl = (x ** (y ** (Refl, Refl, Refl)))
lcyc_1_1__nth_zip_with_inv f (S n) (x :: xs) (y :: ys) prf = lcyc_1_1__nth_zip_with_inv f n xs ys prf

--@derives [LCYC.1.1]
||| Propagating any well-formed tables against a `dom`-valued working
||| memory yields an invariant-satisfying state; settledness of the input
||| tables is not needed, since propagation makes its output settled.
export
lcyc_1_1__propagate_inv_from : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (tables : List (List Iret_11__tok)) ->
                   length tables = length (rules p) ->
                   ((ri : Nat) -> (r : Lgra_6_1__rule) -> (ts : List Iret_11__tok) ->
                      rarc_5_6_5__nth ri (rules p) = Just r -> rarc_5_6_5__nth ri tables = Just ts -> All (Iret_7_4__tok_ok r dom) ts) ->
                   (w' : Rarc_5_6_4__wm) -> All (\f => Elem (lfac_2_5_1__val f) dom) w' ->
                   Lcyc_1_1__inv p dom (MkState w' (rarc_5_6_5__propagate p w' tables))
lcyc_1_1__propagate_inv_from p dom tables len ok w' wd =
  MkInv wd
    (lcyc_1_1__length_zip_with (\r, ts => rarc_5_6_5__prop_rule r w' ts) (rules p) tables len)
    (\ri, r, ts', nr, nt' =>
       let (r' ** (ts ** (nr', nt, eq))) = lcyc_1_1__nth_zip_with_inv (\r, ts => rarc_5_6_5__prop_rule r w' ts) ri (rules p) tables nt'
       in rewrite eq in
          rewrite lcyc_1_1__just_injective (trans (sym nr') nr) in
          iret_7_4__prop_with_ok r dom (iret_7_4__match_tuples r w') (iret_7_9__neg_facts r w') ts (ok ri r ts nr nt) (iret_7_4__match_tuples_ok r dom w' wd))
    (\ri, r, ts', nr, nt' =>
       let (r' ** (ts ** (nr', nt, eq))) = lcyc_1_1__nth_zip_with_inv (\r, ts => rarc_5_6_5__prop_rule r w' ts) ri (rules p) tables nt'
       in rewrite eq in
          rewrite lcyc_1_1__just_injective (trans (sym nr') nr) in
          iret_8_1__prop_with_settled r (iret_7_4__match_tuples r w') (iret_7_9__neg_facts r w') ts)

--@derives [LCYC.1.1]
export
lcyc_1_1__propagate_inv : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (s : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom s ->
               (w' : Rarc_5_6_4__wm) -> All (\f => Elem (lfac_2_5_1__val f) dom) w' ->
               Lcyc_1_1__inv p dom (MkState w' (rarc_5_6_5__propagate p w' (toks s)))
lcyc_1_1__propagate_inv p dom s inv w' wd = lcyc_1_1__propagate_inv_from p dom (toks s) (tokLen inv) (tokOk inv) w' wd

-- ---------------------------------------------------------------------
-- One action: progress and invariant
-- ---------------------------------------------------------------------

--@derives [IRET.7.4]
||| The kind of the i-th bound fact is the i-th pattern kind.
export
iret_7_4__bound_kind : (bound : List Lfac_1_7_1__fact) -> (ks : List Nat) -> lcyc_3_2_2__kinds_of bound = ks -> (i : Nat) -> (f : Lfac_1_7_1__fact) ->
            rarc_5_6_5__nth i bound = Just f -> rarc_5_6_5__nth i ks = Just (fkind f)
iret_7_4__bound_kind bound ks eq i f nb =
  rewrite sym eq in
  rewrite lcyc_1_1__nth_map fkind i bound in
  rewrite nb in Refl

--@derives [RARC.5.6.7]
export
rarc_5_6_7__action_step : (p : Lcyc_3_2_1__program) -> (c : Lcyc_3_1_1__certified p) -> (dom : List (Nat, Nat)) ->
             ((x : (Nat, Nat)) -> Elem x (lits c) -> Elem x dom) ->
             (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just r ->
             (bound : List Lfac_1_7_1__fact) -> lcyc_3_2_2__kinds_of bound = posKinds r -> All (\f => Elem (lfac_2_5_1__val f) dom) bound ->
             (a : Lgra_10_1__action) -> Elem a (actions r) ->
             (s0, s : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom s -> Lcyc_1_1__progress p c dom (strat (strata c) ri) s0 s ->
             ( Lcyc_1_1__progress p c dom (strat (strata c) ri) s0 (rarc_5_6_7__do_action p bound a s)
             , Lcyc_1_1__inv p dom (rarc_5_6_7__do_action p bound a s) )
rarc_5_6_7__action_step p c dom litsIn ri r nr bound bk bd (Emit k v) ea s0 s inv prog
  with (iret_19_1__assert_fact (life p k) (iret_11_3__fact_ids bound) k (fst (v bound)) (snd (v bound)) (wm s)) proof af
  rarc_5_6_7__action_step p c dom litsIn ri r nr bound bk bd (Emit k v) ea s0 s inv prog | Nothing = (prog, inv)
  rarc_5_6_7__action_step p c dom litsIn ri r nr bound bk bd (Emit k v) ea s0 s inv prog | (Just w') =
    ( lcyc_1_1__progress_change p c dom ri r nr k
        (lcyc_1_1__elem_l_append_left k (lcyc_3_2_2__emit_kinds r) (lcyc_3_2_2__withdraw_kinds r) (lcyc_3_2_2__emit_kinds_has r k v ea))
        s0 s inv prog w' (iret_19_1__emit_frame (life p k) (iret_11_3__fact_ids bound) k (fst (v bound)) (snd (v bound)) (wm s) w' af)
        change
    , lcyc_1_1__propagate_inv p dom s inv w' wmDom' )
    where
      inDom : Elem (fst (v bound), snd (v bound)) dom
      inDom = rewrite lcyc_1_1__pair_eta (v bound) in
              lcyc_3_1_1__emit_in_dom p dom (lcyc_3_1_1__range_widen p (lits c) dom litsIn (range c)) ri r nr bound bd k v ea
      wmDom' : All (\f => Elem (lfac_2_5_1__val f) dom) w'
      wmDom' = case iret_19_1__emit_shape (life p k) (iret_11_3__fact_ids bound) k (fst (v bound)) (snd (v bound)) (wm s) w' af of
        Left eq => rewrite eq in lcyc_1_1__all_append (wmDom inv) [inDom]
        Right (old ** (_, eq)) =>
          rewrite eq in lcyc_1_1__all_append (lcyc_1_1__all_filter (\g => not (lfac_2_5_4__same_fact g old)) (wm s) (wmDom inv)) [inDom]
      change : Either (LT (lcyc_1_1__comp1 p (strata c) dom (strat (strata c) ri) w') (lcyc_1_1__comp1 p (strata c) dom (strat (strata c) ri) (wm s)))
                      (rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of (strata c) (strat (strata c) ri) (rules p)) = False)
      change with (rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of (strata c) (strat (strata c) ri) (rules p))) proof rk
        change | False = Right Refl
        change | True =
          let lifeEq : (life p k = Relation)
              lifeEq = fst (certEmit c ri r nr k (lcyc_3_2_2__emit_kinds_has r k v ea) rk)
              afR : (iret_19_1__assert_fact Relation (iret_11_3__fact_ids bound) k (fst (v bound)) (snd (v bound)) (wm s) = Just w')
              afR = replace {p = \l => iret_19_1__assert_fact l (iret_11_3__fact_ids bound) k (fst (v bound)) (snd (v bound)) (wm s) = Just w'} lifeEq af
              shape = iret_19_1__relation_assert_shape (iret_11_3__fact_ids bound) k (fst (v bound)) (snd (v bound)) (wm s) w' afR
          in Left (rewrite fst shape in
                   lcyc_1_1__comp1_emit_lt p c dom ri r nr (MkFact (lfac_2_5_3__fresh_id (iret_11_3__fact_ids bound) (wm s)) k (fst (v bound)) (snd (v bound)))
                     (lcyc_3_2_2__emit_kinds_has r k v ea) rk (wm s) (snd shape) inDom)
rarc_5_6_7__action_step p c dom litsIn ri r nr bound bk bd (Withdraw idx) ea s0 s inv prog with (rarc_5_6_5__nth idx bound) proof nb
  rarc_5_6_7__action_step p c dom litsIn ri r nr bound bk bd (Withdraw idx) ea s0 s inv prog | Nothing = (prog, inv)
  rarc_5_6_7__action_step p c dom litsIn ri r nr bound bk bd (Withdraw idx) ea s0 s inv prog | (Just f)
    with (lscp_2_1_1__withdraw_fact f (wm s)) proof wf
    rarc_5_6_7__action_step p c dom litsIn ri r nr bound bk bd (Withdraw idx) ea s0 s inv prog | (Just f) | Nothing = (prog, inv)
    rarc_5_6_7__action_step p c dom litsIn ri r nr bound bk bd (Withdraw idx) ea s0 s inv prog | (Just f) | (Just w') =
      let sh = lscp_2_1_1__withdraw_shape f (wm s) w' wf
          wk : (rarc_5_6_5__elem (fkind f) (lcyc_3_2_2__withdraw_kinds r) = True)
          wk = lcyc_3_2_2__withdraw_kinds_has r idx (fkind f) ea (iret_7_4__bound_kind bound (posKinds r) bk idx f nb)
      in ( lcyc_1_1__progress_change p c dom ri r nr (fkind f)
             (lcyc_1_1__elem_l_append_right (fkind f) (lcyc_3_2_2__emit_kinds r) (lcyc_3_2_2__withdraw_kinds r) wk)
             s0 s inv prog w' (rewrite fst sh in rarc_5_6_4__frame_remove f (wm s))
             (Left (rewrite fst sh in lcyc_1_1__comp1_withdraw_lt p c dom ri r nr f wk (wm s) (snd sh)))
         , lcyc_1_1__propagate_inv p dom s inv w' (rewrite fst sh in lcyc_1_1__all_filter (\g => not (lfac_2_5_4__same_fact g f)) (wm s) (wmDom inv)) )

--@derives [RARC.5.6.7]
export
rarc_5_6_7__actions_step : (p : Lcyc_3_2_1__program) -> (c : Lcyc_3_1_1__certified p) -> (dom : List (Nat, Nat)) ->
              ((x : (Nat, Nat)) -> Elem x (lits c) -> Elem x dom) ->
              (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just r ->
              (bound : List Lfac_1_7_1__fact) -> lcyc_3_2_2__kinds_of bound = posKinds r -> All (\f => Elem (lfac_2_5_1__val f) dom) bound ->
              (as : List Lgra_10_1__action) -> All (\a => Elem a (actions r)) as ->
              (s0, s : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom s -> Lcyc_1_1__progress p c dom (strat (strata c) ri) s0 s ->
              ( Lcyc_1_1__progress p c dom (strat (strata c) ri) s0 (rarc_5_6_7__do_actions p bound as s)
              , Lcyc_1_1__inv p dom (rarc_5_6_7__do_actions p bound as s) )
rarc_5_6_7__actions_step p c dom litsIn ri r nr bound bk bd [] [] s0 s inv prog = (prog, inv)
rarc_5_6_7__actions_step p c dom litsIn ri r nr bound bk bd (a :: as) (ea :: eas) s0 s inv prog =
  let (prog', inv') = rarc_5_6_7__action_step p c dom litsIn ri r nr bound bk bd a ea s0 s inv prog
  in rarc_5_6_7__actions_step p c dom litsIn ri r nr bound bk bd as eas s0 (rarc_5_6_7__do_action p bound a s) inv' prog'

-- ---------------------------------------------------------------------
-- The pop
-- ---------------------------------------------------------------------

--@derives [IDAT.6.2.2]
export
idat_6_2_2__pending_mark_lte : (j : Nat) -> (ts : List Iret_11__tok) -> LTE (iret_11_3_1__pending_count (idat_6_2_2__mark_at j ts)) (iret_11_3_1__pending_count ts)
idat_6_2_2__pending_mark_lte _ [] = LTEZero
idat_6_2_2__pending_mark_lte Z (t :: ts) with (iret_11_3_1__pending_tok t)
  idat_6_2_2__pending_mark_lte Z (t :: ts) | True = lteSuccRight reflexive
  idat_6_2_2__pending_mark_lte Z (t :: ts) | False = reflexive
idat_6_2_2__pending_mark_lte (S j) (t :: ts) with (iret_11_3_1__pending_tok t)
  idat_6_2_2__pending_mark_lte (S j) (t :: ts) | True = LTESucc (idat_6_2_2__pending_mark_lte j ts)
  idat_6_2_2__pending_mark_lte (S j) (t :: ts) | False = idat_6_2_2__pending_mark_lte j ts

--@derives [IDAT.6.2.2]
||| Marking the fired token: its own stratum's comp2 drops, every other
||| stratum's comp2 is unchanged, and working memory is untouched.
export
idat_6_2_2__pop_inv : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (st : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom st -> (r, j : Nat) ->
         Lcyc_1_1__inv p dom (MkState (wm st) (idat_6_2_2__mark_fired r j (toks st)))
idat_6_2_2__pop_inv p dom st inv r j =
  MkInv (wmDom inv)
    (trans (lcyc_1_1__length_set_at r (idat_6_2_2__mark_at j) (toks st)) (tokLen inv))
    (\ri, q, ts', nq, nt' => case decEq r ri of
        Yes Refl => let (ts ** (nt, eq)) = nthMapInv (idat_6_2_2__mark_at j) ri (toks st) (trans (sym (lcyc_1_1__nth_set_at_eq ri (idat_6_2_2__mark_at j) (toks st))) nt')
                    in rewrite eq in lcyc_1_1__all_set_at idat_6_2_2__mark_t (\t, ok => ok) j ts (tokOk inv ri q ts nq nt)
        No neq => tokOk inv ri q ts' nq (trans (sym (lcyc_1_1__nth_set_at_neq r ri neq (idat_6_2_2__mark_at j) (toks st))) nt'))
    (\ri, q, ts', nq, nt' => case decEq r ri of
        Yes Refl => let (ts ** (nt, eq)) = nthMapInv (idat_6_2_2__mark_at j) ri (toks st) (trans (sym (lcyc_1_1__nth_set_at_eq ri (idat_6_2_2__mark_at j) (toks st))) nt')
                    in rewrite eq in idat_6_2_2__mark_settled q (iret_7_4__match_tuples q (wm st)) (iret_7_9__neg_facts q (wm st)) ts j (settled inv ri q ts nq nt)
        No neq => settled inv ri q ts' nq (trans (sym (lcyc_1_1__nth_set_at_neq r ri neq (idat_6_2_2__mark_at j) (toks st))) nt'))
  where
    nthMapInv : (f : a -> a) -> (i : Nat) -> (xs : List a) -> map f (rarc_5_6_5__nth i xs) = Just y -> (x ** (rarc_5_6_5__nth i xs = Just x, y = f x))
    nthMapInv f i xs prf with (rarc_5_6_5__nth i xs)
      nthMapInv f i xs prf | Nothing = absurd prf
      nthMapInv f i xs prf | (Just x) = (x ** (Refl, sym (lcyc_1_1__just_injective prf)))

--@derives [LCYC.1.1]
||| Other strata's comp2 is unchanged by the pop.
export
lcyc_1_1__pop_comp2_other : (p : Lcyc_3_2_1__program) -> (s : Lcyc_3_1__strata) -> (st : Rarc_5_6_5__state) -> (r, j : Nat) -> (rule : Lgra_6_1__rule) ->
                rarc_5_6_5__nth r (rules p) = Just rule -> (i : Nat) -> Not (i = strat s r) ->
                lcyc_1_1__comp2 s i (rules p) (idat_6_2_2__mark_fired r j (toks st)) = lcyc_1_1__comp2 s i (rules p) (toks st)
lcyc_1_1__pop_comp2_other p s st r j rule nr i neq =
  lcyc_1_1__comp2_ext s i (rules p) (toks st) (idat_6_2_2__mark_fired r j (toks st))
    (\ri, e => let (q ** (nq, eq)) = lcyc_3_1__indices_in_elem s (rules p) i ri e
               in lcyc_1_1__nth_set_at_neq r ri (\rEq => neq (trans (sym eq) (cong (strat s) (sym rEq)))) (idat_6_2_2__mark_at j) (toks st))

--@derives [LCYC.1.1]
||| The firing stratum's comp2 strictly drops on the pop.
export
lcyc_1_1__pop_comp2_own : (p : Lcyc_3_2_1__program) -> (s : Lcyc_3_1__strata) -> (st : Rarc_5_6_5__state) -> (r, j : Nat) -> (rule : Lgra_6_1__rule) ->
              rarc_5_6_5__nth r (rules p) = Just rule -> (ts : List Iret_11__tok) -> rarc_5_6_5__nth r (toks st) = Just ts ->
              (t : Iret_11__tok) -> rarc_5_6_5__nth j ts = Just t -> iret_11_3_1__pending_tok t = True ->
              LT (lcyc_1_1__comp2 s (strat s r) (rules p) (idat_6_2_2__mark_fired r j (toks st))) (lcyc_1_1__comp2 s (strat s r) (rules p) (toks st))
lcyc_1_1__pop_comp2_own p s st r j rule nr ts nt t njt pt =
  lcyc_1_1__sum_by_strict (\ri => iret_11_3_1__pending_count (iret_11__table_at ri (toks st))) (\ri => iret_11_3_1__pending_count (iret_11__table_at ri (idat_6_2_2__mark_fired r j (toks st))))
    (lcyc_3_1__indices_in s (strat s r) (rules p))
    (lcyc_1_1__all_from_elem _ (\ri, _ => termLTE ri))
    r (lcyc_3_1__indices_in_has s (rules p) (strat s r) r rule nr Refl)
    (rewrite lcyc_1_1__nth_set_at_eq r (idat_6_2_2__mark_at j) (toks st) in
     rewrite nt in
     rewrite sym (idat_6_2_2__pending_count_mark j ts t njt pt) in reflexive)
  where
    tableLTE : (m : Maybe (List Iret_11__tok)) -> LTE (iret_11_3_1__pending_count (iret_11__from_maybe (map (idat_6_2_2__mark_at j) m))) (iret_11_3_1__pending_count (iret_11__from_maybe m))
    tableLTE Nothing = LTEZero
    tableLTE (Just ts) = idat_6_2_2__pending_mark_lte j ts
    termLTE : (ri : Nat) -> LTE (iret_11_3_1__pending_count (iret_11__table_at ri (idat_6_2_2__mark_fired r j (toks st)))) (iret_11_3_1__pending_count (iret_11__table_at ri (toks st)))
    termLTE ri = case decEq r ri of
      Yes Refl => rewrite lcyc_1_1__nth_set_at_eq ri (idat_6_2_2__mark_at j) (toks st) in tableLTE (rarc_5_6_5__nth ri (toks st))
      No neq => rewrite lcyc_1_1__nth_set_at_neq r ri neq (idat_6_2_2__mark_at j) (toks st) in reflexive

-- ---------------------------------------------------------------------
-- Lexicographic assembly
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__measure_from_len_eq : (p : Lcyc_3_2_1__program) -> (s : Lcyc_3_1__strata) -> (dom : List (Nat, Nat)) -> (a, n : Nat) -> (st, st' : Rarc_5_6_5__state) ->
                   length (lcyc_1_1__measure_from p s dom a n st') = length (lcyc_1_1__measure_from p s dom a n st)
lcyc_1_1__measure_from_len_eq p s dom a Z st st' = Refl
lcyc_1_1__measure_from_len_eq p s dom a (S n) st st' = cong S (cong S (lcyc_1_1__measure_from_len_eq p s dom (S a) n st st'))

--@derives [LCYC.1.1]
export
lcyc_1_1__lte_neq_lt : (a, i : Nat) -> LTE a i -> Not (a = i) -> LT a i
lcyc_1_1__lte_neq_lt Z Z _ neq = absurd (neq Refl)
lcyc_1_1__lte_neq_lt Z (S i) _ _ = LTESucc LTEZero
lcyc_1_1__lte_neq_lt (S a) (S i) (LTESucc le) neq = LTESucc (lcyc_1_1__lte_neq_lt a i le (\eq => neq (cong S eq)))

--@derives [LCYC.1.1]
export
lcyc_1_1__lex_from : (p : Lcyc_3_2_1__program) -> (s : Lcyc_3_1__strata) -> (dom : List (Nat, Nat)) -> (st, st' : Rarc_5_6_5__state) ->
          (a, n : Nat) -> (i : Nat) -> LTE a i -> LT i (a + n) ->
          ((j : Nat) -> LTE a j -> LT j i ->
             ( lcyc_1_1__comp1 p s dom j (wm st') = lcyc_1_1__comp1 p s dom j (wm st)
             , lcyc_1_1__comp2 s j (rules p) (toks st') = lcyc_1_1__comp2 s j (rules p) (toks st) )) ->
          Either (LT (lcyc_1_1__comp1 p s dom i (wm st')) (lcyc_1_1__comp1 p s dom i (wm st)))
                 ( lcyc_1_1__comp1 p s dom i (wm st') = lcyc_1_1__comp1 p s dom i (wm st)
                 , LT (lcyc_1_1__comp2 s i (rules p) (toks st')) (lcyc_1_1__comp2 s i (rules p) (toks st)) ) ->
          Lcyc_1_1__lex_lt (lcyc_1_1__measure_from p s dom a n st') (lcyc_1_1__measure_from p s dom a n st)
lcyc_1_1__lex_from p s dom st st' a Z i le lt below atI =
  absurd (succNotLTEpred (transitive (replace {p = \x => LTE (S i) x} (plusZeroRightNeutral a) lt) le))
lcyc_1_1__lex_from p s dom st st' a (S n) i le lt below atI with (decEq a i)
  lcyc_1_1__lex_from p s dom st st' a (S n) a le lt below atI | (Yes Refl) = case atI of
    Left c1lt => LexHead c1lt (cong S (lcyc_1_1__measure_from_len_eq p s dom (S a) n st st'))
    Right (c1eq, c2lt) => rewrite c1eq in LexTail (LexHead c2lt (lcyc_1_1__measure_from_len_eq p s dom (S a) n st st'))
  lcyc_1_1__lex_from p s dom st st' a (S n) i le lt below atI | (No neq) =
    let aLtI = lcyc_1_1__lte_neq_lt a i le neq
        (e1, e2) = below a reflexive aLtI
    in rewrite e1 in rewrite e2 in
       LexTail (LexTail (lcyc_1_1__lex_from p s dom st st' (S a) n i aLtI
                  (replace {p = \x => LTE (S i) x} (sym (plusSuccRightSucc a n)) lt)
                  (\j, le', lt' => below j (lteSuccLeft le') lt') atI))

-- ---------------------------------------------------------------------
-- One firing
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__step_decreases_inv : (p : Lcyc_3_2_1__program) -> (c : Lcyc_3_1_1__certified p) -> (dom : List (Nat, Nat)) ->
  ((x : (Nat, Nat)) -> Elem x (lits c) -> Elem x dom) ->
  (st, st' : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom st -> iret_11_4__step p st = Just st' ->
  (Lcyc_1_1__lex_lt (lcyc_1_1__measure p (strata c) dom st') (lcyc_1_1__measure p (strata c) dom st), Lcyc_1_1__inv p dom st')
lcyc_1_1__step_decreases_inv p c dom litsIn st st' inv eq with (ldet_5_1__select_next (toks st)) proof sel
  lcyc_1_1__step_decreases_inv p c dom litsIn st st' inv eq | Nothing = absurd eq
  lcyc_1_1__step_decreases_inv p c dom litsIn st st' inv eq | (Just (r, j)) with (rarc_5_6_5__nth r (rules p)) proof nr
    lcyc_1_1__step_decreases_inv p c dom litsIn st st' inv eq | (Just (r, j)) | Nothing = absurd eq
    lcyc_1_1__step_decreases_inv p c dom litsIn st st' inv eq | (Just (r, j)) | (Just rule)
      with (rarc_5_6_5__nth j (iret_11__table_at r (toks st))) proof ntok
      lcyc_1_1__step_decreases_inv p c dom litsIn st st' inv eq | (Just (r, j)) | (Just rule) | Nothing = absurd eq
      lcyc_1_1__step_decreases_inv p c dom litsIn st st' inv eq | (Just (r, j)) | (Just rule) | (Just tok) =
        let (ts ** (t ** (nt, njt, pt))) = ldet_5_1__select_next_pending (toks st) r j sel
            tokEq : (tok = t)
            tokEq = lcyc_1_1__just_injective (trans (sym ntok) (replace {p = \m => rarc_5_6_5__nth j (iret_11__from_maybe m) = Just t} (sym nt) njt))
            njtok : (rarc_5_6_5__nth j ts = Just tok)
            njtok = replace {p = \x => rarc_5_6_5__nth j ts = Just x} (sym tokEq) njt
            okTok = lcyc_1_1__all_lookup (tokOk inv r rule ts nr nt) (lcyc_1_1__nth_elem j ts njtok)
            res = rarc_5_6_7__actions_step p c dom litsIn r rule nr (tfacts tok) (fst okTok) (snd okTok) (actions rule)
                    (lcyc_1_1__all_from_elem (actions rule) (\a, e => e))
                    (MkState (wm st) (idat_6_2_2__mark_fired r j (toks st))) (MkState (wm st) (idat_6_2_2__mark_fired r j (toks st)))
                    (idat_6_2_2__pop_inv p dom st inv r j)
                    (\j', _ => (Refl, Refl), Right (Refl, Refl))
            prog = fst res
            inv' = snd res
            stEq : (st' = rarc_5_6_7__do_actions p (tfacts tok) (actions rule) (MkState (wm st) (idat_6_2_2__mark_fired r j (toks st))))
            stEq = sym (lcyc_1_1__just_injective eq)
            below : (j' : Nat) -> LT j' (strat (strata c) r) ->
                    ( lcyc_1_1__comp1 p (strata c) dom j' (wm st') = lcyc_1_1__comp1 p (strata c) dom j' (wm st)
                    , lcyc_1_1__comp2 (strata c) j' (rules p) (toks st') = lcyc_1_1__comp2 (strata c) j' (rules p) (toks st) )
            below j' lt = let (e1, e2) = fst prog j' lt
                          in ( rewrite stEq in e1
                             , rewrite stEq in trans e2 (lcyc_1_1__pop_comp2_other p (strata c) st r j rule nr j'
                                 (\x => succNotLTEpred (replace {p = \y => LTE (S j') y} (sym x) lt))) )
            atI : Either (LT (lcyc_1_1__comp1 p (strata c) dom (strat (strata c) r) (wm st')) (lcyc_1_1__comp1 p (strata c) dom (strat (strata c) r) (wm st)))
                         ( lcyc_1_1__comp1 p (strata c) dom (strat (strata c) r) (wm st') = lcyc_1_1__comp1 p (strata c) dom (strat (strata c) r) (wm st)
                         , LT (lcyc_1_1__comp2 (strata c) (strat (strata c) r) (rules p) (toks st')) (lcyc_1_1__comp2 (strata c) (strat (strata c) r) (rules p) (toks st)) )
            atI = case snd prog of
              Left lt => Left (rewrite stEq in lt)
              Right (e1, e2) => Right ( rewrite stEq in e1
                                      , rewrite stEq in rewrite e2 in lcyc_1_1__pop_comp2_own p (strata c) st r j rule nr ts nt t njt pt )
        in ( lcyc_1_1__lex_from p (strata c) dom st st' 0 (count (strata c)) (strat (strata c) r) LTEZero
               (inRange c r rule nr) (\j', _, lt => below j' lt) atI
           , rewrite stEq in inv' )

--@derives [LCYC.1.1]
||| A certified program quiesces from every invariant-satisfying state:
||| some number of firings reaches an empty agenda. Well-founded recursion
||| on the measure's accessibility.
export
lcyc_1_1__quiesces : (p : Lcyc_3_2_1__program) -> (c : Lcyc_3_1_1__certified p) -> (dom : List (Nat, Nat)) ->
  ((x : (Nat, Nat)) -> Elem x (lits c) -> Elem x dom) ->
  (st : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom st -> Accessible Lcyc_1_1__lex_lt (lcyc_1_1__measure p (strata c) dom st) ->
  (n : Nat ** iret_11_4__step_n p n st = Nothing)
lcyc_1_1__quiesces p c dom litsIn st inv (Access h) with (iret_11_4__step p st) proof prf
  lcyc_1_1__quiesces p c dom litsIn st inv (Access h) | Nothing = (1 ** rewrite prf in Refl)
  lcyc_1_1__quiesces p c dom litsIn st inv (Access h) | (Just st') =
    let (dec, inv') = lcyc_1_1__step_decreases_inv p c dom litsIn st st' inv prf
        (n ** done) = lcyc_1_1__quiesces p c dom litsIn st' inv' (h _ dec)
    in (S n ** rewrite prf in done)

-- ---------------------------------------------------------------------
-- The initial state satisfies the invariant
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.5]
export
rarc_5_6_5__no_tokens : Lcyc_3_2_1__program -> List (List Iret_11__tok)
rarc_5_6_5__no_tokens p = map (const (the (List Iret_11__tok) [])) (rules p)

--@derives [RARC.5.6.5]
export
rarc_5_6_5__no_tokens_nth : (p : Lcyc_3_2_1__program) -> (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just r -> rarc_5_6_5__nth ri (rarc_5_6_5__no_tokens p) = Just []
rarc_5_6_5__no_tokens_nth p ri r nr = rewrite lcyc_1_1__nth_map (const (the (List Iret_11__tok) [])) ri (rules p) in rewrite nr in Refl

--@derives [LCYC.1.1]
export
lcyc_1_1__init_inv : (p : Lcyc_3_2_1__program) -> (c : Lcyc_3_1_1__certified p) -> (wm0 : Rarc_5_6_4__wm) -> Lcyc_1_1__inv p (lcyc_1_1__dom_of c wm0) (rarc_5_6_5__init_state p wm0)
lcyc_1_1__init_inv p c wm0 =
  lcyc_1_1__propagate_inv_from p (lcyc_1_1__dom_of c wm0) (rarc_5_6_5__no_tokens p) (lengthMap (rules p))
    (\ri, r, ts, nr, nt => rewrite lcyc_1_1__just_injective (trans (sym nt) (rarc_5_6_5__no_tokens_nth p ri r nr)) in [])
    wm0 (lcyc_1_1__all_from_elem wm0 (\f, e => lcyc_1_1__elem_append_right (lits c) (lcyc_1_1__elem_map_fwd (\f => lfac_2_5_1__val f) e)))

--@derives [LCYC.1.1]
||| THE THEOREM. A certified program reaches an empty agenda from every
||| input working memory, on the deterministic engine.
export
lcyc_1_1__certified_terminates : (p : Lcyc_3_2_1__program) -> (c : Lcyc_3_1_1__certified p) -> (wm0 : Rarc_5_6_4__wm) ->
                      (n : Nat ** iret_11_4__step_n p n (rarc_5_6_5__init_state p wm0) = Nothing)
lcyc_1_1__certified_terminates p c wm0 =
  lcyc_1_1__quiesces p c (lcyc_1_1__dom_of c wm0) (\x, e => lcyc_1_1__elem_append_left e) (rarc_5_6_5__init_state p wm0) (lcyc_1_1__init_inv p c wm0)
           (lcyc_1_1__lex_acc (lcyc_1_1__measure p (strata c) (lcyc_1_1__dom_of c wm0) (rarc_5_6_5__init_state p wm0)))

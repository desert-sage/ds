-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Propagation lemmas for Lcyc/Certificate.idr: a rule's re-propagation
||| depends only on the facts of the kinds it reads (frame), a settled
||| token table is a fixpoint of re-propagation, marking a token fired
||| keeps a table settled, selection returns a pending token whose
||| marking lowers the pending count by exactly one, and re-propagation
||| produces well-formed tokens.
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr:
||| clause-named elements and `--@spec` / `--@derives` markers. Propagation
||| lemmas are named under [RARC.5.6.5], token-table lemmas under the
||| [IRET.8.1] / [IRET.7.4] structure they are about, selection lemmas under
||| [LDET.5.1] / [LDET.5.5], and generic list lemmas under [LCYC.1.1], the
||| clause the termination proof establishes.
module Lcyc.Propagation

import Rete.FireLoop
import Lcyc.Lemmas
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- More list lemmas
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__all_imp : (xs : List a) -> ((x : a) -> prop x -> prop' x) -> All prop xs -> All prop' xs
lcyc_1_1__all_imp [] f [] = []
lcyc_1_1__all_imp (x :: xs) f (p :: ps) = f x p :: lcyc_1_1__all_imp xs f ps

--@derives [LCYC.1.1]
export
lcyc_1_1__all_zip : (xs : List a) -> All prop xs -> All prop' xs -> All (\x => (prop x, prop' x)) xs
lcyc_1_1__all_zip [] [] [] = []
lcyc_1_1__all_zip (x :: xs) (p :: ps) (q :: qs) = (p, q) :: lcyc_1_1__all_zip xs ps qs

--@derives [LCYC.1.1]
export
lcyc_1_1__all_concat_map : (g : a -> List b) -> (xs : List a) -> All (\x => All prop (g x)) xs ->
                All prop (rarc_5_6_5__concat_map g xs)
lcyc_1_1__all_concat_map g [] [] = []
lcyc_1_1__all_concat_map g (x :: xs) (px :: pxs) = lcyc_1_1__all_append px (lcyc_1_1__all_concat_map g xs pxs)

--@derives [LCYC.1.1]
export
lcyc_1_1__map_id_all : (f : a -> a) -> (xs : List a) -> All (\x => f x = x) xs -> map f xs = xs
lcyc_1_1__map_id_all f [] [] = Refl
lcyc_1_1__map_id_all f (x :: xs) (px :: pxs) = rewrite px in cong (x ::) (lcyc_1_1__map_id_all f xs pxs)

--@derives [LCYC.1.1]
export
lcyc_1_1__filter_all_true : (p : a -> Bool) -> (xs : List a) -> All (\x => p x = True) xs -> filter p xs = xs
lcyc_1_1__filter_all_true p [] [] = Refl
lcyc_1_1__filter_all_true p (x :: xs) (px :: pxs) = rewrite px in cong (x ::) (lcyc_1_1__filter_all_true p xs pxs)

--@derives [LCYC.1.1]
export
lcyc_1_1__filter_all_false : (p : a -> Bool) -> (xs : List a) -> All (\x => p x = False) xs -> filter p xs = []
lcyc_1_1__filter_all_false p [] [] = Refl
lcyc_1_1__filter_all_false p (x :: xs) (px :: pxs) = rewrite px in lcyc_1_1__filter_all_false p xs pxs

--@derives [LCYC.1.1]
export
lcyc_1_1__all_set_at : (f : a -> a) -> ((x : a) -> prop x -> prop (f x)) -> (j : Nat) -> (xs : List a) ->
           All prop xs -> All prop (rarc_5_6_5__set_at j f xs)
lcyc_1_1__all_set_at f pf _ [] [] = []
lcyc_1_1__all_set_at f pf Z (x :: xs) (px :: pxs) = pf x px :: pxs
lcyc_1_1__all_set_at f pf (S j) (x :: xs) (px :: pxs) = px :: lcyc_1_1__all_set_at f pf j xs pxs

--@derives [LCYC.1.1]
export
lcyc_1_1__map_set_at : (f : a -> a) -> (g : a -> b) -> ((x : a) -> g (f x) = g x) -> (j : Nat) -> (xs : List a) ->
           map g (rarc_5_6_5__set_at j f xs) = map g xs
lcyc_1_1__map_set_at f g gf _ [] = Refl
lcyc_1_1__map_set_at f g gf Z (x :: xs) = rewrite gf x in Refl
lcyc_1_1__map_set_at f g gf (S j) (x :: xs) = cong (g x ::) (lcyc_1_1__map_set_at f g gf j xs)

--@derives [LCYC.1.1]
||| Kept as a local lemma: Idris 2 0.8.0's base has no `Injective Just`
||| instance and does not export `justInjective`.
export
lcyc_1_1__just_injective : Just x = Just y -> x = y
lcyc_1_1__just_injective Refl = Refl

--@derives [LCYC.1.1]
export
lcyc_1_1__pair_just : Just (a, b) = Just (c, d) -> (a = c, b = d)
lcyc_1_1__pair_just Refl = (Refl, Refl)

-- ---- Eq on List Nat, and elemL on it ----------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__list_nat_eq_refl : (xs : List Nat) -> (xs == xs) = True
lcyc_1_1__list_nat_eq_refl [] = Refl
lcyc_1_1__list_nat_eq_refl (x :: xs) = rewrite lcyc_1_1__nat_eq_refl x in lcyc_1_1__list_nat_eq_refl xs

--@derives [LCYC.1.1]
export
lcyc_1_1__list_nat_eq_true : (xs, ys : List Nat) -> (xs == ys) = True -> xs = ys
lcyc_1_1__list_nat_eq_true [] [] _ = Refl
lcyc_1_1__list_nat_eq_true [] (y :: ys) prf = absurd prf
lcyc_1_1__list_nat_eq_true (x :: xs) [] prf = absurd prf
lcyc_1_1__list_nat_eq_true (x :: xs) (y :: ys) prf =
  rewrite lcyc_1_1__nat_eq_true x y (lcyc_1_1__and_true_l (x == y) (xs == ys) prf) in
  rewrite lcyc_1_1__list_nat_eq_true xs ys (lcyc_1_1__and_true_r (x == y) (xs == ys) prf) in Refl

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_l_true_by : Eq a => ((z : a) -> (z == z) = True) -> (x : a) -> (xs : List a) -> Elem x xs ->
              rarc_5_6_5__elem x xs = True
lcyc_1_1__elem_l_true_by refl x (x :: xs) Here = rewrite refl x in Refl
lcyc_1_1__elem_l_true_by refl x (y :: xs) (There e) with (y == x)
  lcyc_1_1__elem_l_true_by refl x (y :: xs) (There e) | True = Refl
  lcyc_1_1__elem_l_true_by refl x (y :: xs) (There e) | False = lcyc_1_1__elem_l_true_by refl x xs e

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_l_elem_by : Eq a => ((y, z : a) -> (y == z) = True -> y = z) -> (x : a) -> (xs : List a) ->
              rarc_5_6_5__elem x xs = True -> Elem x xs
lcyc_1_1__elem_l_elem_by sound x [] prf = absurd prf
lcyc_1_1__elem_l_elem_by sound x (y :: xs) prf with (y == x) proof yx
  lcyc_1_1__elem_l_elem_by sound x (y :: xs) prf | True = rewrite sym (sound y x yx) in Here
  lcyc_1_1__elem_l_elem_by sound x (y :: xs) prf | False = There (lcyc_1_1__elem_l_elem_by sound x xs prf)

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_ll_true : (x : List Nat) -> (xs : List (List Nat)) -> Elem x xs -> rarc_5_6_5__elem x xs = True
lcyc_1_1__elem_ll_true = lcyc_1_1__elem_l_true_by lcyc_1_1__list_nat_eq_refl

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_ll_elem : (x : List Nat) -> (xs : List (List Nat)) -> rarc_5_6_5__elem x xs = True -> Elem x xs
lcyc_1_1__elem_ll_elem = lcyc_1_1__elem_l_elem_by lcyc_1_1__list_nat_eq_true

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_l_append_false : (x : Nat) -> (xs, ys : List Nat) -> rarc_5_6_5__elem x (xs ++ ys) = False ->
                   (rarc_5_6_5__elem x xs = False, rarc_5_6_5__elem x ys = False)
lcyc_1_1__elem_l_append_false x xs ys prf with (rarc_5_6_5__elem x xs) proof p
  lcyc_1_1__elem_l_append_false x xs ys prf | True = absurd (trans (sym (lcyc_1_1__elem_l_append_left x xs ys p)) prf)
  lcyc_1_1__elem_l_append_false x xs ys prf | False with (rarc_5_6_5__elem x ys) proof q
    lcyc_1_1__elem_l_append_false x xs ys prf | False | True = absurd (trans (sym (lcyc_1_1__elem_l_append_right x xs ys q)) prf)
    lcyc_1_1__elem_l_append_false x xs ys prf | False | False = (Refl, Refl)

-- ---------------------------------------------------------------------
-- Frame: re-propagation reads only the kinds the rule reads
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.5]
export
rarc_5_6_5__tuples_frame : (k : Nat) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k w w' -> (ks : List Nat) -> rarc_5_6_5__elem k ks = False ->
              iret_7_4__tuples ks w' = iret_7_4__tuples ks w
rarc_5_6_5__tuples_frame k w w' fr [] prf = Refl
rarc_5_6_5__tuples_frame k w w' fr (k1 :: ks) prf with (k1 == k) proof e
  rarc_5_6_5__tuples_frame k w w' fr (k1 :: ks) prf | True = absurd prf
  rarc_5_6_5__tuples_frame k w w' fr (k1 :: ks) prf | False =
    rewrite fr k1 (lcyc_1_1__nat_neq_false k1 k e) in rewrite rarc_5_6_5__tuples_frame k w w' fr ks prf in Refl

--@derives [RARC.5.6.5]
export
rarc_5_6_5__neg_facts_frame : (k : Nat) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k w w' -> (nbs : List (Nat, List Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Bool)) ->
                rarc_5_6_5__elem k (map (\nb => fst nb) nbs) = False ->
                map (\nb => rarc_5_6_4__facts_of_kind (fst nb) w') nbs = map (\nb => rarc_5_6_4__facts_of_kind (fst nb) w) nbs
rarc_5_6_5__neg_facts_frame k w w' fr [] prf = Refl
rarc_5_6_5__neg_facts_frame k w w' fr (nb :: nbs) prf with (fst nb == k) proof e
  rarc_5_6_5__neg_facts_frame k w w' fr (nb :: nbs) prf | True = absurd prf
  rarc_5_6_5__neg_facts_frame k w w' fr (nb :: nbs) prf | False =
    rewrite fr (fst nb) (lcyc_1_1__nat_neq_false (fst nb) k e) in
    cong (rarc_5_6_4__facts_of_kind (fst nb) w ::) (rarc_5_6_5__neg_facts_frame k w w' fr nbs prf)

--@derives [RARC.5.6.5]
export
rarc_5_6_5__prop_rule_frame : (k : Nat) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k w w' -> (r : Lgra_6_1__rule) -> rarc_5_6_5__elem k (lcyc_3_2_2__read_kinds r) = False ->
                (ts : List Iret_11__tok) -> rarc_5_6_5__prop_rule r w' ts = rarc_5_6_5__prop_rule r w ts
rarc_5_6_5__prop_rule_frame k w w' fr r prf ts =
  let (pk, nk) = lcyc_1_1__elem_l_append_false k (posKinds r) (iret_7_9__neg_kinds r) prf
  in rewrite rarc_5_6_5__tuples_frame k w w' fr (posKinds r) pk in
     rewrite rarc_5_6_5__neg_facts_frame k w w' fr (negs r) nk in Refl

-- ---------------------------------------------------------------------
-- Settled tables
-- ---------------------------------------------------------------------

--@spec [IRET.8.1]
public export
Iret_8_1__tok_settled : Lgra_6_1__rule -> List (List Lfac_1_7_1__fact) -> List (List Lfac_1_7_1__fact) -> Iret_11__tok -> Type
Iret_8_1__tok_settled r now nf t =
  ( blocked t = iret_7_9__is_blocked_with (iret_7_9__blockers r) nf (tfacts t)
  , rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids now) = True )

--@spec [IRET.8.1]
||| Every token's blocking is current and its tuple is a current match;
||| every current match has a token.
public export
Iret_8_1__settled : Lgra_6_1__rule -> List (List Lfac_1_7_1__fact) -> List (List Lfac_1_7_1__fact) -> List Iret_11__tok -> Type
Iret_8_1__settled r now nf ts =
  ( All (Iret_8_1__tok_settled r now nf) ts
  , All (\fs => rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids ts) = True) now )

--@derives [LDET.5.9]
export
ldet_5_9__refresh_with_settled : (blk : Bool) -> (t : Iret_11__tok) -> blocked t = blk -> ldet_5_9__refresh_with blk t = t
ldet_5_9__refresh_with_settled True (MkTok fs fr True) eq = Refl
ldet_5_9__refresh_with_settled False (MkTok fs fr False) eq = Refl
ldet_5_9__refresh_with_settled True (MkTok fs fr False) eq = absurd eq
ldet_5_9__refresh_with_settled False (MkTok fs fr True) eq = absurd eq

--@derives [LDET.5.9]
export
ldet_5_9__refresh_settled : (r : Lgra_6_1__rule) -> (nf : List (List Lfac_1_7_1__fact)) -> (t : Iret_11__tok) ->
                 blocked t = iret_7_9__is_blocked_with (iret_7_9__blockers r) nf (tfacts t) -> ldet_5_9__refresh_tok r nf t = t
ldet_5_9__refresh_settled r nf t eq = ldet_5_9__refresh_with_settled (iret_7_9__is_blocked_with (iret_7_9__blockers r) nf (tfacts t)) t eq

--@derives [IRET.8.1]
export
iret_8_1__settled_fixed : (r : Lgra_6_1__rule) -> (now, nf : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) ->
               Iret_8_1__settled r now nf ts -> rarc_5_6_5__prop_with r now nf ts = ts
iret_8_1__settled_fixed r now nf ts (allT, allN) =
  rewrite lcyc_1_1__filter_all_true (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids now)) ts (lcyc_1_1__all_imp ts (\t, p => snd p) allT) in
  rewrite lcyc_1_1__filter_all_false (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids ts))) now
            (lcyc_1_1__all_imp now (\fs, p => rewrite p in Refl) allN) in
  rewrite appendNilRightNeutral ts in
  lcyc_1_1__map_id_all (ldet_5_9__refresh_tok r nf) ts (lcyc_1_1__all_imp ts (\t, p => ldet_5_9__refresh_settled r nf t (fst p)) allT)

--@derives [IRET.8.1]
export
iret_8_1__kept_ok : (now : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) -> All (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids now) = True) (iret_8_1__kept_of now ts)
iret_8_1__kept_ok now ts = lcyc_1_1__all_from_elem (iret_8_1__kept_of now ts)
                  (\t, e => snd (lcyc_1_1__elem_filter_inv (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids now)) ts e))

--@derives [IRET.8.1]
export
iret_8_1__added_ok : (now : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) -> All (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids now) = True) (iret_8_1__added_of now ts)
iret_8_1__added_ok now ts =
  lcyc_1_1__all_map iret_8_1__fresh_tok
    (lcyc_1_1__all_from_elem (filter (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids ts))) now)
      (\fs, e => lcyc_1_1__elem_ll_true (iret_11_3__fact_ids fs) (iret_11_3__now_ids now)
                   (lcyc_1_1__elem_map_fwd iret_11_3__fact_ids (fst (lcyc_1_1__elem_filter_inv (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids ts))) now e)))))

--@derives [IRET.8.1]
export
iret_8_1__in_result : (r : Lgra_6_1__rule) -> (now, nf : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) -> (t : Iret_11__tok) ->
           Elem t (iret_8_1__kept_of now ts ++ iret_8_1__added_of now ts) -> rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__tok_ids (rarc_5_6_5__prop_with r now nf ts)) = True
iret_8_1__in_result r now nf ts t e = lcyc_1_1__elem_ll_true (iret_11_3__ids t) (iret_11_3__tok_ids (rarc_5_6_5__prop_with r now nf ts))
                             (lcyc_1_1__elem_map_fwd iret_11_3__ids (lcyc_1_1__elem_map_fwd (ldet_5_9__refresh_tok r nf) e))

--@derives [IRET.8.1]
export
iret_8_1__now_in_result : (r : Lgra_6_1__rule) -> (now, nf : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) ->
              (fs : List Lfac_1_7_1__fact) -> Elem fs now -> rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids (rarc_5_6_5__prop_with r now nf ts)) = True
iret_8_1__now_in_result r now nf ts fs e with (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids ts)) proof old
  iret_8_1__now_in_result r now nf ts fs e | True =
    let (t ** (te, teq)) = lcyc_1_1__elem_map_inv iret_11_3__ids ts (lcyc_1_1__elem_ll_elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids ts) old)
        inKept : Elem t (iret_8_1__kept_of now ts)
        inKept = lcyc_1_1__elem_filter_fwd (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids now)) ts te
                   (rewrite teq in lcyc_1_1__elem_ll_true (iret_11_3__fact_ids fs) (iret_11_3__now_ids now) (lcyc_1_1__elem_map_fwd iret_11_3__fact_ids e))
    in rewrite sym teq in iret_8_1__in_result r now nf ts t (lcyc_1_1__elem_append_left inKept)
  iret_8_1__now_in_result r now nf ts fs e | False =
    let inAdded : Elem (iret_8_1__fresh_tok fs) (iret_8_1__added_of now ts)
        inAdded = lcyc_1_1__elem_map_fwd iret_8_1__fresh_tok
                    (lcyc_1_1__elem_filter_fwd (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids ts))) now e (rewrite old in Refl))
    in iret_8_1__in_result r now nf ts (iret_8_1__fresh_tok fs) (lcyc_1_1__elem_append_right (iret_8_1__kept_of now ts) inAdded)

--@derives [IRET.8.1]
||| The result of re-propagation is settled.
export
iret_8_1__prop_with_settled : (r : Lgra_6_1__rule) -> (now, nf : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) ->
                  Iret_8_1__settled r now nf (rarc_5_6_5__prop_with r now nf ts)
iret_8_1__prop_with_settled r now nf ts =
  ( lcyc_1_1__all_map (ldet_5_9__refresh_tok r nf)
      (lcyc_1_1__all_imp (iret_8_1__kept_of now ts ++ iret_8_1__added_of now ts) (\t, p => (Refl, p)) (lcyc_1_1__all_append (iret_8_1__kept_ok now ts) (iret_8_1__added_ok now ts)))
  , lcyc_1_1__all_from_elem now (iret_8_1__now_in_result r now nf ts) )

--@derives [IDAT.6.2.2]
export
idat_6_2_2__mark_settled : (r : Lgra_6_1__rule) -> (now, nf : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) -> (j : Nat) ->
              Iret_8_1__settled r now nf ts -> Iret_8_1__settled r now nf (idat_6_2_2__mark_at j ts)
idat_6_2_2__mark_settled r now nf ts j (allT, allN) =
  ( lcyc_1_1__all_set_at idat_6_2_2__mark_t (\t, p => p) j ts allT
  , rewrite lcyc_1_1__map_set_at idat_6_2_2__mark_t iret_11_3__ids (\t => Refl) j ts in allN )

-- ---------------------------------------------------------------------
-- Selection and the pop
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__zero_not_succ : Z = S j -> Void
lcyc_1_1__zero_not_succ Refl impossible

--@derives [LDET.5.5]
export
ldet_5_5__first_pending_ok : (ts : List Iret_11__tok) -> (j : Nat) -> ldet_5_5__first_pending ts = Just j ->
                 (t ** (rarc_5_6_5__nth j ts = Just t, iret_11_3_1__pending_tok t = True))
ldet_5_5__first_pending_ok [] j prf = absurd prf
ldet_5_5__first_pending_ok (t :: ts) j prf with (iret_11_3_1__pending_tok t) proof pt
  ldet_5_5__first_pending_ok (t :: ts) Z prf | True = (t ** (Refl, pt))
  ldet_5_5__first_pending_ok (t :: ts) (S j) prf | True = absurd (lcyc_1_1__zero_not_succ (lcyc_1_1__just_injective prf))
  ldet_5_5__first_pending_ok (t :: ts) j prf | False with (ldet_5_5__first_pending ts) proof fp
    ldet_5_5__first_pending_ok (t :: ts) j prf | False | Nothing = absurd prf
    ldet_5_5__first_pending_ok (t :: ts) j prf | False | (Just j') =
      let (t' ** (nj, pt')) = ldet_5_5__first_pending_ok ts j' fp
      in rewrite sym (lcyc_1_1__just_injective prf) in (t' ** (nj, pt'))

--@derives [LDET.5.1]
export
ldet_5_1__select_next_pending : (tables : List (List Iret_11__tok)) -> (r, j : Nat) -> ldet_5_1__select_next tables = Just (r, j) ->
                    (ts ** (t ** (rarc_5_6_5__nth r tables = Just ts, rarc_5_6_5__nth j ts = Just t, iret_11_3_1__pending_tok t = True)))
ldet_5_1__select_next_pending [] r j prf = absurd prf
ldet_5_1__select_next_pending (ts :: tss) r j prf with (ldet_5_5__first_pending ts) proof fp
  ldet_5_1__select_next_pending (ts :: tss) r j prf | (Just j0) =
    let (rEq, jEq) = lcyc_1_1__pair_just prf
        (t ** (nj, pt)) = ldet_5_5__first_pending_ok ts j0 fp
    in rewrite sym rEq in rewrite sym jEq in (ts ** (t ** (Refl, nj, pt)))
  ldet_5_1__select_next_pending (ts :: tss) r j prf | Nothing with (ldet_5_1__select_next tss) proof sn
    ldet_5_1__select_next_pending (ts :: tss) r j prf | Nothing | Nothing = absurd prf
    ldet_5_1__select_next_pending (ts :: tss) r j prf | Nothing | (Just (r', j')) =
      let (rEq, jEq) = lcyc_1_1__pair_just prf
          (ts' ** (t ** (nr, nj, pt))) = ldet_5_1__select_next_pending tss r' j' sn
      in rewrite sym rEq in rewrite sym jEq in (ts' ** (t ** (nr, nj, pt)))

--@derives [IDAT.6.2.2]
export
idat_6_2_2__pending_count_mark : (j : Nat) -> (ts : List Iret_11__tok) -> (t : Iret_11__tok) -> rarc_5_6_5__nth j ts = Just t -> iret_11_3_1__pending_tok t = True ->
                   S (iret_11_3_1__pending_count (idat_6_2_2__mark_at j ts)) = iret_11_3_1__pending_count ts
idat_6_2_2__pending_count_mark Z (t :: ts) t Refl pt = rewrite pt in Refl
idat_6_2_2__pending_count_mark (S j) (u :: ts) t prf pt with (iret_11_3_1__pending_tok u)
  idat_6_2_2__pending_count_mark (S j) (u :: ts) t prf pt | True = cong S (idat_6_2_2__pending_count_mark j ts t prf pt)
  idat_6_2_2__pending_count_mark (S j) (u :: ts) t prf pt | False = idat_6_2_2__pending_count_mark j ts t prf pt

-- ---------------------------------------------------------------------
-- Well-formed tokens out of re-propagation
-- ---------------------------------------------------------------------

--@spec [IRET.7.4]
public export
Iret_7_4__tok_ok : Lgra_6_1__rule -> List (Nat, Nat) -> Iret_11__tok -> Type
Iret_7_4__tok_ok r dom t = (lcyc_3_2_2__kinds_of (tfacts t) = posKinds r, All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts t))

--@spec [IRET.7.4]
public export
Iret_7_4__tuple_ok : Lgra_6_1__rule -> List (Nat, Nat) -> List Lfac_1_7_1__fact -> Type
Iret_7_4__tuple_ok r dom fs = (lcyc_3_2_2__kinds_of fs = posKinds r, All (\f => Elem (lfac_2_5_1__val f) dom) fs)

--@derives [RARC.5.6.4]
export
rarc_5_6_4__all_facts_of_kind : (k : Nat) -> (w : Rarc_5_6_4__wm) -> All (\f => fkind f = k) (rarc_5_6_4__facts_of_kind k w)
rarc_5_6_4__all_facts_of_kind k [] = []
rarc_5_6_4__all_facts_of_kind k (g :: gs) with (fkind g == k) proof gk
  rarc_5_6_4__all_facts_of_kind k (g :: gs) | True = lcyc_1_1__nat_eq_true (fkind g) k gk :: rarc_5_6_4__all_facts_of_kind k gs
  rarc_5_6_4__all_facts_of_kind k (g :: gs) | False = rarc_5_6_4__all_facts_of_kind k gs

--@derives [IRET.7.4]
export
iret_7_4__tuples_kinds : (ks : List Nat) -> (w : Rarc_5_6_4__wm) -> All (\fs => lcyc_3_2_2__kinds_of fs = ks) (iret_7_4__tuples ks w)
iret_7_4__tuples_kinds [] w = [Refl]
iret_7_4__tuples_kinds (k :: ks) w =
  lcyc_1_1__all_concat_map (\f => map (f ::) (iret_7_4__tuples ks w)) (rarc_5_6_4__facts_of_kind k w)
    (lcyc_1_1__all_imp (rarc_5_6_4__facts_of_kind k w)
       (\f, fk => lcyc_1_1__all_map (f ::)
           (lcyc_1_1__all_imp (iret_7_4__tuples ks w) (\fs, eq => rewrite fk in rewrite eq in Refl) (iret_7_4__tuples_kinds ks w)))
       (rarc_5_6_4__all_facts_of_kind k w))

--@derives [IRET.7.4]
export
iret_7_4__tuples_dom : (dom : List (Nat, Nat)) -> (ks : List Nat) -> (w : Rarc_5_6_4__wm) -> All (\f => Elem (lfac_2_5_1__val f) dom) w ->
            All (\fs => All (\f => Elem (lfac_2_5_1__val f) dom) fs) (iret_7_4__tuples ks w)
iret_7_4__tuples_dom dom [] w wd = [[]]
iret_7_4__tuples_dom dom (k :: ks) w wd =
  lcyc_1_1__all_concat_map (\f => map (f ::) (iret_7_4__tuples ks w)) (rarc_5_6_4__facts_of_kind k w)
    (lcyc_1_1__all_imp (rarc_5_6_4__facts_of_kind k w)
       (\f, fd => lcyc_1_1__all_map (f ::) (lcyc_1_1__all_imp (iret_7_4__tuples ks w) (\fs, fsd => fd :: fsd) (iret_7_4__tuples_dom dom ks w wd)))
       (lcyc_1_1__all_filter (\f => fkind f == k) w wd))

--@derives [IRET.7.4]
export
iret_7_4__match_tuples_ok : (r : Lgra_6_1__rule) -> (dom : List (Nat, Nat)) -> (w : Rarc_5_6_4__wm) -> All (\f => Elem (lfac_2_5_1__val f) dom) w ->
                All (Iret_7_4__tuple_ok r dom) (iret_7_4__match_tuples r w)
iret_7_4__match_tuples_ok r dom w wd =
  lcyc_1_1__all_filter (guard r) (iret_7_4__tuples (posKinds r) w)
    (lcyc_1_1__all_zip (iret_7_4__tuples (posKinds r) w) (iret_7_4__tuples_kinds (posKinds r) w) (iret_7_4__tuples_dom dom (posKinds r) w wd))

--@derives [IRET.7.4]
export
iret_7_4__prop_with_ok : (r : Lgra_6_1__rule) -> (dom : List (Nat, Nat)) -> (now, nf : List (List Lfac_1_7_1__fact)) -> (old : List Iret_11__tok) ->
             All (Iret_7_4__tok_ok r dom) old -> All (Iret_7_4__tuple_ok r dom) now ->
             All (Iret_7_4__tok_ok r dom) (rarc_5_6_5__prop_with r now nf old)
iret_7_4__prop_with_ok r dom now nf old oldOk nowOk =
  lcyc_1_1__all_map (ldet_5_9__refresh_tok r nf)
    (lcyc_1_1__all_append (lcyc_1_1__all_filter (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids now)) old oldOk)
               (lcyc_1_1__all_map iret_8_1__fresh_tok
                  (lcyc_1_1__all_filter (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) now nowOk)))

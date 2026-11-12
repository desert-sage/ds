-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Library lemmas for Lcyc/Certificate.idr: Bool/Nat equality bridging,
||| list and sum lemmas, `rarc_5_6_5__nth`/`rarc_5_6_5__set_at` lemmas, and the working-memory
||| "frame" lemmas — a change confined to one kind leaves every other
||| kind's facts, counts and headroom untouched.
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr:
||| clause-named elements and `--@spec` / `--@derives` markers. A library
||| lemma that exists only for the [LCYC.1.1] termination proof is named
||| under that clause;
||| a working-memory lemma under [RARC.5.6.4]; a dedup lemma under
||| [LFAC.2.5.1].
module Lcyc.Lemmas

import Rete.FireLoop
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- Nat / Bool bridging
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__nat_eq_true : (a, b : Nat) -> (a == b) = True -> a = b
lcyc_1_1__nat_eq_true Z Z _ = Refl
lcyc_1_1__nat_eq_true Z (S _) prf = absurd prf
lcyc_1_1__nat_eq_true (S _) Z prf = absurd prf
lcyc_1_1__nat_eq_true (S a) (S b) prf = cong S (lcyc_1_1__nat_eq_true a b prf)

--@derives [LCYC.1.1]
export
lcyc_1_1__nat_eq_refl : (a : Nat) -> (a == a) = True
lcyc_1_1__nat_eq_refl Z = Refl
lcyc_1_1__nat_eq_refl (S a) = lcyc_1_1__nat_eq_refl a

--@derives [LCYC.1.1]
export
lcyc_1_1__nat_eq_false : (a, b : Nat) -> Not (a = b) -> (a == b) = False
lcyc_1_1__nat_eq_false a b neq with (a == b) proof p
  lcyc_1_1__nat_eq_false a b neq | True = absurd (neq (lcyc_1_1__nat_eq_true a b p))
  lcyc_1_1__nat_eq_false a b neq | False = Refl

--@derives [LCYC.1.1]
export
lcyc_1_1__nat_neq_false : (a, b : Nat) -> (a == b) = False -> Not (a = b)
lcyc_1_1__nat_neq_false a a prf Refl = absurd (trans (sym (lcyc_1_1__nat_eq_refl a)) prf)

--@derives [LCYC.1.1]
export
lcyc_1_1__and_true_l : (a, b : Bool) -> (a && b) = True -> a = True
lcyc_1_1__and_true_l True b prf = Refl
lcyc_1_1__and_true_l False b prf = absurd prf

--@derives [LCYC.1.1]
export
lcyc_1_1__and_true_r : (a, b : Bool) -> (a && b) = True -> b = True
lcyc_1_1__and_true_r True b prf = prf
lcyc_1_1__and_true_r False b prf = absurd prf

--@derives [LCYC.1.1]
export
lcyc_1_1__and_false_l : (a, b : Bool) -> a = False -> (a && b) = False
lcyc_1_1__and_false_l False b _ = Refl
lcyc_1_1__and_false_l True b prf = absurd prf

--@derives [LCYC.1.1]
export
lcyc_1_1__and_false_r : (a, b : Bool) -> b = False -> (a && b) = False
lcyc_1_1__and_false_r True b prf = prf
lcyc_1_1__and_false_r False b _ = Refl

--@derives [LCYC.1.1]
export
lcyc_1_1__not_true_is_false : (b : Bool) -> not b = True -> b = False
lcyc_1_1__not_true_is_false False _ = Refl
lcyc_1_1__not_true_is_false True prf = absurd prf

--@derives [LCYC.1.1]
export
lcyc_1_1__not_false_is_true : (b : Bool) -> not b = False -> b = True
lcyc_1_1__not_false_is_true True _ = Refl
lcyc_1_1__not_false_is_true False prf = absurd prf

--@derives [LCYC.1.1]
export
lcyc_1_1__bool_not_both : (b : Bool) -> b = True -> b = False -> Void
lcyc_1_1__bool_not_both True _ prf = absurd prf
lcyc_1_1__bool_not_both False prf _ = absurd prf

--@derives [LFAC.2.5.4]
export
lfac_2_5_4__same_fact_kind : (g, f : Lfac_1_7_1__fact) -> lfac_2_5_4__same_fact g f = True -> fkind g = fkind f
lfac_2_5_4__same_fact_kind g f prf =
  lcyc_1_1__nat_eq_true (fkind g) (fkind f)
    (lcyc_1_1__and_true_l (fkind g == fkind f) _
      (lcyc_1_1__and_true_r (fid g == fid f) _ prf))

--@derives [LFAC.2.5.1]
export
lfac_2_5_1__same_val_refl : (v : (Nat, Nat)) -> lfac_2_5_1__same_val v v = True
lfac_2_5_1__same_val_refl (a, b) = rewrite lcyc_1_1__nat_eq_refl a in lcyc_1_1__nat_eq_refl b

-- ---------------------------------------------------------------------
-- List lemmas
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__filter_ext : (p, q : a -> Bool) -> ((x : a) -> p x = q x) -> (xs : List a) ->
            filter p xs = filter q xs
lcyc_1_1__filter_ext p q ext [] = Refl
lcyc_1_1__filter_ext p q ext (x :: xs) with (p x) proof px
  lcyc_1_1__filter_ext p q ext (x :: xs) | True =
    rewrite sym (ext x) in rewrite px in cong (x ::) (lcyc_1_1__filter_ext p q ext xs)
  lcyc_1_1__filter_ext p q ext (x :: xs) | False =
    rewrite sym (ext x) in rewrite px in lcyc_1_1__filter_ext p q ext xs

--@derives [LCYC.1.1]
||| Survivors of a stronger predicate are no more numerous.
export
lcyc_1_1__filter_lte : (p, q : a -> Bool) -> ((x : a) -> q x = True -> p x = True) -> (xs : List a) ->
            LTE (length (filter q xs)) (length (filter p xs))
lcyc_1_1__filter_lte p q imp [] = LTEZero
lcyc_1_1__filter_lte p q imp (x :: xs) with (q x) proof qx
  lcyc_1_1__filter_lte p q imp (x :: xs) | True =
    rewrite imp x qx in LTESucc (lcyc_1_1__filter_lte p q imp xs)
  lcyc_1_1__filter_lte p q imp (x :: xs) | False with (p x)
    lcyc_1_1__filter_lte p q imp (x :: xs) | False | True = lteSuccRight (lcyc_1_1__filter_lte p q imp xs)
    lcyc_1_1__filter_lte p q imp (x :: xs) | False | False = lcyc_1_1__filter_lte p q imp xs

--@derives [LCYC.1.1]
||| Strictly fewer, when the stronger predicate drops an element the
||| weaker one keeps.
export
lcyc_1_1__filter_strict : (p, q : a -> Bool) -> ((x : a) -> q x = True -> p x = True) -> (xs : List a) ->
               (x0 : a) -> Elem x0 xs -> p x0 = True -> q x0 = False ->
               LT (length (filter q xs)) (length (filter p xs))
lcyc_1_1__filter_strict p q imp (x0 :: xs) x0 Here px qx =
  rewrite px in rewrite qx in LTESucc (lcyc_1_1__filter_lte p q imp xs)
lcyc_1_1__filter_strict p q imp (x :: xs) x0 (There e) px qx with (q x) proof qxx
  lcyc_1_1__filter_strict p q imp (x :: xs) x0 (There e) px qx | True =
    rewrite imp x qxx in LTESucc (lcyc_1_1__filter_strict p q imp xs x0 e px qx)
  lcyc_1_1__filter_strict p q imp (x :: xs) x0 (There e) px qx | False with (p x)
    lcyc_1_1__filter_strict p q imp (x :: xs) x0 (There e) px qx | False | True =
      lteSuccRight (lcyc_1_1__filter_strict p q imp xs x0 e px qx)
    lcyc_1_1__filter_strict p q imp (x :: xs) x0 (There e) px qx | False | False =
      lcyc_1_1__filter_strict p q imp xs x0 e px qx

--@derives [LCYC.1.1]
export
lcyc_1_1__all_filter : (p : a -> Bool) -> (xs : List a) -> All prop xs -> All prop (filter p xs)
lcyc_1_1__all_filter p [] [] = []
lcyc_1_1__all_filter p (x :: xs) (px :: pxs) with (p x)
  lcyc_1_1__all_filter p (x :: xs) (px :: pxs) | True = px :: lcyc_1_1__all_filter p xs pxs
  lcyc_1_1__all_filter p (x :: xs) (px :: pxs) | False = lcyc_1_1__all_filter p xs pxs

--@derives [LCYC.1.1]
export
lcyc_1_1__all_append : All prop xs -> All prop ys -> All prop (xs ++ ys)
lcyc_1_1__all_append [] pys = pys
lcyc_1_1__all_append (px :: pxs) pys = px :: lcyc_1_1__all_append pxs pys

--@derives [LCYC.1.1]
export
lcyc_1_1__all_map : (f : a -> b) -> All (\x => prop (f x)) xs -> All prop (map f xs)
lcyc_1_1__all_map f [] = []
lcyc_1_1__all_map f (px :: pxs) = px :: lcyc_1_1__all_map f pxs

--@derives [LCYC.1.1]
export
lcyc_1_1__all_lookup : All prop xs -> Elem x xs -> prop x
lcyc_1_1__all_lookup (px :: pxs) Here = px
lcyc_1_1__all_lookup (px :: pxs) (There e) = lcyc_1_1__all_lookup pxs e

--@derives [LCYC.1.1]
export
lcyc_1_1__all_from_elem : (xs : List a) -> ((x : a) -> Elem x xs -> prop x) -> All prop xs
lcyc_1_1__all_from_elem [] f = []
lcyc_1_1__all_from_elem (x :: xs) f = f x Here :: lcyc_1_1__all_from_elem xs (\y, e => f y (There e))

--@derives [LCYC.1.1]
export
lcyc_1_1__all_map_maybe : (f : a -> Maybe b) -> (xs : List a) -> All prop xs ->
              ((x : a) -> (y : b) -> prop x -> f x = Just y -> prop' y) ->
              All prop' (mapMaybe f xs)
lcyc_1_1__all_map_maybe f [] [] step = []
lcyc_1_1__all_map_maybe f (x :: xs) (px :: pxs) step with (f x) proof fx
  lcyc_1_1__all_map_maybe f (x :: xs) (px :: pxs) step | Nothing = lcyc_1_1__all_map_maybe f xs pxs step
  lcyc_1_1__all_map_maybe f (x :: xs) (px :: pxs) step | (Just y) =
    step x y px fx :: lcyc_1_1__all_map_maybe f xs pxs step

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_append_left : Elem x xs -> Elem x (xs ++ ys)
lcyc_1_1__elem_append_left Here = Here
lcyc_1_1__elem_append_left (There e) = There (lcyc_1_1__elem_append_left e)

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_append_right : (xs : List a) -> Elem x ys -> Elem x (xs ++ ys)
lcyc_1_1__elem_append_right [] e = e
lcyc_1_1__elem_append_right (_ :: xs) e = There (lcyc_1_1__elem_append_right xs e)

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_map_inv : (f : a -> b) -> (xs : List a) -> Elem y (map f xs) -> (x ** (Elem x xs, f x = y))
lcyc_1_1__elem_map_inv f (x :: xs) Here = (x ** (Here, Refl))
lcyc_1_1__elem_map_inv f (x :: xs) (There e) =
  let (x' ** (e', eq)) = lcyc_1_1__elem_map_inv f xs e in (x' ** (There e', eq))

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_map_fwd : (f : a -> b) -> Elem x xs -> Elem (f x) (map f xs)
lcyc_1_1__elem_map_fwd f Here = Here
lcyc_1_1__elem_map_fwd f (There e) = There (lcyc_1_1__elem_map_fwd f e)

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_filter_fwd : (p : a -> Bool) -> (xs : List a) -> Elem x xs -> p x = True -> Elem x (filter p xs)
lcyc_1_1__elem_filter_fwd p (x :: xs) Here px = rewrite px in Here
lcyc_1_1__elem_filter_fwd p (y :: xs) (There e) px with (p y)
  lcyc_1_1__elem_filter_fwd p (y :: xs) (There e) px | True = There (lcyc_1_1__elem_filter_fwd p xs e px)
  lcyc_1_1__elem_filter_fwd p (y :: xs) (There e) px | False = lcyc_1_1__elem_filter_fwd p xs e px

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_filter_inv : (p : a -> Bool) -> (xs : List a) -> Elem x (filter p xs) -> (Elem x xs, p x = True)
lcyc_1_1__elem_filter_inv p [] e = absurd e
lcyc_1_1__elem_filter_inv p (y :: xs) e with (p y) proof py
  lcyc_1_1__elem_filter_inv p (y :: xs) Here | True = (Here, py)
  lcyc_1_1__elem_filter_inv p (y :: xs) (There e) | True =
    let (e', px) = lcyc_1_1__elem_filter_inv p xs e in (There e', px)
  lcyc_1_1__elem_filter_inv p (y :: xs) e | False =
    let (e', px) = lcyc_1_1__elem_filter_inv p xs e in (There e', px)

--@derives [LCYC.1.1]
||| Bool membership on Nat lists, both directions.
export
lcyc_1_1__elem_l_true : (x : Nat) -> (xs : List Nat) -> Elem x xs -> rarc_5_6_5__elem x xs = True
lcyc_1_1__elem_l_true x (x :: xs) Here = rewrite lcyc_1_1__nat_eq_refl x in Refl
lcyc_1_1__elem_l_true x (y :: xs) (There e) with (y == x)
  lcyc_1_1__elem_l_true x (y :: xs) (There e) | True = Refl
  lcyc_1_1__elem_l_true x (y :: xs) (There e) | False = lcyc_1_1__elem_l_true x xs e

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_l_elem : (x : Nat) -> (xs : List Nat) -> rarc_5_6_5__elem x xs = True -> Elem x xs
lcyc_1_1__elem_l_elem x [] prf = absurd prf
lcyc_1_1__elem_l_elem x (y :: xs) prf with (y == x) proof yx
  lcyc_1_1__elem_l_elem x (y :: xs) prf | True = rewrite sym (lcyc_1_1__nat_eq_true y x yx) in Here
  lcyc_1_1__elem_l_elem x (y :: xs) prf | False = There (lcyc_1_1__elem_l_elem x xs prf)

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_l_false_not : (x : Nat) -> (xs : List Nat) -> rarc_5_6_5__elem x xs = False -> Elem x xs -> Void
lcyc_1_1__elem_l_false_not x xs prf e = lcyc_1_1__bool_not_both (rarc_5_6_5__elem x xs) (lcyc_1_1__elem_l_true x xs e) prf

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_l_append_left : (x : Nat) -> (xs, ys : List Nat) -> rarc_5_6_5__elem x xs = True -> rarc_5_6_5__elem x (xs ++ ys) = True
lcyc_1_1__elem_l_append_left x xs ys prf = lcyc_1_1__elem_l_true x (xs ++ ys) (lcyc_1_1__elem_append_left (lcyc_1_1__elem_l_elem x xs prf))

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_l_append_right : (x : Nat) -> (xs, ys : List Nat) -> rarc_5_6_5__elem x ys = True -> rarc_5_6_5__elem x (xs ++ ys) = True
lcyc_1_1__elem_l_append_right x xs ys prf = lcyc_1_1__elem_l_true x (xs ++ ys) (lcyc_1_1__elem_append_right xs (lcyc_1_1__elem_l_elem x ys prf))

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_append_inv : (xs : List a) -> Elem x (xs ++ ys) -> Either (Elem x xs) (Elem x ys)
lcyc_1_1__elem_append_inv [] e = Right e
lcyc_1_1__elem_append_inv (y :: xs) Here = Left Here
lcyc_1_1__elem_append_inv (y :: xs) (There e) = case lcyc_1_1__elem_append_inv xs e of
  Left e'  => Left (There e')
  Right e' => Right e'

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_l_append_inv : (x : Nat) -> (xs, ys : List Nat) -> rarc_5_6_5__elem x (xs ++ ys) = True ->
                 Either (rarc_5_6_5__elem x xs = True) (rarc_5_6_5__elem x ys = True)
lcyc_1_1__elem_l_append_inv x xs ys prf = case lcyc_1_1__elem_append_inv xs (lcyc_1_1__elem_l_elem x (xs ++ ys) prf) of
  Left e  => Left (lcyc_1_1__elem_l_true x xs e)
  Right e => Right (lcyc_1_1__elem_l_true x ys e)

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_concat_map : (f : a -> List Nat) -> (ys : List a) -> Elem y ys -> (k : Nat) ->
                 rarc_5_6_5__elem k (f y) = True -> rarc_5_6_5__elem k (rarc_5_6_5__concat_map f ys) = True
lcyc_1_1__elem_concat_map f (y :: ys) Here k prf = lcyc_1_1__elem_l_append_left k (f y) (rarc_5_6_5__concat_map f ys) prf
lcyc_1_1__elem_concat_map f (y :: ys) (There e) k prf =
  lcyc_1_1__elem_l_append_right k (f y) (rarc_5_6_5__concat_map f ys) (lcyc_1_1__elem_concat_map f ys e k prf)

--@derives [LCYC.1.1]
export
lcyc_1_1__elem_concat_map_inv : (f : a -> List Nat) -> (ys : List a) -> (k : Nat) ->
                    rarc_5_6_5__elem k (rarc_5_6_5__concat_map f ys) = True -> (y ** (Elem y ys, rarc_5_6_5__elem k (f y) = True))
lcyc_1_1__elem_concat_map_inv f [] k prf = absurd prf
lcyc_1_1__elem_concat_map_inv f (y :: ys) k prf = case lcyc_1_1__elem_l_append_inv k (f y) (rarc_5_6_5__concat_map f ys) prf of
  Left here  => (y ** (Here, here))
  Right rest => let (y' ** (e, p)) = lcyc_1_1__elem_concat_map_inv f ys k rest in (y' ** (There e, p))

--@derives [LCYC.1.1]
export
lcyc_1_1__any_append_l : (p : a -> Bool) -> (xs, ys : List a) -> rarc_5_6_5__any p xs = True -> rarc_5_6_5__any p (xs ++ ys) = True
lcyc_1_1__any_append_l p [] ys prf = absurd prf
lcyc_1_1__any_append_l p (x :: xs) ys prf with (p x)
  lcyc_1_1__any_append_l p (x :: xs) ys prf | True = Refl
  lcyc_1_1__any_append_l p (x :: xs) ys prf | False = lcyc_1_1__any_append_l p xs ys prf

--@derives [LCYC.1.1]
export
lcyc_1_1__any_append_r : (p : a -> Bool) -> (xs, ys : List a) -> rarc_5_6_5__any p ys = True -> rarc_5_6_5__any p (xs ++ ys) = True
lcyc_1_1__any_append_r p [] ys prf = prf
lcyc_1_1__any_append_r p (x :: xs) ys prf with (p x)
  lcyc_1_1__any_append_r p (x :: xs) ys prf | True = Refl
  lcyc_1_1__any_append_r p (x :: xs) ys prf | False = lcyc_1_1__any_append_r p xs ys prf

--@derives [LCYC.1.1]
export
lcyc_1_1__any_elem : (p : a -> Bool) -> (xs : List a) -> Elem x xs -> p x = True -> rarc_5_6_5__any p xs = True
lcyc_1_1__any_elem p (x :: xs) Here px = rewrite px in Refl
lcyc_1_1__any_elem p (y :: xs) (There e) px with (p y)
  lcyc_1_1__any_elem p (y :: xs) (There e) px | True = Refl
  lcyc_1_1__any_elem p (y :: xs) (There e) px | False = lcyc_1_1__any_elem p xs e px

--@derives [LCYC.1.1]
export
lcyc_1_1__any_false_all : (p : a -> Bool) -> (xs : List a) -> rarc_5_6_5__any p xs = False -> All (\x => p x = False) xs
lcyc_1_1__any_false_all p [] prf = []
lcyc_1_1__any_false_all p (x :: xs) prf with (p x) proof px
  lcyc_1_1__any_false_all p (x :: xs) prf | True = absurd prf
  lcyc_1_1__any_false_all p (x :: xs) prf | False = px :: lcyc_1_1__any_false_all p xs prf

-- ---------------------------------------------------------------------
-- sumBy
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__sum_by_ext : (f, g : a -> Nat) -> (xs : List a) -> All (\x => f x = g x) xs -> lcyc_1_1__sum_by f xs = lcyc_1_1__sum_by g xs
lcyc_1_1__sum_by_ext f g [] [] = Refl
lcyc_1_1__sum_by_ext f g (x :: xs) (px :: pxs) = rewrite px in cong (g x +) (lcyc_1_1__sum_by_ext f g xs pxs)

--@derives [LCYC.1.1]
export
lcyc_1_1__sum_by_lte : (f, g : a -> Nat) -> (xs : List a) -> All (\x => LTE (g x) (f x)) xs -> LTE (lcyc_1_1__sum_by g xs) (lcyc_1_1__sum_by f xs)
lcyc_1_1__sum_by_lte f g [] [] = LTEZero
lcyc_1_1__sum_by_lte f g (x :: xs) (px :: pxs) = plusLteMonotone px (lcyc_1_1__sum_by_lte f g xs pxs)

--@derives [LCYC.1.1]
export
lcyc_1_1__sum_by_strict : (f, g : a -> Nat) -> (xs : List a) -> All (\x => LTE (g x) (f x)) xs ->
              (x0 : a) -> Elem x0 xs -> LT (g x0) (f x0) -> LT (lcyc_1_1__sum_by g xs) (lcyc_1_1__sum_by f xs)
lcyc_1_1__sum_by_strict f g (x0 :: xs) (px :: pxs) x0 Here lt =
  plusLteMonotone lt (lcyc_1_1__sum_by_lte f g xs pxs)
lcyc_1_1__sum_by_strict f g (x :: xs) (px :: pxs) x0 (There e) lt =
  rewrite plusSuccRightSucc (g x) (lcyc_1_1__sum_by g xs) in
  plusLteMonotone px (lcyc_1_1__sum_by_strict f g xs pxs x0 e lt)

-- ---------------------------------------------------------------------
-- nth / setAt / zipWith
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__nth_elem : (i : Nat) -> (xs : List a) -> rarc_5_6_5__nth i xs = Just x -> Elem x xs
lcyc_1_1__nth_elem Z (y :: xs) Refl = Here
lcyc_1_1__nth_elem (S n) (y :: xs) prf = There (lcyc_1_1__nth_elem n xs prf)

--@derives [LCYC.1.1]
export
lcyc_1_1__nth_map : (f : a -> b) -> (i : Nat) -> (xs : List a) -> rarc_5_6_5__nth i (map f xs) = map f (rarc_5_6_5__nth i xs)
lcyc_1_1__nth_map f _ [] = Refl
lcyc_1_1__nth_map f Z (x :: xs) = Refl
lcyc_1_1__nth_map f (S n) (x :: xs) = lcyc_1_1__nth_map f n xs

--@derives [LCYC.1.1]
export
lcyc_1_1__nth_set_at_eq : (i : Nat) -> (f : a -> a) -> (xs : List a) -> rarc_5_6_5__nth i (rarc_5_6_5__set_at i f xs) = map f (rarc_5_6_5__nth i xs)
lcyc_1_1__nth_set_at_eq _ f [] = Refl
lcyc_1_1__nth_set_at_eq Z f (x :: xs) = Refl
lcyc_1_1__nth_set_at_eq (S n) f (x :: xs) = lcyc_1_1__nth_set_at_eq n f xs

--@derives [LCYC.1.1]
export
lcyc_1_1__nth_set_at_neq : (i, j : Nat) -> Not (i = j) -> (f : a -> a) -> (xs : List a) -> rarc_5_6_5__nth j (rarc_5_6_5__set_at i f xs) = rarc_5_6_5__nth j xs
lcyc_1_1__nth_set_at_neq _ _ neq f [] = Refl
lcyc_1_1__nth_set_at_neq Z Z neq f (x :: xs) = absurd (neq Refl)
lcyc_1_1__nth_set_at_neq Z (S j) neq f (x :: xs) = Refl
lcyc_1_1__nth_set_at_neq (S i) Z neq f (x :: xs) = Refl
lcyc_1_1__nth_set_at_neq (S i) (S j) neq f (x :: xs) = lcyc_1_1__nth_set_at_neq i j (\eq => neq (cong S eq)) f xs

--@derives [LCYC.1.1]
export
lcyc_1_1__length_set_at : (i : Nat) -> (f : a -> a) -> (xs : List a) -> length (rarc_5_6_5__set_at i f xs) = length xs
lcyc_1_1__length_set_at _ f [] = Refl
lcyc_1_1__length_set_at Z f (x :: xs) = Refl
lcyc_1_1__length_set_at (S n) f (x :: xs) = cong S (lcyc_1_1__length_set_at n f xs)

--@derives [LCYC.1.1]
||| Kept although the Prelude's `Injective S` instance covers it:
||| Rete/NetworkOrder.idr uses it by name.
export
lcyc_1_1__succ_inj : S m = S n -> m = n
lcyc_1_1__succ_inj Refl = Refl

--@derives [LCYC.1.1]
export
lcyc_1_1__length_zip_with : (f : a -> b -> c) -> (xs : List a) -> (ys : List b) -> length ys = length xs ->
                length (zipWith f xs ys) = length xs
lcyc_1_1__length_zip_with f [] [] _ = Refl
lcyc_1_1__length_zip_with f [] (y :: ys) prf = absurd prf
lcyc_1_1__length_zip_with f (x :: xs) [] prf = absurd prf
lcyc_1_1__length_zip_with f (x :: xs) (y :: ys) prf = cong S (lcyc_1_1__length_zip_with f xs ys (injective prf))

--@derives [LCYC.1.1]
export
lcyc_1_1__nth_zip_with_just : (f : a -> b -> c) -> (i : Nat) -> (xs : List a) -> (ys : List b) ->
                 rarc_5_6_5__nth i xs = Just x -> rarc_5_6_5__nth i ys = Just y -> rarc_5_6_5__nth i (zipWith f xs ys) = Just (f x y)
lcyc_1_1__nth_zip_with_just f Z (x :: xs) (y :: ys) Refl Refl = Refl
lcyc_1_1__nth_zip_with_just f (S n) (x :: xs) (y :: ys) px py = lcyc_1_1__nth_zip_with_just f n xs ys px py

--@derives [LCYC.1.1]
export
lcyc_1_1__nth_zip_with_nothing_r : (f : a -> b -> c) -> (i : Nat) -> (xs : List a) -> (ys : List b) ->
                     rarc_5_6_5__nth i ys = Nothing -> rarc_5_6_5__nth i (zipWith f xs ys) = Nothing
lcyc_1_1__nth_zip_with_nothing_r f _ [] ys _ = Refl
lcyc_1_1__nth_zip_with_nothing_r f _ (x :: xs) [] _ = Refl
lcyc_1_1__nth_zip_with_nothing_r f Z (x :: xs) (y :: ys) prf = absurd prf
lcyc_1_1__nth_zip_with_nothing_r f (S n) (x :: xs) (y :: ys) prf = lcyc_1_1__nth_zip_with_nothing_r f n xs ys prf

--@derives [LCYC.1.1]
||| Equal lengths: a position defined on one side is defined on the other.
export
lcyc_1_1__nth_length : (i : Nat) -> (xs : List a) -> (ys : List b) -> length ys = length xs ->
            rarc_5_6_5__nth i ys = Just y -> (x ** rarc_5_6_5__nth i xs = Just x)
lcyc_1_1__nth_length Z (x :: xs) (y :: ys) _ Refl = (x ** Refl)
lcyc_1_1__nth_length (S n) (x :: xs) (y :: ys) prf py = lcyc_1_1__nth_length n xs ys (injective prf) py
lcyc_1_1__nth_length _ [] (y :: ys) prf _ = absurd prf

--@derives [LCYC.1.1]
export
lcyc_1_1__nth_nothing_length : (i : Nat) -> (xs : List a) -> (ys : List b) -> length ys = length xs ->
                   rarc_5_6_5__nth i xs = Nothing -> rarc_5_6_5__nth i ys = Nothing
lcyc_1_1__nth_nothing_length _ [] [] _ _ = Refl
lcyc_1_1__nth_nothing_length _ [] (y :: ys) prf _ = absurd prf
lcyc_1_1__nth_nothing_length _ (x :: xs) [] prf _ = absurd prf
lcyc_1_1__nth_nothing_length Z (x :: xs) (y :: ys) _ prf = absurd prf
lcyc_1_1__nth_nothing_length (S n) (x :: xs) (y :: ys) prf px = lcyc_1_1__nth_nothing_length n xs ys (injective prf) px

-- ---------------------------------------------------------------------
-- Working-memory frame lemmas (`Rarc_5_6_4__frame` is defined in
-- Rete/FireLoop.idr beside `Rarc_5_6_4__wm`)
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.4]
export
rarc_5_6_4__frame_trans : (k : Nat) -> (a, b, c : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k a b -> Rarc_5_6_4__frame k b c -> Rarc_5_6_4__frame k a c
rarc_5_6_4__frame_trans k a b c f g k' neq = trans (g k' neq) (f k' neq)

--@derives [RARC.5.6.4]
export
rarc_5_6_4__facts_of_kind_append : (k : Nat) -> (xs, ys : Rarc_5_6_4__wm) -> rarc_5_6_4__facts_of_kind k (xs ++ ys) = rarc_5_6_4__facts_of_kind k xs ++ rarc_5_6_4__facts_of_kind k ys
rarc_5_6_4__facts_of_kind_append k [] ys = Refl
rarc_5_6_4__facts_of_kind_append k (x :: xs) ys with (fkind x == k)
  rarc_5_6_4__facts_of_kind_append k (x :: xs) ys | True = cong (x ::) (rarc_5_6_4__facts_of_kind_append k xs ys)
  rarc_5_6_4__facts_of_kind_append k (x :: xs) ys | False = rarc_5_6_4__facts_of_kind_append k xs ys

--@derives [RARC.5.6.4]
export
rarc_5_6_4__frame_append : (f : Lfac_1_7_1__fact) -> (wm : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame (fkind f) wm (wm ++ [f])
rarc_5_6_4__frame_append f wm k' neq =
  rewrite rarc_5_6_4__facts_of_kind_append k' wm [f] in
  rewrite lcyc_1_1__nat_eq_false (fkind f) k' (\eq => neq (sym eq)) in
  appendNilRightNeutral (rarc_5_6_4__facts_of_kind k' wm)

--@derives [RARC.5.6.4]
export
rarc_5_6_4__frame_remove : (f : Lfac_1_7_1__fact) -> (wm : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame (fkind f) wm (rarc_5_6_4__remove_exact f wm)
rarc_5_6_4__frame_remove f [] k' neq = Refl
rarc_5_6_4__frame_remove f (g :: gs) k' neq with (lfac_2_5_4__same_fact g f) proof sf
  rarc_5_6_4__frame_remove f (g :: gs) k' neq | True =
    rewrite lcyc_1_1__nat_eq_false (fkind g) k' (\eq => neq (trans (sym eq) (lfac_2_5_4__same_fact_kind g f sf))) in
    rarc_5_6_4__frame_remove f gs k' neq
  rarc_5_6_4__frame_remove f (g :: gs) k' neq | False with (fkind g == k')
    rarc_5_6_4__frame_remove f (g :: gs) k' neq | False | True = cong (g ::) (rarc_5_6_4__frame_remove f gs k' neq)
    rarc_5_6_4__frame_remove f (g :: gs) k' neq | False | False = rarc_5_6_4__frame_remove f gs k' neq

--@derives [RARC.5.6.4]
export
rarc_5_6_4__count_remove_lte : (f : Lfac_1_7_1__fact) -> (k : Nat) -> (wm : Rarc_5_6_4__wm) -> LTE (rarc_5_6_4__count_kind k (rarc_5_6_4__remove_exact f wm)) (rarc_5_6_4__count_kind k wm)
rarc_5_6_4__count_remove_lte f k [] = LTEZero
rarc_5_6_4__count_remove_lte f k (g :: gs) with (lfac_2_5_4__same_fact g f)
  rarc_5_6_4__count_remove_lte f k (g :: gs) | True with (fkind g == k)
    rarc_5_6_4__count_remove_lte f k (g :: gs) | True | True = lteSuccRight (rarc_5_6_4__count_remove_lte f k gs)
    rarc_5_6_4__count_remove_lte f k (g :: gs) | True | False = rarc_5_6_4__count_remove_lte f k gs
  rarc_5_6_4__count_remove_lte f k (g :: gs) | False with (fkind g == k)
    rarc_5_6_4__count_remove_lte f k (g :: gs) | False | True = LTESucc (rarc_5_6_4__count_remove_lte f k gs)
    rarc_5_6_4__count_remove_lte f k (g :: gs) | False | False = rarc_5_6_4__count_remove_lte f k gs

--@derives [RARC.5.6.4]
export
rarc_5_6_4__count_remove_lt : (f : Lfac_1_7_1__fact) -> (wm : Rarc_5_6_4__wm) -> rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) wm = True ->
                LT (rarc_5_6_4__count_kind (fkind f) (rarc_5_6_4__remove_exact f wm)) (rarc_5_6_4__count_kind (fkind f) wm)
rarc_5_6_4__count_remove_lt f [] prf = absurd prf
rarc_5_6_4__count_remove_lt f (g :: gs) prf with (lfac_2_5_4__same_fact g f) proof sf
  rarc_5_6_4__count_remove_lt f (g :: gs) prf | True =
    rewrite lfac_2_5_4__same_fact_kind g f sf in
    rewrite lcyc_1_1__nat_eq_refl (fkind f) in
    LTESucc (rarc_5_6_4__count_remove_lte f (fkind f) gs)
  rarc_5_6_4__count_remove_lt f (g :: gs) prf | False with (fkind g == fkind f)
    rarc_5_6_4__count_remove_lt f (g :: gs) prf | False | True = LTESucc (rarc_5_6_4__count_remove_lt f gs prf)
    rarc_5_6_4__count_remove_lt f (g :: gs) prf | False | False = rarc_5_6_4__count_remove_lt f gs prf

--@derives [RARC.5.6.4]
export
rarc_5_6_4__count_frame : (k : Nat) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k w w' -> (k' : Nat) -> Not (k' = k) ->
             rarc_5_6_4__count_kind k' w' = rarc_5_6_4__count_kind k' w
rarc_5_6_4__count_frame k w w' fr k' neq = cong length (fr k' neq)

-- ---------------------------------------------------------------------
-- Live values and headroom
-- ---------------------------------------------------------------------

--@spec [LFAC.2.5.1]
public export
lfac_2_5_1__live_val : Nat -> (Nat, Nat) -> Rarc_5_6_4__wm -> Bool
lfac_2_5_1__live_val k v w = rarc_5_6_5__any (\f => lfac_2_5_1__same_val (lfac_2_5_1__val f) v) (rarc_5_6_4__facts_of_kind k w)

--@derives [LCYC.1.1]
||| Values of `dom` with no live fact of kind `k` carrying them.
public export
lcyc_1_1__headroom : Nat -> List (Nat, Nat) -> Rarc_5_6_4__wm -> Nat
lcyc_1_1__headroom k dom w = length (filter (\d => not (lfac_2_5_1__live_val k d w)) dom)

--@derives [LFAC.2.5.1]
export
lfac_2_5_1__live_val_frame : (k : Nat) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k w w' -> (k' : Nat) -> Not (k' = k) -> (d : (Nat, Nat)) ->
               lfac_2_5_1__live_val k' d w' = lfac_2_5_1__live_val k' d w
lfac_2_5_1__live_val_frame k w w' fr k' neq d = rewrite fr k' neq in Refl

--@derives [LCYC.1.1]
export
lcyc_1_1__headroom_frame : (k : Nat) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame k w w' -> (k' : Nat) -> Not (k' = k) ->
                (dom : List (Nat, Nat)) -> lcyc_1_1__headroom k' dom w' = lcyc_1_1__headroom k' dom w
lcyc_1_1__headroom_frame k w w' fr k' neq dom =
  cong length (lcyc_1_1__filter_ext (\d => not (lfac_2_5_1__live_val k' d w')) (\d => not (lfac_2_5_1__live_val k' d w))
                         (\d => cong not (lfac_2_5_1__live_val_frame k w w' fr k' neq d)) dom)

--@derives [LFAC.2.5.1]
export
lfac_2_5_1__live_val_append_mono : (k : Nat) -> (d : (Nat, Nat)) -> (w : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) ->
                    lfac_2_5_1__live_val k d w = True -> lfac_2_5_1__live_val k d (w ++ [f]) = True
lfac_2_5_1__live_val_append_mono k d w f prf =
  rewrite rarc_5_6_4__facts_of_kind_append k w [f] in
  lcyc_1_1__any_append_l (\g => lfac_2_5_1__same_val (lfac_2_5_1__val g) d) (rarc_5_6_4__facts_of_kind k w) (rarc_5_6_4__facts_of_kind k [f]) prf

--@derives [LFAC.2.5.1]
export
lfac_2_5_1__live_val_append_self : (w : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> lfac_2_5_1__live_val (fkind f) (lfac_2_5_1__val f) (w ++ [f]) = True
lfac_2_5_1__live_val_append_self w f =
  rewrite rarc_5_6_4__facts_of_kind_append (fkind f) w [f] in
  rewrite lcyc_1_1__nat_eq_refl (fkind f) in
  lcyc_1_1__any_append_r (\g => lfac_2_5_1__same_val (lfac_2_5_1__val g) (lfac_2_5_1__val f)) (rarc_5_6_4__facts_of_kind (fkind f) w) [f] (rewrite lfac_2_5_1__same_val_refl (lfac_2_5_1__val f) in Refl)

--@derives [LCYC.1.1]
||| A relation insert of a value in `dom` strictly lowers that kind's
||| headroom.
export
lcyc_1_1__headroom_insert_lt : (dom : List (Nat, Nat)) -> (w : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) ->
                   lfac_2_5_1__live_val (fkind f) (lfac_2_5_1__val f) w = False -> Elem (lfac_2_5_1__val f) dom ->
                   LT (lcyc_1_1__headroom (fkind f) dom (w ++ [f])) (lcyc_1_1__headroom (fkind f) dom w)
lcyc_1_1__headroom_insert_lt dom w f notLive inDom =
  lcyc_1_1__filter_strict (\d => not (lfac_2_5_1__live_val (fkind f) d w)) (\d => not (lfac_2_5_1__live_val (fkind f) d (w ++ [f])))
    (\d, prf => cong not (contra d prf))
    dom (lfac_2_5_1__val f) inDom (rewrite notLive in Refl) (rewrite lfac_2_5_1__live_val_append_self w f in Refl)
  where
    contra : (d : (Nat, Nat)) -> not (lfac_2_5_1__live_val (fkind f) d (w ++ [f])) = True -> lfac_2_5_1__live_val (fkind f) d w = False
    contra d prf with (lfac_2_5_1__live_val (fkind f) d w) proof lv
      contra d prf | True = absurd (trans (sym prf)
                                          (rewrite lfac_2_5_1__live_val_append_mono (fkind f) d w f lv in Refl))
      contra d prf | False = Refl

--@derives [LCYC.1.1]
export
lcyc_1_1__find_nothing_cons : (p : a -> Bool) -> (x : a) -> (xs : List a) -> rarc_5_6_5__find p (x :: xs) = Nothing ->
                   (p x = False, rarc_5_6_5__find p xs = Nothing)
lcyc_1_1__find_nothing_cons p x xs prf with (p x)
  lcyc_1_1__find_nothing_cons p x xs prf | True = absurd prf
  lcyc_1_1__find_nothing_cons p x xs prf | False = (Refl, prf)

--@derives [IRET.19.1]
||| `iret_19_1__find_relation` reporting no live fact means the value is not live.
export
iret_19_1__find_relation_nothing : (k, key, pay : Nat) -> (w : Rarc_5_6_4__wm) -> iret_19_1__find_relation k key pay w = Nothing ->
                      lfac_2_5_1__live_val k (key, pay) w = False
iret_19_1__find_relation_nothing k key pay [] prf = Refl
iret_19_1__find_relation_nothing k key pay (g :: gs) prf =
  let (pg, rest) = lcyc_1_1__find_nothing_cons (\f => (fkind f == k) && ((fkey f == key) && (fpay f == pay))) g gs prf
  in step pg (iret_19_1__find_relation_nothing k key pay gs rest)
  where
    step : ((fkind g == k) && ((fkey g == key) && (fpay g == pay))) = False ->
           lfac_2_5_1__live_val k (key, pay) gs = False -> lfac_2_5_1__live_val k (key, pay) (g :: gs) = False
    step pg ih with (fkind g == k)
      step pg ih | True = rewrite pg in ih
      step pg ih | False = ih

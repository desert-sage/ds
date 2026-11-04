-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The order theorem for Rete/Network.idr [LDET.5.5], [LDET.5.9]: the
||| creation timetag is a strict total order on a rule's activations, a
||| function of the match and of working memory alone; it is the same
||| order under the working memory before an assertion and after it, and
||| before a retraction and after it, for every match both hold. What
||| Rete/NetworkOrderKeep.idr builds on: every terminal is sorted by it
||| after any history, so the agenda order is the canonical order of the
||| activation set — batched equals incremental in order, and a released
||| match fires where it first completed.
|||
||| NORMATIVE COMPANION to Rete/Network.idr.
module Rete.NetworkOrder

import Rete.FireLoop
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- The strict order on positions
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
export
ldet_5_5__lt_irrefl : (a : Nat) -> ldet_5_5__lt a a = False
ldet_5_5__lt_irrefl Z = Refl
ldet_5_5__lt_irrefl (S a) = ldet_5_5__lt_irrefl a

--@derives [LDET.5.5]
export
ldet_5_5__lt_asym : (a, b : Nat) -> ldet_5_5__lt a b = True -> ldet_5_5__lt b a = False
ldet_5_5__lt_asym a Z prf = absurd (the (False = True) prf)
ldet_5_5__lt_asym Z (S b) prf = Refl
ldet_5_5__lt_asym (S a) (S b) prf = ldet_5_5__lt_asym a b prf

--@derives [LDET.5.5]
export
ldet_5_5__lt_trans : (a, b, c : Nat) -> ldet_5_5__lt a b = True -> ldet_5_5__lt b c = True -> ldet_5_5__lt a c = True
ldet_5_5__lt_trans a b Z ab bc = absurd (the (False = True) bc)
ldet_5_5__lt_trans a Z (S c) ab bc = absurd (the (False = True) ab)
ldet_5_5__lt_trans Z (S b) (S c) ab bc = Refl
ldet_5_5__lt_trans (S a) (S b) (S c) ab bc = ldet_5_5__lt_trans a b c ab bc

--@derives [LDET.5.5]
||| Not less and not equal is greater.
export
ldet_5_5__lt_tri : (a, b : Nat) -> ldet_5_5__lt a b = False -> (a == b) = False -> ldet_5_5__lt b a = True
ldet_5_5__lt_tri Z Z _ eq = absurd (the (True = False) eq)
ldet_5_5__lt_tri Z (S b) lt _ = absurd (the (True = False) lt)
ldet_5_5__lt_tri (S a) Z _ _ = Refl
ldet_5_5__lt_tri (S a) (S b) lt eq = ldet_5_5__lt_tri a b lt eq

--@derives [LDET.5.5]
export
ldet_5_5__lt_neq : (a, b : Nat) -> ldet_5_5__lt a b = True -> (a == b) = False
ldet_5_5__lt_neq a Z prf = absurd (the (False = True) prf)
ldet_5_5__lt_neq Z (S b) prf = Refl
ldet_5_5__lt_neq (S a) (S b) prf = ldet_5_5__lt_neq a b prf

--@derives [LDET.5.5]
export
ldet_5_5__max_z : (a : Nat) -> ldet_5_5__max a Z = a
ldet_5_5__max_z Z = Refl
ldet_5_5__max_z (S a) = Refl

--@derives [LDET.5.5]
export
ldet_5_5__max_lt : (a, b : Nat) -> ldet_5_5__lt a b = True -> ldet_5_5__max a b = b
ldet_5_5__max_lt a Z prf = absurd (the (False = True) prf)
ldet_5_5__max_lt Z (S b) prf = Refl
ldet_5_5__max_lt (S a) (S b) prf = cong S (ldet_5_5__max_lt a b prf)

--@derives [LDET.5.5]
export
ldet_5_5__max_ge : (a, b : Nat) -> ldet_5_5__lt a b = False -> ldet_5_5__max a b = a
ldet_5_5__max_ge a Z _ = ldet_5_5__max_z a
ldet_5_5__max_ge Z (S b) prf = absurd (the (True = False) prf)
ldet_5_5__max_ge (S a) (S b) prf = cong S (ldet_5_5__max_ge a b prf)

--@derives [LDET.5.5]
||| The latest position of a non-empty key is one of its positions.
export
ldet_5_5__latest_elem : (x : Nat) -> (xs : List Nat) -> Elem (ldet_5_5__latest (x :: xs)) (x :: xs)
ldet_5_5__latest_elem x [] = rewrite ldet_5_5__max_z x in Here
ldet_5_5__latest_elem x (y :: ys) with (ldet_5_5__lt x (ldet_5_5__latest (y :: ys))) proof l
  ldet_5_5__latest_elem x (y :: ys) | True = rewrite ldet_5_5__max_lt x (ldet_5_5__latest (y :: ys)) l in There (ldet_5_5__latest_elem y ys)
  ldet_5_5__latest_elem x (y :: ys) | False = rewrite ldet_5_5__max_ge x (ldet_5_5__latest (y :: ys)) l in Here

-- ---------------------------------------------------------------------
-- The renumbering a retraction performs [LDET.5.9]
-- ---------------------------------------------------------------------

--@derives [LDET.5.9]
||| After the fact at position p leaves, a position past p moves down by
||| one and a position before it stays.
public export
ldet_5_9__shift : Nat -> Nat -> Nat
ldet_5_9__shift Z Z = Z
ldet_5_9__shift Z (S x) = x
ldet_5_9__shift (S p) Z = Z
ldet_5_9__shift (S p) (S x) = S (ldet_5_9__shift p x)

--@derives [LDET.5.9]
||| The renumbering keeps the strict order between positions other than p.
export
ldet_5_9__shift_lt : (p, a, b : Nat) -> (a == p) = False -> (b == p) = False ->
                     ldet_5_5__lt (ldet_5_9__shift p a) (ldet_5_9__shift p b) = ldet_5_5__lt a b
ldet_5_9__shift_lt Z Z b ap _ = absurd (the (True = False) ap)
ldet_5_9__shift_lt Z (S a) Z _ bp = absurd (the (True = False) bp)
ldet_5_9__shift_lt Z (S a) (S b) _ _ = Refl
ldet_5_9__shift_lt (S p) Z Z _ _ = Refl
ldet_5_9__shift_lt (S p) Z (S b) _ _ = Refl
ldet_5_9__shift_lt (S p) (S a) Z _ _ = Refl
ldet_5_9__shift_lt (S p) (S a) (S b) ap bp = ldet_5_9__shift_lt p a b ap bp

--@derives [LDET.5.9]
||| The renumbering keeps equality between positions other than p.
export
ldet_5_9__shift_eq : (p, a, b : Nat) -> (a == p) = False -> (b == p) = False ->
                     (ldet_5_9__shift p a == ldet_5_9__shift p b) = (a == b)
ldet_5_9__shift_eq Z Z b ap _ = absurd (the (True = False) ap)
ldet_5_9__shift_eq Z (S a) Z _ bp = absurd (the (True = False) bp)
ldet_5_9__shift_eq Z (S a) (S b) _ _ = Refl
ldet_5_9__shift_eq (S p) Z Z _ _ = Refl
ldet_5_9__shift_eq (S p) Z (S b) _ _ = Refl
ldet_5_9__shift_eq (S p) (S a) Z _ _ = Refl
ldet_5_9__shift_eq (S p) (S a) (S b) ap bp = ldet_5_9__shift_eq p a b ap bp

--@derives [LDET.5.9]
export
ldet_5_9__shift_max : (p, a, b : Nat) -> (a == p) = False -> (b == p) = False ->
                      ldet_5_9__shift p (ldet_5_5__max a b) = ldet_5_5__max (ldet_5_9__shift p a) (ldet_5_9__shift p b)
ldet_5_9__shift_max p a b ap bp with (ldet_5_5__lt a b) proof l
  ldet_5_9__shift_max p a b ap bp | True =
    trans (cong (ldet_5_9__shift p) (ldet_5_5__max_lt a b l))
          (sym (ldet_5_5__max_lt (ldet_5_9__shift p a) (ldet_5_9__shift p b) (trans (ldet_5_9__shift_lt p a b ap bp) l)))
  ldet_5_9__shift_max p a b ap bp | False =
    trans (cong (ldet_5_9__shift p) (ldet_5_5__max_ge a b l))
          (sym (ldet_5_5__max_ge (ldet_5_9__shift p a) (ldet_5_9__shift p b) (trans (ldet_5_9__shift_lt p a b ap bp) l)))

--@derives [LDET.5.9]
||| A key none of whose positions is p keeps its latest away from p.
export
ldet_5_9__latest_neq : (p : Nat) -> (x : Nat) -> (xs : List Nat) -> All (\y => (y == p) = False) (x :: xs) ->
                       (ldet_5_5__latest (x :: xs) == p) = False
ldet_5_9__latest_neq p x xs al = lcyc_1_1__all_lookup al (ldet_5_5__latest_elem x xs)

--@derives [LDET.5.9]
||| The latest of a renumbered key is the renumbered latest.
export
ldet_5_9__latest_shift : (p : Nat) -> (x : Nat) -> (xs : List Nat) -> All (\y => (y == p) = False) (x :: xs) ->
                         ldet_5_5__latest (map (ldet_5_9__shift p) (x :: xs)) = ldet_5_9__shift p (ldet_5_5__latest (x :: xs))
ldet_5_9__latest_shift p x [] (px :: []) =
  trans (ldet_5_5__max_z (ldet_5_9__shift p x)) (cong (ldet_5_9__shift p) (sym (ldet_5_5__max_z x)))
ldet_5_9__latest_shift p x (y :: ys) (px :: al) =
  trans (cong (ldet_5_5__max (ldet_5_9__shift p x)) (ldet_5_9__latest_shift p y ys al))
        (sym (ldet_5_9__shift_max p x (ldet_5_5__latest (y :: ys)) px (ldet_5_9__latest_neq p y ys al)))

--@derives [LDET.5.9]
||| The lexicographic order between renumbered keys is the order between
||| the keys.
export
ldet_5_9__lex_shift : (p : Nat) -> (xs, ys : List Nat) -> All (\y => (y == p) = False) xs -> All (\y => (y == p) = False) ys ->
                      ldet_5_5__lex_lt (map (ldet_5_9__shift p) xs) (map (ldet_5_9__shift p) ys) = ldet_5_5__lex_lt xs ys
ldet_5_9__lex_shift p [] [] _ _ = Refl
ldet_5_9__lex_shift p [] (y :: ys) _ _ = Refl
ldet_5_9__lex_shift p (x :: xs) [] _ _ = Refl
ldet_5_9__lex_shift p (x :: xs) (y :: ys) (px :: pxs) (py :: pys) with (ldet_5_5__lt x y) proof l
  ldet_5_9__lex_shift p (x :: xs) (y :: ys) (px :: pxs) (py :: pys) | True =
    rewrite ldet_5_9__shift_lt p x y px py in rewrite l in Refl
  ldet_5_9__lex_shift p (x :: xs) (y :: ys) (px :: pxs) (py :: pys) | False with (x == y) proof e
    ldet_5_9__lex_shift p (x :: xs) (y :: ys) (px :: pxs) (py :: pys) | False | True =
      rewrite ldet_5_9__shift_lt p x y px py in rewrite l in
      rewrite ldet_5_9__shift_eq p x y px py in rewrite e in
      ldet_5_9__lex_shift p xs ys pxs pys
    ldet_5_9__lex_shift p (x :: xs) (y :: ys) (px :: pxs) (py :: pys) | False | False =
      rewrite ldet_5_9__shift_lt p x y px py in rewrite l in
      rewrite ldet_5_9__shift_eq p x y px py in rewrite e in Refl

--@derives [LDET.5.9]
||| THE ORDER IS THE SAME UNDER THE RENUMBERING, for two non-empty keys
||| none of whose positions is p.
export
ldet_5_9__before_shift : (p : Nat) -> (x, y : Nat) -> (xs, ys : List Nat) ->
                         All (\z => (z == p) = False) (x :: xs) -> All (\z => (z == p) = False) (y :: ys) ->
                         ldet_5_5__before_keys (map (ldet_5_9__shift p) (x :: xs)) (map (ldet_5_9__shift p) (y :: ys))
                           = ldet_5_5__before_keys (x :: xs) (y :: ys)
ldet_5_9__before_shift p x y xs ys ax ay with (ldet_5_5__lt (ldet_5_5__latest (x :: xs)) (ldet_5_5__latest (y :: ys))) proof l
  ldet_5_9__before_shift p x y xs ys ax ay | True =
    rewrite ldet_5_9__latest_shift p x xs ax in rewrite ldet_5_9__latest_shift p y ys ay in
    rewrite ldet_5_9__shift_lt p (ldet_5_5__latest (x :: xs)) (ldet_5_5__latest (y :: ys)) (ldet_5_9__latest_neq p x xs ax) (ldet_5_9__latest_neq p y ys ay) in
    rewrite l in Refl
  ldet_5_9__before_shift p x y xs ys ax ay | False with (ldet_5_5__latest (x :: xs) == ldet_5_5__latest (y :: ys)) proof e
    ldet_5_9__before_shift p x y xs ys ax ay | False | True =
      rewrite ldet_5_9__latest_shift p x xs ax in rewrite ldet_5_9__latest_shift p y ys ay in
      rewrite ldet_5_9__shift_lt p (ldet_5_5__latest (x :: xs)) (ldet_5_5__latest (y :: ys)) (ldet_5_9__latest_neq p x xs ax) (ldet_5_9__latest_neq p y ys ay) in
      rewrite l in
      rewrite ldet_5_9__latest_shift p x xs ax in rewrite ldet_5_9__latest_shift p y ys ay in
      rewrite ldet_5_9__shift_eq p (ldet_5_5__latest (x :: xs)) (ldet_5_5__latest (y :: ys)) (ldet_5_9__latest_neq p x xs ax) (ldet_5_9__latest_neq p y ys ay) in
      rewrite e in ldet_5_9__lex_shift p (x :: xs) (y :: ys) ax ay
    ldet_5_9__before_shift p x y xs ys ax ay | False | False =
      rewrite ldet_5_9__latest_shift p x xs ax in rewrite ldet_5_9__latest_shift p y ys ay in
      rewrite ldet_5_9__shift_lt p (ldet_5_5__latest (x :: xs)) (ldet_5_5__latest (y :: ys)) (ldet_5_9__latest_neq p x xs ax) (ldet_5_9__latest_neq p y ys ay) in
      rewrite l in
      rewrite ldet_5_9__latest_shift p x xs ax in rewrite ldet_5_9__latest_shift p y ys ay in
      rewrite ldet_5_9__shift_eq p (ldet_5_5__latest (x :: xs)) (ldet_5_5__latest (y :: ys)) (ldet_5_9__latest_neq p x xs ax) (ldet_5_9__latest_neq p y ys ay) in
      rewrite e in Refl

--@derives [LDET.5.5]
||| The nil token's key comes before every non-empty key, and nothing
||| comes before it: the order of a rule of only NOT patterns.
export
ldet_5_5__before_nil : (y : Nat) -> (ys : List Nat) -> ldet_5_5__before_keys [] (y :: ys) = True
ldet_5_5__before_nil y ys with (ldet_5_5__lt 0 (ldet_5_5__latest (y :: ys))) proof l
  ldet_5_5__before_nil y ys | True = Refl
  ldet_5_5__before_nil y ys | False with (ldet_5_5__latest (y :: ys)) proof lat
    ldet_5_5__before_nil y ys | False | Z = Refl
    ldet_5_5__before_nil y ys | False | (S n) = absurd (the (True = False) l)

--@derives [LDET.5.5]
export
ldet_5_5__nil_before : (ks : List Nat) -> ldet_5_5__before_keys ks [] = False
ldet_5_5__nil_before [] = Refl
ldet_5_5__nil_before (x :: xs) with (ldet_5_5__latest (x :: xs)) proof lat
  ldet_5_5__nil_before (x :: xs) | Z = Refl
  ldet_5_5__nil_before (x :: xs) | (S n) = Refl

-- ---------------------------------------------------------------------
-- Positions under a change of working memory
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
||| A fact of the tail, given it is not the head.
export
ldet_5_5__elem_tail : {x, h : Lfac_1_7_1__fact} -> {rest : List Lfac_1_7_1__fact} ->
                      Elem x (h :: rest) -> lfac_2_5_4__same_fact h x = False -> Elem x rest
ldet_5_5__elem_tail Here hx = absurd (the (True = False) (trans (sym (lfac_2_5_4__same_fact_refl _)) hx))
ldet_5_5__elem_tail (There e) hx = e

--@derives [LDET.5.5]
||| A live fact's position is unchanged by an assertion.
export
ldet_5_5__pos_append : (wm : Rarc_5_6_4__wm) -> (f, g : Lfac_1_7_1__fact) -> Elem g wm -> ldet_5_5__pos (wm ++ [f]) g = ldet_5_5__pos wm g
ldet_5_5__pos_append (h :: rest) f g eg with (lfac_2_5_4__same_fact h g) proof hg
  ldet_5_5__pos_append (h :: rest) f g eg | True = Refl
  ldet_5_5__pos_append (h :: rest) f g eg | False = cong S (ldet_5_5__pos_append rest f g (ldet_5_5__elem_tail eg hg))

--@derives [LDET.5.5]
||| In a distinct working memory, position determines the fact.
export
ldet_5_5__pos_inj : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (g, f : Lfac_1_7_1__fact) -> Elem g wm -> Elem f wm ->
                    ldet_5_5__pos wm g = ldet_5_5__pos wm f -> g = f
ldet_5_5__pos_inj (h :: rest) (DCons nh d) g f eg ef eq with (lfac_2_5_4__same_fact h g) proof hg
  ldet_5_5__pos_inj (h :: rest) (DCons nh d) g f eg ef eq | True with (lfac_2_5_4__same_fact h f) proof hf
    ldet_5_5__pos_inj (h :: rest) (DCons nh d) g f eg ef eq | True | True = trans (sym (lfac_2_5_4__same_fact_eq h g hg)) (lfac_2_5_4__same_fact_eq h f hf)
    ldet_5_5__pos_inj (h :: rest) (DCons nh d) g f eg ef eq | True | False = absurd (the (Z = S (ldet_5_5__pos rest f)) eq)
  ldet_5_5__pos_inj (h :: rest) (DCons nh d) g f eg ef eq | False with (lfac_2_5_4__same_fact h f) proof hf
    ldet_5_5__pos_inj (h :: rest) (DCons nh d) g f eg ef eq | False | True = absurd (the (S (ldet_5_5__pos rest g) = Z) eq)
    ldet_5_5__pos_inj (h :: rest) (DCons nh d) g f eg ef eq | False | False =
      ldet_5_5__pos_inj rest d g f (ldet_5_5__elem_tail eg hg) (ldet_5_5__elem_tail ef hf) (lcyc_1_1__succ_inj eq)

--@derives [LDET.5.9]
||| A live fact other than the retracted one takes the renumbered
||| position of its old one.
export
ldet_5_9__pos_remove : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                       (g : Lfac_1_7_1__fact) -> Elem g wm -> Not (g = f) ->
                       ldet_5_5__pos (rarc_5_6_4__remove_exact f wm) g = ldet_5_9__shift (ldet_5_5__pos wm f) (ldet_5_5__pos wm g)
ldet_5_9__pos_remove (h :: rest) (DCons nh d) f ef g eg ne with (lfac_2_5_4__same_fact h f) proof hf
  ldet_5_9__pos_remove (h :: rest) (DCons nh d) f ef g eg ne | True =
    let hfe : (h = f)
        hfe = lfac_2_5_4__same_fact_eq h f hf
        hg : (lfac_2_5_4__same_fact h g = False)
        hg = lfac_2_5_4__same_fact_neq h g (\eq => ne (trans (sym eq) hfe))
        nf : Not (Elem f rest)
        nf = \e => nh (replace {p = \z => Elem z rest} (sym hfe) e)
    in rewrite rarc_5_6_4__remove_exact_absent f rest nf in rewrite hg in Refl
  ldet_5_9__pos_remove (h :: rest) (DCons nh d) f ef g eg ne | False with (lfac_2_5_4__same_fact h g) proof hg
    ldet_5_9__pos_remove (h :: rest) (DCons nh d) f ef g eg ne | False | True = Refl
    ldet_5_9__pos_remove (h :: rest) (DCons nh d) f ef g eg ne | False | False =
      cong S (ldet_5_9__pos_remove rest d f (ldet_5_5__elem_tail ef hf) g (ldet_5_5__elem_tail eg hg) ne)

-- ---------------------------------------------------------------------
-- Keys under a change of working memory
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
||| A token whose facts are all live.
public export
Ldet_5_5__live : Rarc_5_6_4__wm -> Iret_7_1__token -> Type
Ldet_5_5__live wm t = All (\g => Elem g wm) t

--@derives [LDET.5.5]
export
ldet_5_5__map_all : (g, h : a -> b) -> (xs : List a) -> All (\x => g x = h x) xs -> map g xs = map h xs
ldet_5_5__map_all g h [] [] = Refl
ldet_5_5__map_all g h (x :: xs) (px :: pxs) = rewrite px in cong (h x ::) (ldet_5_5__map_all g h xs pxs)

--@derives [LDET.5.5]
export
ldet_5_5__map_map : (g : b -> c) -> (h : a -> b) -> (xs : List a) -> map g (map h xs) = map (\x => g (h x)) xs
ldet_5_5__map_map g h [] = Refl
ldet_5_5__map_map g h (x :: xs) = cong (g (h x) ::) (ldet_5_5__map_map g h xs)

--@derives [LDET.5.5]
||| A live token's key is unchanged by an assertion.
export
ldet_5_5__key_append : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (t : Iret_7_1__token) -> Ldet_5_5__live wm t ->
                       ldet_5_5__key (wm ++ [f]) t = ldet_5_5__key wm t
ldet_5_5__key_append wm f t lv = ldet_5_5__map_all _ _ t (lcyc_1_1__all_imp t (\g, eg => ldet_5_5__pos_append wm f g eg) lv)

--@derives [LDET.5.9]
||| A token live without the retracted fact has, afterwards, its old key
||| renumbered.
export
ldet_5_9__key_remove : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                       (t : Iret_7_1__token) -> Ldet_5_5__live wm t -> Not (Elem f t) ->
                       ldet_5_5__key (rarc_5_6_4__remove_exact f wm) t = map (ldet_5_9__shift (ldet_5_5__pos wm f)) (ldet_5_5__key wm t)
ldet_5_9__key_remove wm dw f ef t lv nft =
  trans (ldet_5_5__map_all _ _ t (lcyc_1_1__all_from_elem t (\g, eg =>
           ldet_5_9__pos_remove wm dw f ef g (lcyc_1_1__all_lookup lv eg) (\gf => nft (replace {p = \z => Elem z t} gf eg)))))
        (sym (ldet_5_5__map_map (ldet_5_9__shift (ldet_5_5__pos wm f)) (ldet_5_5__pos wm) t))

--@derives [LDET.5.9]
||| No position of such a token is the retracted fact's.
export
ldet_5_9__key_neq : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                    (t : Iret_7_1__token) -> Ldet_5_5__live wm t -> Not (Elem f t) ->
                    All (\z => (z == ldet_5_5__pos wm f) = False) (ldet_5_5__key wm t)
ldet_5_9__key_neq wm dw f ef t lv nft =
  lcyc_1_1__all_map (ldet_5_5__pos wm) (lcyc_1_1__all_from_elem t (\g, eg =>
    iret_12__bool_false_of _ (\p => nft (replace {p = \z => Elem z t}
      (ldet_5_5__pos_inj wm dw g f (lcyc_1_1__all_lookup lv eg) ef (lcyc_1_1__nat_eq_true _ _ p)) eg))))

--@derives [LDET.5.5]
||| THE ORDER IS THE SAME UNDER THE WORKING MEMORY BEFORE AN ASSERTION
||| AND AFTER IT, for two live matches.
export
ldet_5_5__before_append : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (s, t : Iret_7_1__token) ->
                          Ldet_5_5__live wm s -> Ldet_5_5__live wm t ->
                          ldet_5_5__before (wm ++ [f]) s t = ldet_5_5__before wm s t
ldet_5_5__before_append wm f s t ls lt =
  cong2 ldet_5_5__before_keys (ldet_5_5__key_append wm f s ls) (ldet_5_5__key_append wm f t lt)

--@derives [LDET.5.9]
||| The order between renumbered keys is the order between the keys, for
||| any two keys none of whose positions is p.
export
ldet_5_9__before_keys_shift : (p : Nat) -> (ks, kt : List Nat) -> All (\z => (z == p) = False) ks -> All (\z => (z == p) = False) kt ->
                              ldet_5_5__before_keys (map (ldet_5_9__shift p) ks) (map (ldet_5_9__shift p) kt) = ldet_5_5__before_keys ks kt
ldet_5_9__before_keys_shift p [] [] _ _ = Refl
ldet_5_9__before_keys_shift p [] (y :: ys) _ _ = trans (ldet_5_5__before_nil _ _) (sym (ldet_5_5__before_nil y ys))
ldet_5_9__before_keys_shift p (x :: xs) [] _ _ = trans (ldet_5_5__nil_before _) (sym (ldet_5_5__nil_before (x :: xs)))
ldet_5_9__before_keys_shift p (x :: xs) (y :: ys) ax ay = ldet_5_9__before_shift p x y xs ys ax ay

--@derives [LDET.5.9]
||| THE ORDER IS THE SAME UNDER THE WORKING MEMORY BEFORE A RETRACTION
||| AND AFTER IT, for two matches live without the retracted fact: a
||| released match fires where it first completed, and the survivors keep
||| their order.
export
ldet_5_9__before_remove : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                          (s, t : Iret_7_1__token) -> Ldet_5_5__live wm s -> Ldet_5_5__live wm t -> Not (Elem f s) -> Not (Elem f t) ->
                          ldet_5_5__before (rarc_5_6_4__remove_exact f wm) s t = ldet_5_5__before wm s t
ldet_5_9__before_remove wm dw f ef s t ls lt nfs nft =
  trans (cong2 ldet_5_5__before_keys (ldet_5_9__key_remove wm dw f ef s ls nfs) (ldet_5_9__key_remove wm dw f ef t lt nft))
        (ldet_5_9__before_keys_shift (ldet_5_5__pos wm f) (ldet_5_5__key wm s) (ldet_5_5__key wm t)
           (ldet_5_9__key_neq wm dw f ef s ls nfs) (ldet_5_9__key_neq wm dw f ef t lt nft))

-- ---------------------------------------------------------------------
-- The order on keys is strict and total
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
export
ldet_5_5__eq_comm : (a, b : Nat) -> (a == b) = (b == a)
ldet_5_5__eq_comm Z Z = Refl
ldet_5_5__eq_comm Z (S b) = Refl
ldet_5_5__eq_comm (S a) Z = Refl
ldet_5_5__eq_comm (S a) (S b) = ldet_5_5__eq_comm a b

--@derives [LDET.5.5]
export
ldet_5_5__lex_irrefl : (ks : List Nat) -> ldet_5_5__lex_lt ks ks = False
ldet_5_5__lex_irrefl [] = Refl
ldet_5_5__lex_irrefl (x :: xs) =
  rewrite ldet_5_5__lt_irrefl x in rewrite lcyc_1_1__nat_eq_refl x in ldet_5_5__lex_irrefl xs

--@derives [LDET.5.5]
export
ldet_5_5__lex_asym : (ks, kt : List Nat) -> ldet_5_5__lex_lt ks kt = True -> ldet_5_5__lex_lt kt ks = False
ldet_5_5__lex_asym [] [] prf = absurd (the (False = True) prf)
ldet_5_5__lex_asym [] (y :: ys) prf = Refl
ldet_5_5__lex_asym (x :: xs) [] prf = absurd (the (False = True) prf)
ldet_5_5__lex_asym (x :: xs) (y :: ys) prf with (ldet_5_5__lt x y) proof l
  ldet_5_5__lex_asym (x :: xs) (y :: ys) prf | True =
    rewrite ldet_5_5__lt_asym x y l in rewrite ldet_5_5__eq_comm y x in rewrite ldet_5_5__lt_neq x y l in Refl
  ldet_5_5__lex_asym (x :: xs) (y :: ys) prf | False with (x == y) proof e
    ldet_5_5__lex_asym (x :: xs) (y :: ys) prf | False | True =
      rewrite sym (lcyc_1_1__nat_eq_true x y e) in
      rewrite ldet_5_5__lt_irrefl x in rewrite lcyc_1_1__nat_eq_refl x in ldet_5_5__lex_asym xs ys prf
    ldet_5_5__lex_asym (x :: xs) (y :: ys) prf | False | False = absurd (the (False = True) prf)

--@derives [LDET.5.5]
export
ldet_5_5__lex_trans : (ks, kt, ku : List Nat) -> ldet_5_5__lex_lt ks kt = True -> ldet_5_5__lex_lt kt ku = True -> ldet_5_5__lex_lt ks ku = True
ldet_5_5__lex_trans [] [] ku p1 p2 = absurd (the (False = True) p1)
ldet_5_5__lex_trans [] (y :: ys) [] p1 p2 = absurd (the (False = True) p2)
ldet_5_5__lex_trans [] (y :: ys) (z :: zs) p1 p2 = Refl
ldet_5_5__lex_trans (x :: xs) [] ku p1 p2 = absurd (the (False = True) p1)
ldet_5_5__lex_trans (x :: xs) (y :: ys) [] p1 p2 = absurd (the (False = True) p2)
ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 with (ldet_5_5__lt x y) proof l1
  ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | True with (ldet_5_5__lt y z) proof l2
    ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | True | True = rewrite ldet_5_5__lt_trans x y z l1 l2 in Refl
    ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | True | False with (y == z) proof e2
      ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | True | False | True =
        rewrite sym (lcyc_1_1__nat_eq_true y z e2) in rewrite l1 in Refl
      ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | True | False | False = absurd (the (False = True) p2)
  ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | False with (x == y) proof e1
    ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | False | True with (ldet_5_5__lt y z) proof l2
      ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | False | True | True =
        rewrite lcyc_1_1__nat_eq_true x y e1 in rewrite l2 in Refl
      ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | False | True | False with (y == z) proof e2
        ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | False | True | False | True =
          rewrite lcyc_1_1__nat_eq_true x y e1 in rewrite lcyc_1_1__nat_eq_true y z e2 in
          rewrite ldet_5_5__lt_irrefl z in rewrite lcyc_1_1__nat_eq_refl z in ldet_5_5__lex_trans xs ys zs p1 p2
        ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | False | True | False | False = absurd (the (False = True) p2)
    ldet_5_5__lex_trans (x :: xs) (y :: ys) (z :: zs) p1 p2 | False | False = absurd (the (False = True) p1)

--@derives [LDET.5.5]
||| Two different keys are ordered one way or the other.
export
ldet_5_5__lex_total : (ks, kt : List Nat) -> Not (ks = kt) -> Either (ldet_5_5__lex_lt ks kt = True) (ldet_5_5__lex_lt kt ks = True)
ldet_5_5__lex_total [] [] ne = void (ne Refl)
ldet_5_5__lex_total [] (y :: ys) ne = Left Refl
ldet_5_5__lex_total (x :: xs) [] ne = Right Refl
ldet_5_5__lex_total (x :: xs) (y :: ys) ne with (ldet_5_5__lt x y) proof l
  ldet_5_5__lex_total (x :: xs) (y :: ys) ne | True = Left Refl
  ldet_5_5__lex_total (x :: xs) (y :: ys) ne | False with (ldet_5_5__lt y x) proof l'
    ldet_5_5__lex_total (x :: xs) (y :: ys) ne | False | True = Right Refl
    ldet_5_5__lex_total (x :: xs) (y :: ys) ne | False | False with (x == y) proof e
      ldet_5_5__lex_total (x :: xs) (y :: ys) ne | False | False | True =
        let xy : (x = y)
            xy = lcyc_1_1__nat_eq_true x y e
        in case ldet_5_5__lex_total xs ys (\eq => ne (cong2 (::) xy eq)) of
             Left p  => Left p
             Right p => Right (rewrite ldet_5_5__eq_comm y x in rewrite e in p)
      ldet_5_5__lex_total (x :: xs) (y :: ys) ne | False | False | False = absurd (trans (sym l') (ldet_5_5__lt_tri x y l e))

--@derives [LDET.5.5]
export
ldet_5_5__before_keys_irrefl : (ks : List Nat) -> ldet_5_5__before_keys ks ks = False
ldet_5_5__before_keys_irrefl ks =
  rewrite ldet_5_5__lt_irrefl (ldet_5_5__latest ks) in rewrite lcyc_1_1__nat_eq_refl (ldet_5_5__latest ks) in ldet_5_5__lex_irrefl ks

--@derives [LDET.5.5]
export
ldet_5_5__before_keys_asym : (ks, kt : List Nat) -> ldet_5_5__before_keys ks kt = True -> ldet_5_5__before_keys kt ks = False
ldet_5_5__before_keys_asym ks kt prf with (ldet_5_5__lt (ldet_5_5__latest ks) (ldet_5_5__latest kt)) proof l
  ldet_5_5__before_keys_asym ks kt prf | True =
    rewrite ldet_5_5__lt_asym (ldet_5_5__latest ks) (ldet_5_5__latest kt) l in
    rewrite ldet_5_5__eq_comm (ldet_5_5__latest kt) (ldet_5_5__latest ks) in
    rewrite ldet_5_5__lt_neq (ldet_5_5__latest ks) (ldet_5_5__latest kt) l in Refl
  ldet_5_5__before_keys_asym ks kt prf | False with (ldet_5_5__latest ks == ldet_5_5__latest kt) proof e
    ldet_5_5__before_keys_asym ks kt prf | False | True =
      rewrite sym (lcyc_1_1__nat_eq_true (ldet_5_5__latest ks) (ldet_5_5__latest kt) e) in
      rewrite ldet_5_5__lt_irrefl (ldet_5_5__latest ks) in
      rewrite sym (lcyc_1_1__nat_eq_true (ldet_5_5__latest ks) (ldet_5_5__latest kt) e) in
      rewrite lcyc_1_1__nat_eq_refl (ldet_5_5__latest ks) in
      ldet_5_5__lex_asym ks kt prf
    ldet_5_5__before_keys_asym ks kt prf | False | False = absurd (the (False = True) prf)

--@derives [LDET.5.5]
export
ldet_5_5__before_keys_trans : (ks, kt, ku : List Nat) -> ldet_5_5__before_keys ks kt = True -> ldet_5_5__before_keys kt ku = True ->
                              ldet_5_5__before_keys ks ku = True
ldet_5_5__before_keys_trans ks kt ku p1 p2 with (ldet_5_5__lt (ldet_5_5__latest ks) (ldet_5_5__latest kt)) proof l1
  ldet_5_5__before_keys_trans ks kt ku p1 p2 | True with (ldet_5_5__lt (ldet_5_5__latest kt) (ldet_5_5__latest ku)) proof l2
    ldet_5_5__before_keys_trans ks kt ku p1 p2 | True | True =
      rewrite ldet_5_5__lt_trans (ldet_5_5__latest ks) (ldet_5_5__latest kt) (ldet_5_5__latest ku) l1 l2 in Refl
    ldet_5_5__before_keys_trans ks kt ku p1 p2 | True | False with (ldet_5_5__latest kt == ldet_5_5__latest ku) proof e2
      ldet_5_5__before_keys_trans ks kt ku p1 p2 | True | False | True =
        rewrite sym (lcyc_1_1__nat_eq_true (ldet_5_5__latest kt) (ldet_5_5__latest ku) e2) in rewrite l1 in Refl
      ldet_5_5__before_keys_trans ks kt ku p1 p2 | True | False | False = absurd (the (False = True) p2)
  ldet_5_5__before_keys_trans ks kt ku p1 p2 | False with (ldet_5_5__latest ks == ldet_5_5__latest kt) proof e1
    ldet_5_5__before_keys_trans ks kt ku p1 p2 | False | True with (ldet_5_5__lt (ldet_5_5__latest kt) (ldet_5_5__latest ku)) proof l2
      ldet_5_5__before_keys_trans ks kt ku p1 p2 | False | True | True =
        rewrite lcyc_1_1__nat_eq_true (ldet_5_5__latest ks) (ldet_5_5__latest kt) e1 in rewrite l2 in Refl
      ldet_5_5__before_keys_trans ks kt ku p1 p2 | False | True | False with (ldet_5_5__latest kt == ldet_5_5__latest ku) proof e2
        ldet_5_5__before_keys_trans ks kt ku p1 p2 | False | True | False | True =
          rewrite lcyc_1_1__nat_eq_true (ldet_5_5__latest ks) (ldet_5_5__latest kt) e1 in
          rewrite lcyc_1_1__nat_eq_true (ldet_5_5__latest kt) (ldet_5_5__latest ku) e2 in
          rewrite ldet_5_5__lt_irrefl (ldet_5_5__latest ku) in
          rewrite lcyc_1_1__nat_eq_true (ldet_5_5__latest ks) (ldet_5_5__latest kt) e1 in
          rewrite lcyc_1_1__nat_eq_true (ldet_5_5__latest kt) (ldet_5_5__latest ku) e2 in
          rewrite lcyc_1_1__nat_eq_refl (ldet_5_5__latest ku) in
          ldet_5_5__lex_trans ks kt ku p1 p2
        ldet_5_5__before_keys_trans ks kt ku p1 p2 | False | True | False | False = absurd (the (False = True) p2)
    ldet_5_5__before_keys_trans ks kt ku p1 p2 | False | False = absurd (the (False = True) p1)

--@derives [LDET.5.5]
||| Two different keys are ordered one way or the other: the timetag is
||| total on the activations of one rule.
export
ldet_5_5__before_keys_total : (ks, kt : List Nat) -> Not (ks = kt) -> Either (ldet_5_5__before_keys ks kt = True) (ldet_5_5__before_keys kt ks = True)
ldet_5_5__before_keys_total ks kt ne with (ldet_5_5__lt (ldet_5_5__latest ks) (ldet_5_5__latest kt)) proof l
  ldet_5_5__before_keys_total ks kt ne | True = Left Refl
  ldet_5_5__before_keys_total ks kt ne | False with (ldet_5_5__latest ks == ldet_5_5__latest kt) proof e
    ldet_5_5__before_keys_total ks kt ne | False | True = case ldet_5_5__lex_total ks kt ne of
      Left p  => Left p
      Right p => Right (rewrite sym (lcyc_1_1__nat_eq_true (ldet_5_5__latest ks) (ldet_5_5__latest kt) e) in
                        rewrite ldet_5_5__lt_irrefl (ldet_5_5__latest ks) in
                        rewrite sym (lcyc_1_1__nat_eq_true (ldet_5_5__latest ks) (ldet_5_5__latest kt) e) in
                        rewrite lcyc_1_1__nat_eq_refl (ldet_5_5__latest ks) in p)
    ldet_5_5__before_keys_total ks kt ne | False | False =
      Right (rewrite ldet_5_5__lt_tri (ldet_5_5__latest ks) (ldet_5_5__latest kt) l e in Refl)

-- ---------------------------------------------------------------------
-- The order on live tokens
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
||| In a distinct working memory, the key determines the live token.
export
ldet_5_5__key_inj : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (s, t : Iret_7_1__token) -> Ldet_5_5__live wm s -> Ldet_5_5__live wm t ->
                    ldet_5_5__key wm s = ldet_5_5__key wm t -> s = t
ldet_5_5__key_inj wm dw [] [] _ _ eq = Refl
ldet_5_5__key_inj wm dw [] (g :: gs) _ _ eq = absurd eq
ldet_5_5__key_inj wm dw (f :: fs) [] _ _ eq = absurd eq
ldet_5_5__key_inj wm dw (f :: fs) (g :: gs) (lf :: lfs) (lg :: lgs) eq =
  let (hd, tl) = consInjective eq
  in cong2 (::) (ldet_5_5__pos_inj wm dw f g lf lg hd) (ldet_5_5__key_inj wm dw fs gs lfs lgs tl)

--@derives [LDET.5.5]
export
ldet_5_5__before_irrefl : (wm : Rarc_5_6_4__wm) -> (t : Iret_7_1__token) -> ldet_5_5__before wm t t = False
ldet_5_5__before_irrefl wm t = ldet_5_5__before_keys_irrefl (ldet_5_5__key wm t)

--@derives [LDET.5.5]
export
ldet_5_5__before_asym : (wm : Rarc_5_6_4__wm) -> (s, t : Iret_7_1__token) -> ldet_5_5__before wm s t = True -> ldet_5_5__before wm t s = False
ldet_5_5__before_asym wm s t prf = ldet_5_5__before_keys_asym (ldet_5_5__key wm s) (ldet_5_5__key wm t) prf

--@derives [LDET.5.5]
export
ldet_5_5__before_trans : (wm : Rarc_5_6_4__wm) -> (s, t, u : Iret_7_1__token) ->
                         ldet_5_5__before wm s t = True -> ldet_5_5__before wm t u = True -> ldet_5_5__before wm s u = True
ldet_5_5__before_trans wm s t u p1 p2 = ldet_5_5__before_keys_trans (ldet_5_5__key wm s) (ldet_5_5__key wm t) (ldet_5_5__key wm u) p1 p2

--@derives [LDET.5.5]
--@derives [IRET.11.1]
||| Two different live matches are ordered one way or the other: the
||| second key decides between any two activations of one rule.
export
ldet_5_5__before_total : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (s, t : Iret_7_1__token) -> Ldet_5_5__live wm s -> Ldet_5_5__live wm t ->
                         Not (s = t) -> Either (ldet_5_5__before wm s t = True) (ldet_5_5__before wm t s = True)
ldet_5_5__before_total wm dw s t ls lt ne =
  ldet_5_5__before_keys_total (ldet_5_5__key wm s) (ldet_5_5__key wm t) (\eq => ne (ldet_5_5__key_inj wm dw s t ls lt eq))

-- ---------------------------------------------------------------------
-- A terminal sorted by the timetag
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
--@derives [IRET.1.9]
||| A terminal in agenda order: each activation before every later one.
public export
data Ldet_5_5__sorted : Rarc_5_6_4__wm -> List Iret_8_1__act -> Type where
  SNil  : Ldet_5_5__sorted w []
  SCons : All (\b => ldet_5_5__before w (atuple a) (atuple b) = True) rest -> Ldet_5_5__sorted w rest -> Ldet_5_5__sorted w (a :: rest)

--@derives [LDET.5.5]
||| Every activation of a terminal is live.
public export
Ldet_5_5__live_acts : Rarc_5_6_4__wm -> List Iret_8_1__act -> Type
Ldet_5_5__live_acts wm acts = All (\a => Ldet_5_5__live wm (atuple a)) acts

--@derives [LDET.5.5]
export
ldet_5_5__insert_all : (wm : Rarc_5_6_4__wm) -> (prop : Iret_8_1__act -> Type) -> (a : Iret_8_1__act) -> (acts : List Iret_8_1__act) ->
                       prop a -> All prop acts -> All prop (ldet_5_5__insert wm a acts)
ldet_5_5__insert_all wm prop a [] pa [] = [pa]
ldet_5_5__insert_all wm prop a (b :: bs) pa (pb :: pbs) with (ldet_5_5__before wm (atuple a) (atuple b))
  ldet_5_5__insert_all wm prop a (b :: bs) pa (pb :: pbs) | True = pa :: pb :: pbs
  ldet_5_5__insert_all wm prop a (b :: bs) pa (pb :: pbs) | False = pb :: ldet_5_5__insert_all wm prop a bs pa pbs

--@derives [LDET.5.5]
||| INSERTION KEEPS THE ORDER: a live activation not already held takes
||| its place, and the terminal stays sorted.
export
ldet_5_5__insert_sorted : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (a : Iret_8_1__act) -> Ldet_5_5__live wm (atuple a) ->
                          (acts : List Iret_8_1__act) -> Ldet_5_5__sorted wm acts -> Ldet_5_5__live_acts wm acts ->
                          Not (Elem (atuple a) (iret_8_1__tuples acts)) -> Ldet_5_5__sorted wm (ldet_5_5__insert wm a acts)
ldet_5_5__insert_sorted wm dw a la [] SNil [] na = SCons [] SNil
ldet_5_5__insert_sorted wm dw a la (b :: bs) (SCons ab sb) (lb :: lbs) na with (ldet_5_5__before wm (atuple a) (atuple b)) proof p
  ldet_5_5__insert_sorted wm dw a la (b :: bs) (SCons ab sb) (lb :: lbs) na | True =
    SCons (p :: lcyc_1_1__all_imp bs (\b', bb' => ldet_5_5__before_trans wm (atuple a) (atuple b) (atuple b') p bb') ab) (SCons ab sb)
  ldet_5_5__insert_sorted wm dw a la (b :: bs) (SCons ab sb) (lb :: lbs) na | False =
    let ba : (ldet_5_5__before wm (atuple b) (atuple a) = True)
        ba = case ldet_5_5__before_total wm dw (atuple a) (atuple b) la lb (\eq => na (replace {p = \z => Elem z (atuple b :: iret_8_1__tuples bs)} (sym eq) Here)) of
               Left q  => absurd (trans (sym p) q)
               Right q => q
    in SCons (ldet_5_5__insert_all wm (\b' => ldet_5_5__before wm (atuple b) (atuple b') = True) a bs ba ab)
             (ldet_5_5__insert_sorted wm dw a la bs sb lbs (\e => na (There e)))

--@derives [IRET.8.1]
--@derives [LDET.5.5]
||| ACTIVATION KEEPS THE ORDER: distinct live new matches, none already
||| held, each take their place.
export
iret_8_1__activate_sorted : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (new : List Iret_7_1__token) -> Iret_11_3__distinct new -> All (Ldet_5_5__live wm) new ->
                            (acts : List Iret_8_1__act) -> Ldet_5_5__sorted wm acts -> Ldet_5_5__live_acts wm acts ->
                            ((t : Iret_7_1__token) -> Elem t new -> Not (Elem t (iret_8_1__tuples acts))) ->
                            ( Ldet_5_5__sorted wm (iret_8_1__activate wm new acts)
                            , Ldet_5_5__live_acts wm (iret_8_1__activate wm new acts) )
iret_8_1__activate_sorted wm dw [] DNil [] acts sa la disj = (sa, la)
iret_8_1__activate_sorted wm dw (t :: ts) (DCons nt d) (lt :: lts) acts sa la disj =
  iret_8_1__activate_sorted wm dw ts d lts (ldet_5_5__insert wm (MkAct t False) acts)
    (ldet_5_5__insert_sorted wm dw (MkAct t False) lt acts sa la (disj t Here))
    (ldet_5_5__insert_all wm (\a => Ldet_5_5__live wm (atuple a)) (MkAct t False) acts lt la)
    (\u, eu, e => case ldet_5_5__insert_elem_inv wm (MkAct t False) acts u e of
                    Left eq => nt (replace {p = \z => Elem z ts} eq eu)
                    Right r => disj u (There eu) r)

--@derives [IRET.8.1]
--@derives [LDET.5.5]
||| ENDING KEEPS THE ORDER.
export
iret_8_1__end_sorted : (wm : Rarc_5_6_4__wm) -> (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                       Ldet_5_5__sorted wm acts -> Ldet_5_5__sorted wm (iret_8_1__end gone acts)
iret_8_1__end_sorted wm gone [] SNil = SNil
iret_8_1__end_sorted wm gone (a :: as) (SCons aa sa) with (rarc_5_6_5__elem (atuple a) gone)
  iret_8_1__end_sorted wm gone (a :: as) (SCons aa sa) | True = iret_8_1__end_sorted wm gone as sa
  iret_8_1__end_sorted wm gone (a :: as) (SCons aa sa) | False =
    SCons (lcyc_1_1__all_filter (\b => not (rarc_5_6_5__elem (atuple b) gone)) as aa) (iret_8_1__end_sorted wm gone as sa)

--@derives [IRET.8.1]
export
iret_8_1__end_live : (wm : Rarc_5_6_4__wm) -> (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                     Ldet_5_5__live_acts wm acts -> Ldet_5_5__live_acts wm (iret_8_1__end gone acts)
iret_8_1__end_live wm gone acts la = lcyc_1_1__all_filter (\b => not (rarc_5_6_5__elem (atuple b) gone)) acts la

--@derives [IDAT.6.2.2]
--@derives [LDET.5.3]
||| MARKING KEEPS THE ORDER: refraction is a flag, not a key.
export
idat_6_2_2__mark_sorted : (wm : Rarc_5_6_4__wm) -> (j : Nat) -> (acts : List Iret_8_1__act) ->
                          Ldet_5_5__sorted wm acts -> Ldet_5_5__sorted wm (idat_6_2_2__mark_acts j acts)
idat_6_2_2__mark_sorted wm j [] SNil = SNil
idat_6_2_2__mark_sorted wm Z (a :: as) (SCons aa sa) =
  SCons (replace {p = \z => All (\b => ldet_5_5__before wm z (atuple b) = True) as} (sym (idat_6_2_2__mark_atuple a)) aa) sa
idat_6_2_2__mark_sorted wm (S j) (a :: as) (SCons aa sa) =
  SCons (lcyc_1_1__all_set_at idat_6_2_2__mark_act
           (\b, pb => replace {p = \z => ldet_5_5__before wm (atuple a) z = True} (sym (idat_6_2_2__mark_atuple b)) pb) j as aa)
        (idat_6_2_2__mark_sorted wm j as sa)

--@derives [IDAT.6.2.2]
export
idat_6_2_2__mark_live : (wm : Rarc_5_6_4__wm) -> (j : Nat) -> (acts : List Iret_8_1__act) ->
                        Ldet_5_5__live_acts wm acts -> Ldet_5_5__live_acts wm (idat_6_2_2__mark_acts j acts)
idat_6_2_2__mark_live wm j acts la =
  lcyc_1_1__all_set_at idat_6_2_2__mark_act (\b, pb => replace {p = \z => Ldet_5_5__live wm z} (sym (idat_6_2_2__mark_atuple b)) pb) j acts la

-- ---------------------------------------------------------------------
-- The order survives the change of working memory
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
||| A sorted terminal of live activations is sorted under the working
||| memory after an assertion.
export
ldet_5_5__sorted_append : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (acts : List Iret_8_1__act) ->
                          Ldet_5_5__live_acts wm acts -> Ldet_5_5__sorted wm acts -> Ldet_5_5__sorted (wm ++ [f]) acts
ldet_5_5__sorted_append wm f [] [] SNil = SNil
ldet_5_5__sorted_append wm f (a :: as) (la :: las) (SCons aa sa) =
  SCons (lcyc_1_1__all_from_elem as (\b, eb =>
           trans (ldet_5_5__before_append wm f (atuple a) (atuple b) la (lcyc_1_1__all_lookup las eb)) (lcyc_1_1__all_lookup aa eb)))
        (ldet_5_5__sorted_append wm f as las sa)

--@derives [LDET.5.9]
||| A sorted terminal of activations live without the retracted fact is
||| sorted under the working memory after the retraction: the survivors
||| keep their order.
export
ldet_5_9__sorted_remove : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                          (acts : List Iret_8_1__act) -> Ldet_5_5__live_acts wm acts -> All (\a => Not (Elem f (atuple a))) acts ->
                          Ldet_5_5__sorted wm acts -> Ldet_5_5__sorted (rarc_5_6_4__remove_exact f wm) acts
ldet_5_9__sorted_remove wm dw f ef [] [] [] SNil = SNil
ldet_5_9__sorted_remove wm dw f ef (a :: as) (la :: las) (na :: nas) (SCons aa sa) =
  SCons (lcyc_1_1__all_from_elem as (\b, eb =>
           trans (ldet_5_9__before_remove wm dw f ef (atuple a) (atuple b) la (lcyc_1_1__all_lookup las eb) na (lcyc_1_1__all_lookup nas eb))
                 (lcyc_1_1__all_lookup aa eb)))
        (ldet_5_9__sorted_remove wm dw f ef as las nas sa)

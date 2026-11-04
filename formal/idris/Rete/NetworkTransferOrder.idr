-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE TRANSFER, PART TWO (i): THE ENUMERATION IS THE KEY'S ORDER.
||| Rete/FireLoop.idr enumerates a rule's tuples facts-outermost in
||| working-memory order and appends the new ones ([IRET.7.4], [IRET.8.1]);
||| the network sorts its terminals by the canonical key ([LDET.5.5]).
||| This module proves the two orders are one: the enumeration is
||| lexicographic in the keys, and among matches one event completes --
||| all sharing the latest position -- the key's order is the
||| lexicographic one. It also states sortedness on bare tuple lists, so
||| that a FireLoop table and a network terminal can be compared as
||| lists, and proves two sorted tuple lists with the same members are
||| the same list.
module Rete.NetworkTransferOrder

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
import Rete.NetworkAgree
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Termination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- Sortedness of bare tuple lists
-- ---------------------------------------------------------------------

--@spec [LDET.5.5]
--@spec [IRET.1.9]
||| A tuple list in agenda order under a working memory: each tuple
||| before every later one.
public export
data Ldet_5_5__sorted_tuples : Rarc_5_6_4__wm -> List Iret_7_1__token -> Type where
  STNil  : Ldet_5_5__sorted_tuples w []
  STCons : All (\t' => ldet_5_5__before w t t' = True) rest -> Ldet_5_5__sorted_tuples w rest -> Ldet_5_5__sorted_tuples w (t :: rest)

--@derives [LDET.5.5]
||| A sorted terminal's tuples are sorted.
export
ldet_5_5__sorted_tuples_of_acts : (wm : Rarc_5_6_4__wm) -> (acts : List Iret_8_1__act) -> Ldet_5_5__sorted wm acts ->
                                  Ldet_5_5__sorted_tuples wm (iret_8_1__tuples acts)
ldet_5_5__sorted_tuples_of_acts wm [] SNil = STNil
ldet_5_5__sorted_tuples_of_acts wm (a :: as) (SCons ab sa) = STCons (lcyc_1_1__all_map atuple ab) (ldet_5_5__sorted_tuples_of_acts wm as sa)

--@derives [LDET.5.5]
export
ldet_5_5__sorted_tuples_filter : (wm : Rarc_5_6_4__wm) -> (q : Iret_7_1__token -> Bool) -> (ts : List Iret_7_1__token) ->
                                 Ldet_5_5__sorted_tuples wm ts -> Ldet_5_5__sorted_tuples wm (filter q ts)
ldet_5_5__sorted_tuples_filter wm q [] STNil = STNil
ldet_5_5__sorted_tuples_filter wm q (t :: rest) (STCons al s) with (q t)
  ldet_5_5__sorted_tuples_filter wm q (t :: rest) (STCons al s) | True = STCons (lcyc_1_1__all_filter q rest al) (ldet_5_5__sorted_tuples_filter wm q rest s)
  ldet_5_5__sorted_tuples_filter wm q (t :: rest) (STCons al s) | False = ldet_5_5__sorted_tuples_filter wm q rest s

--@derives [LDET.5.5]
||| Two sorted lists, every tuple of the first before every tuple of the
||| second, append to a sorted list.
export
ldet_5_5__sorted_tuples_append : (wm : Rarc_5_6_4__wm) -> (xs, ys : List Iret_7_1__token) ->
                                 Ldet_5_5__sorted_tuples wm xs -> Ldet_5_5__sorted_tuples wm ys ->
                                 ((x : Iret_7_1__token) -> Elem x xs -> (y : Iret_7_1__token) -> Elem y ys -> ldet_5_5__before wm x y = True) ->
                                 Ldet_5_5__sorted_tuples wm (xs ++ ys)
ldet_5_5__sorted_tuples_append wm [] ys STNil sy cross = sy
ldet_5_5__sorted_tuples_append wm (x :: xs) ys (STCons al sx) sy cross =
  STCons (lcyc_1_1__all_append al (lcyc_1_1__all_from_elem ys (\y, ey => cross x Here y ey)))
         (ldet_5_5__sorted_tuples_append wm xs ys sx sy (\x', ex', y, ey => cross x' (There ex') y ey))

--@derives [LDET.5.5]
||| A sorted tuple list is distinct: the order is irreflexive.
export
ldet_5_5__sorted_tuples_distinct : (wm : Rarc_5_6_4__wm) -> (ts : List Iret_7_1__token) -> Ldet_5_5__sorted_tuples wm ts -> Iret_11_3__distinct ts
ldet_5_5__sorted_tuples_distinct wm [] STNil = DNil
ldet_5_5__sorted_tuples_distinct wm (t :: rest) (STCons al s) =
  DCons (\e => absurd (trans (sym (ldet_5_5__before_irrefl wm t)) (lcyc_1_1__all_lookup al e))) (ldet_5_5__sorted_tuples_distinct wm rest s)

--@derives [LDET.5.5]
||| The order is carried by any working memory that orders the tuples
||| the same way.
export
ldet_5_5__sorted_tuples_transport : (wm, wm' : Rarc_5_6_4__wm) -> (ts : List Iret_7_1__token) ->
                                    ((s, t : Iret_7_1__token) -> Elem s ts -> Elem t ts -> ldet_5_5__before wm' s t = ldet_5_5__before wm s t) ->
                                    Ldet_5_5__sorted_tuples wm ts -> Ldet_5_5__sorted_tuples wm' ts
ldet_5_5__sorted_tuples_transport wm wm' [] same STNil = STNil
ldet_5_5__sorted_tuples_transport wm wm' (t :: rest) same (STCons al s) =
  STCons (lcyc_1_1__all_from_elem rest (\t', e => trans (same t t' Here (There e)) (lcyc_1_1__all_lookup al e)))
         (ldet_5_5__sorted_tuples_transport wm wm' rest (\s', t', es, et => same s' t' (There es) (There et)) s)

--@derives [LDET.5.9]
||| TWO SORTED TUPLE LISTS WITH THE SAME MEMBERS ARE THE SAME LIST.
export
ldet_5_9__sorted_tuples_unique : (wm : Rarc_5_6_4__wm) -> (xs, ys : List Iret_7_1__token) ->
                                 Ldet_5_5__sorted_tuples wm xs -> Ldet_5_5__sorted_tuples wm ys -> Iret_7_4__same_set xs ys -> xs = ys
ldet_5_9__sorted_tuples_unique wm [] [] _ _ _ = Refl
ldet_5_9__sorted_tuples_unique wm [] (y :: ys) _ _ ss = absurd (snd (ss y) Here)
ldet_5_9__sorted_tuples_unique wm (x :: xs) [] _ _ ss = absurd (fst (ss x) Here)
ldet_5_9__sorted_tuples_unique wm (x :: xs) (y :: ys) (STCons ax sx) (STCons by sy) ss =
  let xy : (x = y)
      xy = case iret_11_3__elem_cons (fst (ss x) Here) of
             Left p => p
             Right ex => case iret_11_3__elem_cons (snd (ss y) Here) of
               Left q => sym q
               Right ey => absurd (trans (sym (ldet_5_5__before_asym wm x y (lcyc_1_1__all_lookup ax ey))) (lcyc_1_1__all_lookup by ex))
      nx : Not (Elem x xs)
      nx = \e => absurd (trans (sym (ldet_5_5__before_irrefl wm x)) (lcyc_1_1__all_lookup ax e))
      ny : Not (Elem y ys)
      ny = \e => absurd (trans (sym (ldet_5_5__before_irrefl wm y)) (lcyc_1_1__all_lookup by e))
      tails : Iret_7_4__same_set xs ys
      tails = \t => ( \e => case iret_11_3__elem_cons (fst (ss t) (There e)) of
                              Left eq => absurd (nx (replace {p = \z => Elem z xs} (trans eq (sym xy)) e))
                              Right r => r
                    , \e => case iret_11_3__elem_cons (snd (ss t) (There e)) of
                              Left eq => absurd (ny (replace {p = \z => Elem z ys} (trans eq xy) e))
                              Right r => r )
  in cong2 (::) xy (ldet_5_9__sorted_tuples_unique wm xs ys sx sy tails)

-- ---------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
export
ldet_5_5__pos_head : (x : Lfac_1_7_1__fact) -> (xs : Rarc_5_6_4__wm) -> ldet_5_5__pos (x :: xs) x = 0
ldet_5_5__pos_head x xs with (lfac_2_5_4__same_fact x x) proof e
  ldet_5_5__pos_head x xs | True = Refl
  ldet_5_5__pos_head x xs | False = absurd (trans (sym (lfac_2_5_4__same_fact_refl x)) e)

--@derives [LDET.5.5]
export
ldet_5_5__pos_cons_neq : (x, g : Lfac_1_7_1__fact) -> (xs : Rarc_5_6_4__wm) -> Not (x = g) -> ldet_5_5__pos (x :: xs) g = S (ldet_5_5__pos xs g)
ldet_5_5__pos_cons_neq x g xs ne with (lfac_2_5_4__same_fact x g) proof e
  ldet_5_5__pos_cons_neq x g xs ne | True = void (ne (lfac_2_5_4__same_fact_eq x g e))
  ldet_5_5__pos_cons_neq x g xs ne | False = Refl

--@derives [LDET.5.5]
||| The position of the fact appended is the length: the latest.
export
ldet_5_5__pos_last : (wm : Rarc_5_6_4__wm) -> (new : Lfac_1_7_1__fact) -> Not (Elem new wm) -> ldet_5_5__pos (wm ++ [new]) new = length wm
ldet_5_5__pos_last [] new nn = ldet_5_5__pos_head new []
ldet_5_5__pos_last (x :: xs) new nn =
  trans (ldet_5_5__pos_cons_neq x new (xs ++ [new]) (\eq => nn (replace {p = \z => Elem z (x :: xs)} eq Here)))
        (cong S (ldet_5_5__pos_last xs new (\e => nn (There e))))

--@derives [LDET.5.5]
||| A live fact's position is below the length.
export
ldet_5_5__pos_lt_length : (wm : Rarc_5_6_4__wm) -> (g : Lfac_1_7_1__fact) -> Elem g wm -> ldet_5_5__lt (ldet_5_5__pos wm g) (length wm) = True
ldet_5_5__pos_lt_length (g :: xs) g Here = rewrite ldet_5_5__pos_head g xs in Refl
ldet_5_5__pos_lt_length (x :: xs) g (There eg) with (lfac_2_5_4__same_fact x g)
  ldet_5_5__pos_lt_length (x :: xs) g (There eg) | True = Refl
  ldet_5_5__pos_lt_length (x :: xs) g (There eg) | False = ldet_5_5__pos_lt_length xs g eg

--@derives [LDET.5.5]
export
ldet_5_5__lt_succ_not : (a, b : Nat) -> ldet_5_5__lt a (S b) = True -> ldet_5_5__lt b a = False
ldet_5_5__lt_succ_not Z b h = Refl
ldet_5_5__lt_succ_not (S a) Z h = absurd h
ldet_5_5__lt_succ_not (S a) (S b) h = ldet_5_5__lt_succ_not a b h

-- ---------------------------------------------------------------------
-- The facts of a kind sit at increasing positions
-- ---------------------------------------------------------------------

--@spec [IRET.7.4]
--@spec [LDET.5.5]
||| Facts in working-memory order: each at an earlier position than every
||| later one.
public export
data Ldet_5_5__pos_sorted : Rarc_5_6_4__wm -> List Lfac_1_7_1__fact -> Type where
  PSNil  : Ldet_5_5__pos_sorted w []
  PSCons : All (\g => ldet_5_5__lt (ldet_5_5__pos w f) (ldet_5_5__pos w g) = True) rest -> Ldet_5_5__pos_sorted w rest -> Ldet_5_5__pos_sorted w (f :: rest)

--@derives [LDET.5.5]
||| Positions read in a longer working memory: a list sorted under the
||| tail, none of whose facts is the head, is sorted under the whole.
export
ldet_5_5__pos_sorted_lift : (x : Lfac_1_7_1__fact) -> (xs : Rarc_5_6_4__wm) -> (fs : List Lfac_1_7_1__fact) -> Not (Elem x fs) ->
                            Ldet_5_5__pos_sorted xs fs -> Ldet_5_5__pos_sorted (x :: xs) fs
ldet_5_5__pos_sorted_lift x xs [] nx PSNil = PSNil
ldet_5_5__pos_sorted_lift x xs (f :: rest) nx (PSCons al s) =
  PSCons (lcyc_1_1__all_from_elem rest (\g, eg =>
            rewrite ldet_5_5__pos_cons_neq x f xs (\eq => nx (replace {p = \z => Elem z (f :: rest)} (sym eq) Here)) in
            rewrite ldet_5_5__pos_cons_neq x g xs (\eq => nx (replace {p = \z => Elem z (f :: rest)} (sym eq) (There eg))) in
            lcyc_1_1__all_lookup al eg))
         (ldet_5_5__pos_sorted_lift x xs rest (\e => nx (There e)) s)

--@derives [IRET.7.4]
--@derives [LDET.5.5]
||| A sublist of a distinct working memory, taken by a test, sits at
||| increasing positions.
export
ldet_5_5__filter_pos_sorted : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (q : Lfac_1_7_1__fact -> Bool) -> Ldet_5_5__pos_sorted wm (filter q wm)
ldet_5_5__filter_pos_sorted [] DNil q = PSNil
ldet_5_5__filter_pos_sorted (x :: xs) (DCons nx d) q with (q x)
  ldet_5_5__filter_pos_sorted (x :: xs) (DCons nx d) q | True =
    PSCons (lcyc_1_1__all_from_elem (filter q xs) (\g, eg =>
              rewrite ldet_5_5__pos_head x xs in
              rewrite ldet_5_5__pos_cons_neq x g xs (\eq => nx (replace {p = \z => Elem z xs} (sym eq) (fst (lcyc_1_1__elem_filter_inv q xs eg)))) in
              Refl))
           (ldet_5_5__pos_sorted_lift x xs (filter q xs) (\e => nx (fst (lcyc_1_1__elem_filter_inv q xs e))) (ldet_5_5__filter_pos_sorted xs d q))
  ldet_5_5__filter_pos_sorted (x :: xs) (DCons nx d) q | False =
    ldet_5_5__pos_sorted_lift x xs (filter q xs) (\e => nx (fst (lcyc_1_1__elem_filter_inv q xs e))) (ldet_5_5__filter_pos_sorted xs d q)

-- ---------------------------------------------------------------------
-- The enumeration is lexicographic
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
export
ldet_5_5__lex_cons_same : (p : Nat) -> (a, b : List Nat) -> ldet_5_5__lex_lt (p :: a) (p :: b) = ldet_5_5__lex_lt a b
ldet_5_5__lex_cons_same p a b = rewrite ldet_5_5__lt_irrefl p in rewrite lcyc_1_1__nat_eq_refl p in Refl

--@derives [LDET.5.5]
export
ldet_5_5__lex_cons_lt : (p, q : Nat) -> (a, b : List Nat) -> ldet_5_5__lt p q = True -> ldet_5_5__lex_lt (p :: a) (q :: b) = True
ldet_5_5__lex_cons_lt p q a b h = rewrite h in Refl

--@spec [LDET.5.5]
--@spec [IRET.7.4]
||| A tuple list in pattern order under a working memory: each tuple's
||| key lexicographically before every later one's.
public export
data Ldet_5_5__lex_sorted : Rarc_5_6_4__wm -> List Iret_7_1__token -> Type where
  LSNil  : Ldet_5_5__lex_sorted w []
  LSCons : All (\t' => ldet_5_5__lex_lt (ldet_5_5__key w t) (ldet_5_5__key w t') = True) rest -> Ldet_5_5__lex_sorted w rest -> Ldet_5_5__lex_sorted w (t :: rest)

--@derives [LDET.5.5]
export
ldet_5_5__lex_sorted_filter : (wm : Rarc_5_6_4__wm) -> (q : Iret_7_1__token -> Bool) -> (ts : List Iret_7_1__token) ->
                              Ldet_5_5__lex_sorted wm ts -> Ldet_5_5__lex_sorted wm (filter q ts)
ldet_5_5__lex_sorted_filter wm q [] LSNil = LSNil
ldet_5_5__lex_sorted_filter wm q (t :: rest) (LSCons al s) with (q t)
  ldet_5_5__lex_sorted_filter wm q (t :: rest) (LSCons al s) | True = LSCons (lcyc_1_1__all_filter q rest al) (ldet_5_5__lex_sorted_filter wm q rest s)
  ldet_5_5__lex_sorted_filter wm q (t :: rest) (LSCons al s) | False = ldet_5_5__lex_sorted_filter wm q rest s

--@derives [LDET.5.5]
export
ldet_5_5__lex_sorted_append : (wm : Rarc_5_6_4__wm) -> (xs, ys : List Iret_7_1__token) ->
                              Ldet_5_5__lex_sorted wm xs -> Ldet_5_5__lex_sorted wm ys ->
                              ((x : Iret_7_1__token) -> Elem x xs -> (y : Iret_7_1__token) -> Elem y ys -> ldet_5_5__lex_lt (ldet_5_5__key wm x) (ldet_5_5__key wm y) = True) ->
                              Ldet_5_5__lex_sorted wm (xs ++ ys)
ldet_5_5__lex_sorted_append wm [] ys LSNil sy cross = sy
ldet_5_5__lex_sorted_append wm (x :: xs) ys (LSCons al sx) sy cross =
  LSCons (lcyc_1_1__all_append al (lcyc_1_1__all_from_elem ys (\y, ey => cross x Here y ey)))
         (ldet_5_5__lex_sorted_append wm xs ys sx sy (\x', ex', y, ey => cross x' (There ex') y ey))

--@derives [LDET.5.5]
--@derives [IRET.7.4]
||| Prefixing every tuple of a sorted list with one fact keeps it sorted:
||| the first positions agree and the rest decide.
export
ldet_5_5__lex_sorted_cons : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (ts : List Iret_7_1__token) ->
                            Ldet_5_5__lex_sorted wm ts -> Ldet_5_5__lex_sorted wm (map (f ::) ts)
ldet_5_5__lex_sorted_cons wm f [] LSNil = LSNil
ldet_5_5__lex_sorted_cons wm f (t :: rest) (LSCons al s) =
  LSCons (lcyc_1_1__all_map (f ::) (lcyc_1_1__all_imp rest (\t', h => trans (ldet_5_5__lex_cons_same (ldet_5_5__pos wm f) (ldet_5_5__key wm t) (ldet_5_5__key wm t')) h) al))
         (ldet_5_5__lex_sorted_cons wm f rest s)

--@derives [IRET.7.4]
--@derives [LDET.5.5]
||| Facts outermost: the blocks of a position-sorted fact list, each a
||| sorted list of extensions, concatenate to a sorted list.
export
iret_7_4__extend_lex_sorted : (wm : Rarc_5_6_4__wm) -> (fs : List Lfac_1_7_1__fact) -> (rest : List Iret_7_1__token) ->
                              Ldet_5_5__pos_sorted wm fs -> Ldet_5_5__lex_sorted wm rest -> Ldet_5_5__lex_sorted wm (iret_7_4__extend fs rest)
iret_7_4__extend_lex_sorted wm [] rest PSNil sr = LSNil
iret_7_4__extend_lex_sorted wm (f :: fs) rest (PSCons al s) sr =
  ldet_5_5__lex_sorted_append wm (map (f ::) rest) (iret_7_4__extend fs rest)
    (ldet_5_5__lex_sorted_cons wm f rest sr)
    (iret_7_4__extend_lex_sorted wm fs rest s sr)
    (\x, ex, y, ey =>
       let (r ** (_, xeq)) = lcyc_1_1__elem_map_inv (f ::) rest ex
           (f2 ** (ef2, ey')) = iret_7_7__elem_concat_inv (\g => map (g ::) rest) fs ey
           (r2 ** (_, yeq)) = lcyc_1_1__elem_map_inv (f2 ::) rest ey'
       in replace {p = \z => ldet_5_5__lex_lt (ldet_5_5__key wm z) (ldet_5_5__key wm y) = True} xeq
            (replace {p = \z => ldet_5_5__lex_lt (ldet_5_5__key wm (f :: r)) (ldet_5_5__key wm z) = True} yeq
               (ldet_5_5__lex_cons_lt (ldet_5_5__pos wm f) (ldet_5_5__pos wm f2) (ldet_5_5__key wm r) (ldet_5_5__key wm r2) (lcyc_1_1__all_lookup al ef2))))

--@derives [IRET.7.4]
--@derives [LDET.5.5]
||| THE ENUMERATION IS LEXICOGRAPHIC: the tuples of the positive kinds,
||| facts outermost in working-memory order, are sorted by their keys in
||| pattern order.
export
iret_7_4__tuples_lex_sorted : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (ks : List Nat) -> Ldet_5_5__lex_sorted wm (iret_7_4__tuples ks wm)
iret_7_4__tuples_lex_sorted wm dw [] = LSCons [] LSNil
iret_7_4__tuples_lex_sorted wm dw (k :: ks) =
  iret_7_4__extend_lex_sorted wm (rarc_5_6_4__facts_of_kind k wm) (iret_7_4__tuples ks wm)
    (ldet_5_5__filter_pos_sorted wm dw (\f => fkind f == k)) (iret_7_4__tuples_lex_sorted wm dw ks)

-- ---------------------------------------------------------------------
-- Pattern order is the key's order among one event's matches
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
||| Two keys completed at the same position compare by pattern order.
export
ldet_5_5__before_keys_same_latest : (ks, kt : List Nat) -> ldet_5_5__latest ks = ldet_5_5__latest kt -> ldet_5_5__before_keys ks kt = ldet_5_5__lex_lt ks kt
ldet_5_5__before_keys_same_latest ks kt eq with (ldet_5_5__lt (ldet_5_5__latest ks) (ldet_5_5__latest kt)) proof l
  ldet_5_5__before_keys_same_latest ks kt eq | True =
    absurd (trans (sym (replace {p = \z => ldet_5_5__lt z (ldet_5_5__latest kt) = False} (sym eq) (ldet_5_5__lt_irrefl (ldet_5_5__latest kt)))) l)
  ldet_5_5__before_keys_same_latest ks kt eq | False with (ldet_5_5__latest ks == ldet_5_5__latest kt) proof e
    ldet_5_5__before_keys_same_latest ks kt eq | False | True = Refl
    ldet_5_5__before_keys_same_latest ks kt eq | False | False =
      absurd (trans (sym (replace {p = \z => (z == ldet_5_5__latest kt) = False} eq e)) (lcyc_1_1__nat_eq_refl (ldet_5_5__latest kt)))

--@derives [LDET.5.5]
||| A key completed earlier comes first.
export
ldet_5_5__before_keys_lt : (ks, kt : List Nat) -> ldet_5_5__lt (ldet_5_5__latest ks) (ldet_5_5__latest kt) = True -> ldet_5_5__before_keys ks kt = True
ldet_5_5__before_keys_lt ks kt h = rewrite h in Refl

--@derives [LDET.5.5]
export
ldet_5_5__max_bounded : (x, pk : Nat) -> ldet_5_5__lt pk x = False -> ldet_5_5__max x pk = pk
ldet_5_5__max_bounded x pk h with (ldet_5_5__lt x pk) proof l
  ldet_5_5__max_bounded x pk h | True = ldet_5_5__max_lt x pk l
  ldet_5_5__max_bounded x pk h | False with (x == pk) proof e
    ldet_5_5__max_bounded x pk h | False | True = trans (ldet_5_5__max_ge x pk l) (lcyc_1_1__nat_eq_true x pk e)
    ldet_5_5__max_bounded x pk h | False | False = absurd (trans (sym (ldet_5_5__lt_tri x pk l e)) h)

--@derives [LDET.5.5]
||| The latest of a key bounded above is bounded above.
export
ldet_5_5__latest_bounded : (pk : Nat) -> (ks : List Nat) -> All (\x => ldet_5_5__lt pk x = False) ks -> ldet_5_5__lt pk (ldet_5_5__latest ks) = False
ldet_5_5__latest_bounded pk [] [] = Refl
ldet_5_5__latest_bounded pk (x :: xs) (px :: pxs) with (ldet_5_5__lt x (ldet_5_5__latest xs)) proof l
  ldet_5_5__latest_bounded pk (x :: xs) (px :: pxs) | True = rewrite ldet_5_5__max_lt x (ldet_5_5__latest xs) l in ldet_5_5__latest_bounded pk xs pxs
  ldet_5_5__latest_bounded pk (x :: xs) (px :: pxs) | False = rewrite ldet_5_5__max_ge x (ldet_5_5__latest xs) l in px

--@derives [LDET.5.5]
||| A key holding a position no other exceeds completed at it.
export
ldet_5_5__latest_of_bound : (pk : Nat) -> (ks : List Nat) -> Elem pk ks -> All (\x => ldet_5_5__lt pk x = False) ks -> ldet_5_5__latest ks = pk
ldet_5_5__latest_of_bound pk (pk :: xs) Here (px :: pxs) = ldet_5_5__max_ge pk (ldet_5_5__latest xs) (ldet_5_5__latest_bounded pk xs pxs)
ldet_5_5__latest_of_bound pk (x :: xs) (There e) (px :: pxs) =
  rewrite ldet_5_5__latest_of_bound pk xs e pxs in ldet_5_5__max_bounded x pk px

--@derives [LDET.5.5]
||| A key whose positions all lie below a bound completed below it, or
||| is empty.
export
ldet_5_5__latest_below : (pk : Nat) -> (ks : List Nat) -> All (\x => ldet_5_5__lt x pk = True) ks -> Either (ks = []) (ldet_5_5__lt (ldet_5_5__latest ks) pk = True)
ldet_5_5__latest_below pk [] [] = Left Refl
ldet_5_5__latest_below pk (x :: xs) (px :: pxs) with (ldet_5_5__lt x (ldet_5_5__latest xs)) proof l
  ldet_5_5__latest_below pk (x :: xs) (px :: pxs) | True = case ldet_5_5__latest_below pk xs pxs of
    Left nil => absurd (replace {p = \z => ldet_5_5__lt x (ldet_5_5__latest z) = True} nil l)
    Right h  => Right (rewrite ldet_5_5__max_lt x (ldet_5_5__latest xs) l in h)
  ldet_5_5__latest_below pk (x :: xs) (px :: pxs) | False = Right (rewrite ldet_5_5__max_ge x (ldet_5_5__latest xs) l in px)

--@derives [LDET.5.5]
--@derives [IRET.7.4]
||| ONE EVENT'S MATCHES, all completed at one position, are in the key's
||| order when they are in pattern order.
export
ldet_5_5__lex_to_sorted : (wm : Rarc_5_6_4__wm) -> (pk : Nat) -> (ts : List Iret_7_1__token) -> All (\t => ldet_5_5__latest (ldet_5_5__key wm t) = pk) ts ->
                          Ldet_5_5__lex_sorted wm ts -> Ldet_5_5__sorted_tuples wm ts
ldet_5_5__lex_to_sorted wm pk [] [] LSNil = STNil
ldet_5_5__lex_to_sorted wm pk (t :: rest) (pt :: prest) (LSCons al s) =
  STCons (lcyc_1_1__all_from_elem rest (\t', e =>
            trans (ldet_5_5__before_keys_same_latest (ldet_5_5__key wm t) (ldet_5_5__key wm t') (trans pt (sym (lcyc_1_1__all_lookup prest e))))
                  (lcyc_1_1__all_lookup al e)))
         (ldet_5_5__lex_to_sorted wm pk rest prest s)

-- ---------------------------------------------------------------------
-- Tuples over a smaller working memory
-- ---------------------------------------------------------------------

--@derives [IRET.7.4]
||| A tuple of the kinds whose facts all lie in a working memory is a
||| tuple over it.
export
iret_7_4__tuples_sub : (ks : List Nat) -> (wm, wm' : Rarc_5_6_4__wm) -> (fs : List Lfac_1_7_1__fact) ->
                       Elem fs (iret_7_4__tuples ks wm') -> All (\f => Elem f wm) fs -> Elem fs (iret_7_4__tuples ks wm)
iret_7_4__tuples_sub [] wm wm' fs e lv = replace {p = \z => Elem z [[]]} (sym (iret_12__elem_singleton e)) Here
iret_7_4__tuples_sub (k :: ks) wm wm' fs e lv =
  let (f ** (ef, em)) = iret_7_7__elem_concat_inv (\g => map (g ::) (iret_7_4__tuples ks wm')) (rarc_5_6_4__facts_of_kind k wm') e
      (rest ** (er, req)) = lcyc_1_1__elem_map_inv (f ::) (iret_7_4__tuples ks wm') em
      (lf :: lrest) = replace {p = \z => All (\g => Elem g wm) z} (sym req) lv
      kf : ((fkind f == k) = True)
      kf = snd (lcyc_1_1__elem_filter_inv (\g => fkind g == k) wm' ef)
  in replace {p = \z => Elem z (iret_7_4__tuples (k :: ks) wm)} req
       (iret_12_2__elem_concat_map (\g => map (g ::) (iret_7_4__tuples ks wm)) (rarc_5_6_4__facts_of_kind k wm)
          (lcyc_1_1__elem_filter_fwd (\g => fkind g == k) wm lf kf)
          (lcyc_1_1__elem_map_fwd (f ::) (iret_7_4__tuples_sub ks wm wm' rest er lrest)))

--@derives [IRET.7.4]
||| A match over one working memory whose facts are live in another is
||| a match over that one: the guard reads the facts alone.
export
iret_7_4__match_sub : (r : Lgra_6_1__rule) -> (wm, wm' : Rarc_5_6_4__wm) -> (fs : List Lfac_1_7_1__fact) ->
                      Elem fs (iret_7_4__match_tuples r wm') -> All (\f => Elem f wm) fs -> Elem fs (iret_7_4__match_tuples r wm)
iret_7_4__match_sub r wm wm' fs e lv =
  let (es, gd) = lcyc_1_1__elem_filter_inv (guard r) (iret_7_4__tuples (posKinds r) wm') e
  in lcyc_1_1__elem_filter_fwd (guard r) (iret_7_4__tuples (posKinds r) wm) (iret_7_4__tuples_sub (posKinds r) wm wm' fs es lv) gd

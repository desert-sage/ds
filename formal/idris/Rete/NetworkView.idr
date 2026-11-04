-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The view theorem for Rete/Network.idr: every alpha memory is the facts
||| of its schema passing its tests [IRET.6.1], every left memory is what
||| its left parent passes [IRET.7.4], every NOT node's counts are its
||| blockers [IRET.7.9.4], and every terminal holds exactly the rule's
||| matches [IRET.8.1] — after any history, incremental propagation
||| [IRET.7.7] equals the recompute RARC.5.6.5.
|||
||| NORMATIVE COMPANION to Rete/Network.idr. The relation is
||| `Iret_7_7__consistent`, stated per chain relative to the front the
||| chain receives and to the alpha memories as they stand, so that the
||| four propagation paths can be proved one node at a time and alpha
||| dispatch one alpha at a time; the working-memory view closes the loop
||| at the top level.
module Rete.NetworkView

import Rete.FireLoop
import Rete.Network
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- Fact and token equality
-- ---------------------------------------------------------------------

--@derives [LFAC.2.5.4]
||| Field-wise equality is equality.
export
lfac_2_5_4__same_fact_eq : (g, f : Lfac_1_7_1__fact) -> lfac_2_5_4__same_fact g f = True -> g = f
lfac_2_5_4__same_fact_eq (MkFact i k y p) (MkFact i' k' y' p') prf =
  let r1 = lcyc_1_1__and_true_r (i == i') _ prf
      r2 = lcyc_1_1__and_true_r (k == k') _ r1
  in rewrite lcyc_1_1__nat_eq_true i i' (lcyc_1_1__and_true_l (i == i') _ prf) in
     rewrite lcyc_1_1__nat_eq_true k k' (lcyc_1_1__and_true_l (k == k') _ r1) in
     rewrite lcyc_1_1__nat_eq_true y y' (lcyc_1_1__and_true_l (y == y') _ r2) in
     rewrite lcyc_1_1__nat_eq_true p p' (lcyc_1_1__and_true_r (y == y') _ r2) in Refl

--@derives [LFAC.2.5.4]
export
lfac_2_5_4__same_fact_refl : (f : Lfac_1_7_1__fact) -> lfac_2_5_4__same_fact f f = True
lfac_2_5_4__same_fact_refl (MkFact i k y p) =
  rewrite lcyc_1_1__nat_eq_refl i in rewrite lcyc_1_1__nat_eq_refl k in
  rewrite lcyc_1_1__nat_eq_refl y in rewrite lcyc_1_1__nat_eq_refl p in Refl

--@derives [IRET.11.3]
||| Token identity: tuple equality is equality.
export
iret_11_3__tok_eq : (s, t : Iret_7_1__token) -> (s == t) = True -> s = t
iret_11_3__tok_eq [] [] _ = Refl
iret_11_3__tok_eq [] (_ :: _) prf = absurd prf
iret_11_3__tok_eq (_ :: _) [] prf = absurd prf
iret_11_3__tok_eq (x :: xs) (y :: ys) prf =
  rewrite lfac_2_5_4__same_fact_eq x y (lcyc_1_1__and_true_l (x == y) _ prf) in
  rewrite iret_11_3__tok_eq xs ys (lcyc_1_1__and_true_r (x == y) _ prf) in Refl

--@derives [IRET.11.3]
export
iret_11_3__tok_eq_refl : (t : Iret_7_1__token) -> (t == t) = True
iret_11_3__tok_eq_refl [] = Refl
iret_11_3__tok_eq_refl (x :: xs) = rewrite lfac_2_5_4__same_fact_refl x in iret_11_3__tok_eq_refl xs

--@derives [IRET.11.3]
export
iret_11_3__tok_neq : (s, t : Iret_7_1__token) -> Not (s = t) -> (s == t) = False
iret_11_3__tok_neq s t ne = iret_12__bool_false_of _ (\p => ne (iret_11_3__tok_eq s t p))

--@derives [IRET.11.3]
||| Bool membership on token lists, both directions.
export
iret_11_3__elem_tok_true : (t : Iret_7_1__token) -> (ts : List Iret_7_1__token) -> Elem t ts -> rarc_5_6_5__elem t ts = True
iret_11_3__elem_tok_true t (t :: ts) Here = rewrite iret_11_3__tok_eq_refl t in Refl
iret_11_3__elem_tok_true t (u :: ts) (There e) with (u == t)
  iret_11_3__elem_tok_true t (u :: ts) (There e) | True = Refl
  iret_11_3__elem_tok_true t (u :: ts) (There e) | False = iret_11_3__elem_tok_true t ts e

--@derives [IRET.11.3]
export
iret_11_3__elem_tok_elem : (t : Iret_7_1__token) -> (ts : List Iret_7_1__token) -> rarc_5_6_5__elem t ts = True -> Elem t ts
iret_11_3__elem_tok_elem t [] prf = absurd prf
iret_11_3__elem_tok_elem t (u :: ts) prf with (u == t) proof ut
  iret_11_3__elem_tok_elem t (u :: ts) prf | True = rewrite sym (iret_11_3__tok_eq u t ut) in Here
  iret_11_3__elem_tok_elem t (u :: ts) prf | False = There (iret_11_3__elem_tok_elem t ts prf)

--@derives [IRET.11.3]
export
iret_11_3__elem_tok_false : (t : Iret_7_1__token) -> (ts : List Iret_7_1__token) -> rarc_5_6_5__elem t ts = False -> Not (Elem t ts)
iret_11_3__elem_tok_false t ts prf e = lcyc_1_1__bool_not_both _ (iret_11_3__elem_tok_true t ts e) prf

--@derives [IRET.11.3]
export
iret_11_3__not_elem_tok : (t : Iret_7_1__token) -> (ts : List Iret_7_1__token) -> Not (Elem t ts) -> rarc_5_6_5__elem t ts = False
iret_11_3__not_elem_tok t ts ne = iret_12__bool_false_of _ (\p => ne (iret_11_3__elem_tok_elem t ts p))

--@derives [IRET.11.3]
||| A member of a cons is the head or a member of the tail.
export
iret_11_3__elem_cons : {x, y : a} -> {ys : List a} -> Elem x (y :: ys) -> Either (x = y) (Elem x ys)
iret_11_3__elem_cons Here = Left Refl
iret_11_3__elem_cons (There e) = Right e

-- ---------------------------------------------------------------------
-- List lemmas
-- ---------------------------------------------------------------------

--@derives [IRET.7.7]
export
iret_7_7__filter_append : (p : a -> Bool) -> (xs, ys : List a) -> filter p (xs ++ ys) = filter p xs ++ filter p ys
iret_7_7__filter_append p [] ys = Refl
iret_7_7__filter_append p (x :: xs) ys with (p x)
  iret_7_7__filter_append p (x :: xs) ys | True = cong (x ::) (iret_7_7__filter_append p xs ys)
  iret_7_7__filter_append p (x :: xs) ys | False = iret_7_7__filter_append p xs ys

--@derives [IRET.7.7]
export
iret_7_7__concat_map_append : (g : a -> List b) -> (xs, ys : List a) ->
                              rarc_5_6_5__concat_map g (xs ++ ys) = rarc_5_6_5__concat_map g xs ++ rarc_5_6_5__concat_map g ys
iret_7_7__concat_map_append g [] ys = Refl
iret_7_7__concat_map_append g (x :: xs) ys =
  rewrite iret_7_7__concat_map_append g xs ys in appendAssociative (g x) (rarc_5_6_5__concat_map g xs) (rarc_5_6_5__concat_map g ys)

--@derives [IRET.7.7]
export
iret_7_7__elem_concat_inv : (g : a -> List b) -> (xs : List a) -> Elem y (rarc_5_6_5__concat_map g xs) -> (x ** (Elem x xs, Elem y (g x)))
iret_7_7__elem_concat_inv g [] e = absurd e
iret_7_7__elem_concat_inv g (x :: xs) e = case lcyc_1_1__elem_append_inv (g x) e of
  Left h  => (x ** (Here, h))
  Right r => let (x' ** (el, e')) = iret_7_7__elem_concat_inv g xs r in (x' ** (There el, e'))

--@derives [IRET.7.2]
export
iret_7_2__snoc_not_nil : (t : List a) -> (f : a) -> Not (t ++ [f] = [])
iret_7_2__snoc_not_nil [] f prf = absurd prf
iret_7_2__snoc_not_nil (x :: t) f prf = absurd prf

--@derives [IRET.7.2]
||| Extension is injective: the same extended token has the same prefix
||| and the same last fact.
export
iret_7_2__snoc_inj : (t, u : List a) -> (f, g : a) -> t ++ [f] = u ++ [g] -> (t = u, f = g)
iret_7_2__snoc_inj [] [] f g prf = (Refl, fst (consInjective prf))
iret_7_2__snoc_inj [] (y :: u) f g prf = let (_, tl) = consInjective prf in void (iret_7_2__snoc_not_nil u g (sym tl))
iret_7_2__snoc_inj (x :: t) [] f g prf = let (_, tl) = consInjective prf in void (iret_7_2__snoc_not_nil t f tl)
iret_7_2__snoc_inj (x :: t) (y :: u) f g prf =
  let (hd, tl) = consInjective prf
      (te, fe) = iret_7_2__snoc_inj t u f g tl
  in (rewrite hd in rewrite te in Refl, fe)

--@derives [IRET.7.9.1]
export
iret_7_9_1__length_snoc : (xs : List a) -> (x : a) -> length (xs ++ [x]) = S (length xs)
iret_7_9_1__length_snoc [] x = Refl
iret_7_9_1__length_snoc (y :: xs) x = cong S (iret_7_9_1__length_snoc xs x)

--@derives [IRET.8.1]
||| Inserting an activation into a terminal keeps every activation it
||| held, as it was. Shared by Rete/NetworkTransferFlags.idr and
||| Rete/NetworkTick.idr.
export
iret_8_1__insert_keeps : (wm : Rarc_5_6_4__wm) -> (a : Iret_8_1__act) -> (acts : List Iret_8_1__act) -> (b : Iret_8_1__act) ->
                         Elem b acts -> Elem b (ldet_5_5__insert wm a acts)
iret_8_1__insert_keeps wm a [] b e = absurd e
iret_8_1__insert_keeps wm a (x :: xs) b e with (ldet_5_5__before wm (atuple a) (atuple x))
  iret_8_1__insert_keeps wm a (x :: xs) b e | True = There e
  iret_8_1__insert_keeps wm a (x :: xs) _ Here | False = Here
  iret_8_1__insert_keeps wm a (x :: xs) b (There e) | False = There (iret_8_1__insert_keeps wm a xs b e)

--@derives [LCYC.1.1]
||| Two tests that agree on every member filter alike. Shared by
||| Rete/NetworkAnswer.idr, Rete/WhereV5.idr and Rete/NetworkTmsCascade.idr.
export
lcyc_1_1__filter_ext_on : (p, q : a -> Bool) -> (xs : List a) -> ((x : a) -> Elem x xs -> p x = q x) -> filter p xs = filter q xs
lcyc_1_1__filter_ext_on p q [] pw = Refl
lcyc_1_1__filter_ext_on p q (x :: xs) pw =
  rewrite pw x Here in
  case iret_12__bool_split (q x) of
    Left h  => rewrite h in cong (x ::) (lcyc_1_1__filter_ext_on p q xs (\y, e => pw y (There e)))
    Right h => rewrite h in lcyc_1_1__filter_ext_on p q xs (\y, e => pw y (There e))

--@derives [LCYC.1.1]
||| Filtering twice is filtering by the conjunction.
export
lcyc_1_1__filter_filter : (p, q : a -> Bool) -> (xs : List a) -> filter q (filter p xs) = filter (\x => p x && q x) xs
lcyc_1_1__filter_filter p q [] = Refl
lcyc_1_1__filter_filter p q (x :: xs) =
  case iret_12__bool_split (p x) of
    Left pt => rewrite pt in
               case iret_12__bool_split (q x) of
                 Left qt  => rewrite qt in cong (x ::) (lcyc_1_1__filter_filter p q xs)
                 Right qf => rewrite qf in lcyc_1_1__filter_filter p q xs
    Right pf => rewrite pf in lcyc_1_1__filter_filter p q xs

-- ---------------------------------------------------------------------
-- Distinct lists
-- ---------------------------------------------------------------------

--@derives [IRET.11.3]
||| No two entries with the same identity.
public export
data Iret_11_3__distinct : List a -> Type where
  DNil  : Iret_11_3__distinct []
  DCons : Not (Elem x xs) -> Iret_11_3__distinct xs -> Iret_11_3__distinct (x :: xs)

--@derives [IRET.11.3]
export
iret_11_3__distinct_filter : (p : a -> Bool) -> (xs : List a) -> Iret_11_3__distinct xs -> Iret_11_3__distinct (filter p xs)
iret_11_3__distinct_filter p [] DNil = DNil
iret_11_3__distinct_filter p (x :: xs) (DCons nx d) with (p x)
  iret_11_3__distinct_filter p (x :: xs) (DCons nx d) | True =
    DCons (\e => nx (fst (lcyc_1_1__elem_filter_inv p xs e))) (iret_11_3__distinct_filter p xs d)
  iret_11_3__distinct_filter p (x :: xs) (DCons nx d) | False = iret_11_3__distinct_filter p xs d

--@derives [IRET.11.3]
export
iret_11_3__distinct_append : (xs, ys : List a) -> Iret_11_3__distinct xs -> Iret_11_3__distinct ys ->
                             ((x : a) -> Elem x xs -> Not (Elem x ys)) -> Iret_11_3__distinct (xs ++ ys)
iret_11_3__distinct_append [] ys DNil dy disj = dy
iret_11_3__distinct_append (x :: xs) ys (DCons nx d) dy disj =
  DCons (\e => case lcyc_1_1__elem_append_inv xs e of
                 Left l  => nx l
                 Right r => disj x Here r)
        (iret_11_3__distinct_append xs ys d dy (\y, ey => disj y (There ey)))

--@derives [IRET.11.3]
export
iret_11_3__distinct_map_inj : (h : a -> b) -> ((x, y : a) -> h x = h y -> x = y) -> (xs : List a) ->
                              Iret_11_3__distinct xs -> Iret_11_3__distinct (map h xs)
iret_11_3__distinct_map_inj h inj [] DNil = DNil
iret_11_3__distinct_map_inj h inj (x :: xs) (DCons nx d) =
  DCons (\e => let (u ** (eu, eq)) = lcyc_1_1__elem_map_inv h xs e
               in nx (replace {p = \z => Elem z xs} (inj u x eq) eu))
        (iret_11_3__distinct_map_inj h inj xs d)

--@derives [IRET.11.3]
||| A distinct list of distinct, pairwise disjoint lists concatenates to a
||| distinct list.
export
iret_11_3__distinct_concat : (g : a -> List b) -> (xs : List a) -> Iret_11_3__distinct xs ->
                             ((x : a) -> Elem x xs -> Iret_11_3__distinct (g x)) ->
                             ((x, x' : a) -> Elem x xs -> Elem x' xs -> Not (x = x') -> (y : b) -> Elem y (g x) -> Not (Elem y (g x'))) ->
                             Iret_11_3__distinct (rarc_5_6_5__concat_map g xs)
iret_11_3__distinct_concat g [] DNil dg disj = DNil
iret_11_3__distinct_concat g (x :: xs) (DCons nx d) dg disj =
  iret_11_3__distinct_append (g x) (rarc_5_6_5__concat_map g xs) (dg x Here)
    (iret_11_3__distinct_concat g xs d (\x', e => dg x' (There e)) (\x1, x2, e1, e2 => disj x1 x2 (There e1) (There e2)))
    (\y, ey, ey' => let (x' ** (ex', ey'')) = iret_7_7__elem_concat_inv g xs ey'
                    in disj x x' Here (There ex') (\eq => nx (replace {p = \z => Elem z xs} (sym eq) ex')) y ey ey'')

--@derives [IRET.11.3]
||| A sublist by filter, under a map, stays distinct.
export
iret_11_3__distinct_map_filter : (h : a -> b) -> (p : a -> Bool) -> (xs : List a) ->
                                 Iret_11_3__distinct (map h xs) -> Iret_11_3__distinct (map h (filter p xs))
iret_11_3__distinct_map_filter h p [] DNil = DNil
iret_11_3__distinct_map_filter h p (x :: xs) (DCons nx d) with (p x)
  iret_11_3__distinct_map_filter h p (x :: xs) (DCons nx d) | True =
    DCons (\e => let (u ** (eu, eq)) = lcyc_1_1__elem_map_inv h (filter p xs) e
                 in nx (replace {p = \z => Elem z (map h xs)} eq (lcyc_1_1__elem_map_fwd h (fst (lcyc_1_1__elem_filter_inv p xs eu)))))
          (iret_11_3__distinct_map_filter h p xs d)
  iret_11_3__distinct_map_filter h p (x :: xs) (DCons nx d) | False = iret_11_3__distinct_map_filter h p xs d

-- ---------------------------------------------------------------------
-- Same set
-- ---------------------------------------------------------------------

--@derives [IRET.7.4]
||| Two lists with the same members.
public export
Iret_7_4__same_set : {a : Type} -> List a -> List a -> Type
Iret_7_4__same_set xs ys = (x : a) -> (Elem x xs -> Elem x ys, Elem x ys -> Elem x xs)

--@derives [IRET.7.4]
export
iret_7_4__same_set_refl : (xs : List a) -> Iret_7_4__same_set xs xs
iret_7_4__same_set_refl xs = \x => (id, id)

--@derives [IRET.7.4]
export
iret_7_4__same_set_of_eq : (xs, ys : List a) -> xs = ys -> Iret_7_4__same_set xs ys
iret_7_4__same_set_of_eq xs xs Refl = iret_7_4__same_set_refl xs

--@derives [IRET.7.4]
export
iret_7_4__same_set_sym : (xs, ys : List a) -> Iret_7_4__same_set xs ys -> Iret_7_4__same_set ys xs
iret_7_4__same_set_sym xs ys ss = \x => (snd (ss x), fst (ss x))

--@derives [IRET.7.4]
export
iret_7_4__same_set_trans : (xs, ys, zs : List a) -> Iret_7_4__same_set xs ys -> Iret_7_4__same_set ys zs -> Iret_7_4__same_set xs zs
iret_7_4__same_set_trans xs ys zs s1 s2 = \x => (\e => fst (s2 x) (fst (s1 x) e), \e => snd (s1 x) (snd (s2 x) e))

--@derives [IRET.7.4]
export
iret_7_4__same_set_append : (xs, xs', ys, ys' : List a) -> Iret_7_4__same_set xs xs' -> Iret_7_4__same_set ys ys' ->
                            Iret_7_4__same_set (xs ++ ys) (xs' ++ ys')
iret_7_4__same_set_append xs xs' ys ys' s1 s2 = \x =>
  ( \e => case lcyc_1_1__elem_append_inv xs e of
            Left l  => lcyc_1_1__elem_append_left (fst (s1 x) l)
            Right r => lcyc_1_1__elem_append_right xs' (fst (s2 x) r)
  , \e => case lcyc_1_1__elem_append_inv xs' e of
            Left l  => lcyc_1_1__elem_append_left (snd (s1 x) l)
            Right r => lcyc_1_1__elem_append_right xs (snd (s2 x) r) )

--@derives [IRET.7.4]
export
iret_7_4__same_set_filter : (p : a -> Bool) -> (xs, ys : List a) -> Iret_7_4__same_set xs ys -> Iret_7_4__same_set (filter p xs) (filter p ys)
iret_7_4__same_set_filter p xs ys ss = \x =>
  ( \e => let (e', px) = lcyc_1_1__elem_filter_inv p xs e in lcyc_1_1__elem_filter_fwd p ys (fst (ss x) e') px
  , \e => let (e', px) = lcyc_1_1__elem_filter_inv p ys e in lcyc_1_1__elem_filter_fwd p xs (snd (ss x) e') px )

--@derives [IRET.7.4]
export
iret_7_4__same_set_concat : (g : a -> List b) -> (xs, ys : List a) -> Iret_7_4__same_set xs ys ->
                            Iret_7_4__same_set (rarc_5_6_5__concat_map g xs) (rarc_5_6_5__concat_map g ys)
iret_7_4__same_set_concat g xs ys ss = \y =>
  ( \e => let (x ** (ex, ey)) = iret_7_7__elem_concat_inv g xs e in iret_12_2__elem_concat_map g ys (fst (ss x) ex) ey
  , \e => let (x ** (ex, ey)) = iret_7_7__elem_concat_inv g ys e in iret_12_2__elem_concat_map g xs (snd (ss x) ex) ey )

-- ---------------------------------------------------------------------
-- Extension, blocking, and what a node passes on
-- ---------------------------------------------------------------------

--@derives [IRET.7.7]
||| Membership of an extended front: a token of the front plus a joining
||| fact of the memory.
export
iret_7_7__extend_elem_inv : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (front : List Iret_7_1__token) -> (y : Iret_7_1__token) ->
                            Elem y (iret_7_7__extend_front j mem front) ->
                            (t ** (f ** (Elem t front, Elem f mem, j t f = True, y = t ++ [f])))
iret_7_7__extend_elem_inv j mem front y e =
  let (t ** (et, ey)) = iret_7_7__elem_concat_inv (iret_7_2__extend_tok j mem) front e
      (f ** (ef, eq)) = lcyc_1_1__elem_map_inv (\g => t ++ [g]) (iret_7_6__joining j mem t) ey
      (efm, jf) = lcyc_1_1__elem_filter_inv (j t) mem ef
  in (t ** (f ** (et, efm, jf, sym eq)))

--@derives [IRET.7.7]
export
iret_7_7__extend_elem_fwd : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (front : List Iret_7_1__token) ->
                            (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) -> Elem t front -> Elem f mem -> j t f = True ->
                            Elem (t ++ [f]) (iret_7_7__extend_front j mem front)
iret_7_7__extend_elem_fwd j mem front t f et ef jf =
  iret_12_2__elem_concat_map (iret_7_2__extend_tok j mem) front et
    (lcyc_1_1__elem_map_fwd (\g => t ++ [g]) (lcyc_1_1__elem_filter_fwd (j t) mem ef jf))

--@derives [IRET.7.9.1]
export
iret_7_9_1__pass_elem_inv : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (front : List Iret_7_1__token) -> (y : Iret_7_1__token) ->
                            Elem y (iret_7_9_1__pass j mem front) -> (Elem y front, iret_7_9_1__blockers j mem y = 0)
iret_7_9_1__pass_elem_inv j mem front y e =
  let (e', z) = lcyc_1_1__elem_filter_inv (\t => iret_7_9_1__blockers j mem t == 0) front e in (e', lcyc_1_1__nat_eq_true _ 0 z)

--@derives [IRET.7.9.1]
export
iret_7_9_1__pass_elem_fwd : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (front : List Iret_7_1__token) -> (y : Iret_7_1__token) ->
                            Elem y front -> iret_7_9_1__blockers j mem y = 0 -> Elem y (iret_7_9_1__pass j mem front)
iret_7_9_1__pass_elem_fwd j mem front y e z = lcyc_1_1__elem_filter_fwd (\t => iret_7_9_1__blockers j mem t == 0) front e (rewrite z in Refl)

--@derives [IRET.7.7]
||| Extending a distinct front over a distinct memory is distinct.
export
iret_7_7__distinct_extend : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> Iret_11_3__distinct mem ->
                            (front : List Iret_7_1__token) -> Iret_11_3__distinct front -> Iret_11_3__distinct (iret_7_7__extend_front j mem front)
iret_7_7__distinct_extend j mem dm front df =
  iret_11_3__distinct_concat (iret_7_2__extend_tok j mem) front df
    (\t, _ => iret_11_3__distinct_map_inj (\g => t ++ [g]) (\g, h, eq => snd (iret_7_2__snoc_inj t t g h eq))
                (iret_7_6__joining j mem t) (iret_11_3__distinct_filter (j t) mem dm))
    (\t, u, _, _, ne, y, ey, ey' =>
       let (g ** (_, eqg)) = lcyc_1_1__elem_map_inv (\g => t ++ [g]) (iret_7_6__joining j mem t) ey
           (h ** (_, eqh)) = lcyc_1_1__elem_map_inv (\g => u ++ [g]) (iret_7_6__joining j mem u) ey'
       in ne (fst (iret_7_2__snoc_inj t u g h (trans eqg (sym eqh)))))

--@derives [IRET.7.7]
export
iret_7_7__next_append : (neg : Bool) -> (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (xs, ys : List Iret_7_1__token) ->
                        iret_7_7__next_of neg j mem (xs ++ ys) = iret_7_7__next_of neg j mem xs ++ iret_7_7__next_of neg j mem ys
iret_7_7__next_append True j mem xs ys = iret_7_7__filter_append _ xs ys
iret_7_7__next_append False j mem xs ys = iret_7_7__concat_map_append _ xs ys

--@derives [IRET.7.7]
export
iret_7_7__next_same_set : (neg : Bool) -> (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (xs, ys : List Iret_7_1__token) ->
                          Iret_7_4__same_set xs ys -> Iret_7_4__same_set (iret_7_7__next_of neg j mem xs) (iret_7_7__next_of neg j mem ys)
iret_7_7__next_same_set True j mem xs ys ss = iret_7_4__same_set_filter _ xs ys ss
iret_7_7__next_same_set False j mem xs ys ss = iret_7_4__same_set_concat _ xs ys ss

--@derives [IRET.7.7]
export
iret_7_7__next_distinct : (neg : Bool) -> (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> Iret_11_3__distinct mem ->
                          (front : List Iret_7_1__token) -> Iret_11_3__distinct front -> Iret_11_3__distinct (iret_7_7__next_of neg j mem front)
iret_7_7__next_distinct True j mem dm front df = iret_11_3__distinct_filter _ front df
iret_7_7__next_distinct False j mem dm front df = iret_7_7__distinct_extend j mem dm front df

--@derives [IRET.7.7]
||| What a node passes on from disjoint fronts is disjoint.
export
iret_7_7__next_disjoint : (neg : Bool) -> (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (xs, ys : List Iret_7_1__token) ->
                          ((t : Iret_7_1__token) -> Elem t ys -> Not (Elem t xs)) ->
                          (y : Iret_7_1__token) -> Elem y (iret_7_7__next_of neg j mem ys) -> Not (Elem y (iret_7_7__next_of neg j mem xs))
iret_7_7__next_disjoint True j mem xs ys disj y ey ex =
  disj y (fst (iret_7_9_1__pass_elem_inv j mem ys y ey)) (fst (iret_7_9_1__pass_elem_inv j mem xs y ex))
iret_7_7__next_disjoint False j mem xs ys disj y ey ex =
  let (t ** (f ** (et, _, _, eqt))) = iret_7_7__extend_elem_inv j mem ys y ey
      (u ** (g ** (eu, _, _, equ))) = iret_7_7__extend_elem_inv j mem xs y ex
  in disj t et (replace {p = \z => Elem z xs} (sym (fst (iret_7_2__snoc_inj t u f g (trans (sym eqt) equ)))) eu)

-- ---------------------------------------------------------------------
-- Block counts
-- ---------------------------------------------------------------------

--@derives [IRET.7.9.4]
export
iret_7_9_4__count_filter_zero : (t : Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) ->
                                iret_7_9_4__count t (filter (\e => not (fst e == t)) cs) = 0
iret_7_9_4__count_filter_zero t [] = Refl
iret_7_9_4__count_filter_zero t ((u, n) :: cs) with (u == t) proof ut
  iret_7_9_4__count_filter_zero t ((u, n) :: cs) | True = iret_7_9_4__count_filter_zero t cs
  iret_7_9_4__count_filter_zero t ((u, n) :: cs) | False = rewrite ut in iret_7_9_4__count_filter_zero t cs

--@derives [IRET.7.9.4]
export
iret_7_9_4__count_filter_other : (t, u : Iret_7_1__token) -> Not (t = u) -> (cs : List (Iret_7_1__token, Nat)) ->
                                 iret_7_9_4__count t (filter (\e => not (fst e == u)) cs) = iret_7_9_4__count t cs
iret_7_9_4__count_filter_other t u ne [] = Refl
iret_7_9_4__count_filter_other t u ne ((v, n) :: cs) with (v == u) proof vu
  iret_7_9_4__count_filter_other t u ne ((v, n) :: cs) | True =
    rewrite iret_11_3__tok_neq v t (\eq => ne (trans (sym eq) (iret_11_3__tok_eq v u vu))) in iret_7_9_4__count_filter_other t u ne cs
  iret_7_9_4__count_filter_other t u ne ((v, n) :: cs) | False with (v == t)
    iret_7_9_4__count_filter_other t u ne ((v, n) :: cs) | False | True = Refl
    iret_7_9_4__count_filter_other t u ne ((v, n) :: cs) | False | False = iret_7_9_4__count_filter_other t u ne cs

--@derives [IRET.7.9.4]
export
iret_7_9_4__count_set_eq : (t : Iret_7_1__token) -> (n : Nat) -> (cs : List (Iret_7_1__token, Nat)) ->
                           iret_7_9_4__count t (iret_7_9_4__set_count t n cs) = n
iret_7_9_4__count_set_eq t n cs with (n == 0) proof nz
  iret_7_9_4__count_set_eq t n cs | True = rewrite lcyc_1_1__nat_eq_true n 0 nz in iret_7_9_4__count_filter_zero t cs
  iret_7_9_4__count_set_eq t n cs | False = rewrite iret_11_3__tok_eq_refl t in Refl

--@derives [IRET.7.9.4]
export
iret_7_9_4__count_set_neq : (t, u : Iret_7_1__token) -> Not (t = u) -> (n : Nat) -> (cs : List (Iret_7_1__token, Nat)) ->
                            iret_7_9_4__count t (iret_7_9_4__set_count u n cs) = iret_7_9_4__count t cs
iret_7_9_4__count_set_neq t u ne n cs with (n == 0)
  iret_7_9_4__count_set_neq t u ne n cs | True = iret_7_9_4__count_filter_other t u ne cs
  iret_7_9_4__count_set_neq t u ne n cs | False =
    rewrite iret_11_3__tok_neq u t (\eq => ne (sym eq)) in iret_7_9_4__count_filter_other t u ne cs

--@derives [IRET.7.9.4]
||| Dropping entries of departed tokens leaves the others' counts.
export
iret_7_9_4__count_filter_keep : (t : Iret_7_1__token) -> (gone : List Iret_7_1__token) -> Not (Elem t gone) -> (cs : List (Iret_7_1__token, Nat)) ->
                                iret_7_9_4__count t (filter (\e => not (rarc_5_6_5__elem (fst e) gone)) cs) = iret_7_9_4__count t cs
iret_7_9_4__count_filter_keep t gone nt [] = Refl
iret_7_9_4__count_filter_keep t gone nt ((u, n) :: cs) with (rarc_5_6_5__elem u gone) proof ug
  iret_7_9_4__count_filter_keep t gone nt ((u, n) :: cs) | True =
    rewrite iret_11_3__tok_neq u t (\eq => nt (replace {p = \z => Elem z gone} eq (iret_11_3__elem_tok_elem u gone ug))) in
    iret_7_9_4__count_filter_keep t gone nt cs
  iret_7_9_4__count_filter_keep t gone nt ((u, n) :: cs) | False with (u == t)
    iret_7_9_4__count_filter_keep t gone nt ((u, n) :: cs) | False | True = Refl
    iret_7_9_4__count_filter_keep t gone nt ((u, n) :: cs) | False | False = iret_7_9_4__count_filter_keep t gone nt cs

--@derives [IRET.7.9.1]
export
iret_7_9_1__record_miss : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (ts : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) ->
                          (t : Iret_7_1__token) -> Not (Elem t ts) -> iret_7_9_4__count t (iret_7_9_1__record j mem ts cs) = iret_7_9_4__count t cs
iret_7_9_1__record_miss j mem [] cs t nt = Refl
iret_7_9_1__record_miss j mem (u :: us) cs t nt =
  trans (iret_7_9_1__record_miss j mem us _ t (\e => nt (There e)))
        (iret_7_9_4__count_set_neq t u (\eq => nt (replace {p = \z => Elem z (u :: us)} (sym eq) Here)) (iret_7_9_1__blockers j mem u) cs)

--@derives [IRET.7.9.1]
export
iret_7_9_1__record_hit : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (ts : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) ->
                         (t : Iret_7_1__token) -> Elem t ts -> iret_7_9_4__count t (iret_7_9_1__record j mem ts cs) = iret_7_9_1__blockers j mem t
iret_7_9_1__record_hit j mem (t :: us) cs t Here with (rarc_5_6_5__elem t us) proof tu
  iret_7_9_1__record_hit j mem (t :: us) cs t Here | True = iret_7_9_1__record_hit j mem us _ t (iret_11_3__elem_tok_elem t us tu)
  iret_7_9_1__record_hit j mem (t :: us) cs t Here | False =
    trans (iret_7_9_1__record_miss j mem us _ t (iret_11_3__elem_tok_false t us tu)) (iret_7_9_4__count_set_eq t (iret_7_9_1__blockers j mem t) cs)
iret_7_9_1__record_hit j mem (u :: us) cs t (There e) = iret_7_9_1__record_hit j mem us _ t e

--@derives [IRET.7.9.2]
export
iret_7_9_2__block_miss : (hit : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) -> (t : Iret_7_1__token) -> Not (Elem t hit) ->
                         iret_7_9_4__count t (iret_7_9_2__block hit cs) = iret_7_9_4__count t cs
iret_7_9_2__block_miss [] cs t nt = Refl
iret_7_9_2__block_miss (u :: us) cs t nt =
  trans (iret_7_9_2__block_miss us _ t (\e => nt (There e)))
        (iret_7_9_4__count_set_neq t u (\eq => nt (replace {p = \z => Elem z (u :: us)} (sym eq) Here)) (S (iret_7_9_4__count u cs)) cs)

--@derives [IRET.7.9.2]
export
iret_7_9_2__block_hit : (hit : List Iret_7_1__token) -> Iret_11_3__distinct hit -> (cs : List (Iret_7_1__token, Nat)) -> (t : Iret_7_1__token) -> Elem t hit ->
                        iret_7_9_4__count t (iret_7_9_2__block hit cs) = S (iret_7_9_4__count t cs)
iret_7_9_2__block_hit (t :: us) (DCons nt d) cs t Here =
  trans (iret_7_9_2__block_miss us _ t nt) (iret_7_9_4__count_set_eq t (S (iret_7_9_4__count t cs)) cs)
iret_7_9_2__block_hit (u :: us) (DCons nu d) cs t (There e) =
  trans (iret_7_9_2__block_hit us d _ t e)
        (cong S (iret_7_9_4__count_set_neq t u (\eq => nu (replace {p = \z => Elem z us} eq e)) (S (iret_7_9_4__count u cs)) cs))

--@derives [IRET.7.9.3]
export
iret_7_9_3__unblock_miss : (hit : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) -> (t : Iret_7_1__token) -> Not (Elem t hit) ->
                           iret_7_9_4__count t (iret_7_9_3__unblock hit cs) = iret_7_9_4__count t cs
iret_7_9_3__unblock_miss [] cs t nt = Refl
iret_7_9_3__unblock_miss (u :: us) cs t nt =
  trans (iret_7_9_3__unblock_miss us _ t (\e => nt (There e)))
        (iret_7_9_4__count_set_neq t u (\eq => nt (replace {p = \z => Elem z (u :: us)} (sym eq) Here)) (pred (iret_7_9_4__count u cs)) cs)

--@derives [IRET.7.9.3]
export
iret_7_9_3__unblock_hit : (hit : List Iret_7_1__token) -> Iret_11_3__distinct hit -> (cs : List (Iret_7_1__token, Nat)) -> (t : Iret_7_1__token) -> Elem t hit ->
                          iret_7_9_4__count t (iret_7_9_3__unblock hit cs) = pred (iret_7_9_4__count t cs)
iret_7_9_3__unblock_hit (t :: us) (DCons nt d) cs t Here =
  trans (iret_7_9_3__unblock_miss us _ t nt) (iret_7_9_4__count_set_eq t (pred (iret_7_9_4__count t cs)) cs)
iret_7_9_3__unblock_hit (u :: us) (DCons nu d) cs t (There e) =
  trans (iret_7_9_3__unblock_hit us d _ t e)
        (cong pred (iret_7_9_4__count_set_neq t u (\eq => nu (replace {p = \z => Elem z us} eq e)) (pred (iret_7_9_4__count u cs)) cs))

--@derives [IRET.7.9.1]
export
iret_7_9_1__blockers_hit : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) -> (t : Iret_7_1__token) -> j t f = True ->
                           iret_7_9_1__blockers j (mem ++ [f]) t = S (iret_7_9_1__blockers j mem t)
iret_7_9_1__blockers_hit j mem f t jf =
  rewrite iret_7_7__filter_append (j t) mem [f] in rewrite jf in iret_7_9_1__length_snoc (filter (j t) mem) f

--@derives [IRET.7.9.1]
export
iret_7_9_1__blockers_miss : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) -> (t : Iret_7_1__token) -> j t f = False ->
                            iret_7_9_1__blockers j (mem ++ [f]) t = iret_7_9_1__blockers j mem t
iret_7_9_1__blockers_miss j mem f t jf =
  rewrite iret_7_7__filter_append (j t) mem [f] in rewrite jf in cong length (appendNilRightNeutral (filter (j t) mem))

-- ---------------------------------------------------------------------
-- Terminals
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
export
ldet_5_5__insert_elem_inv : (wm : Rarc_5_6_4__wm) -> (a : Iret_8_1__act) -> (acts : List Iret_8_1__act) -> (t : Iret_7_1__token) ->
                            Elem t (iret_8_1__tuples (ldet_5_5__insert wm a acts)) -> Either (t = atuple a) (Elem t (iret_8_1__tuples acts))
ldet_5_5__insert_elem_inv wm a [] _ Here = Left Refl
ldet_5_5__insert_elem_inv wm a [] t (There e) = absurd e
ldet_5_5__insert_elem_inv wm a (b :: bs) t e with (ldet_5_5__before wm (atuple a) (atuple b))
  ldet_5_5__insert_elem_inv wm a (b :: bs) _ Here | True = Left Refl
  ldet_5_5__insert_elem_inv wm a (b :: bs) t (There e) | True = Right e
  ldet_5_5__insert_elem_inv wm a (b :: bs) _ Here | False = Right Here
  ldet_5_5__insert_elem_inv wm a (b :: bs) t (There e) | False = case ldet_5_5__insert_elem_inv wm a bs t e of
    Left eq => Left eq
    Right r => Right (There r)

--@derives [LDET.5.5]
export
ldet_5_5__insert_elem_here : (wm : Rarc_5_6_4__wm) -> (a : Iret_8_1__act) -> (acts : List Iret_8_1__act) -> Elem (atuple a) (iret_8_1__tuples (ldet_5_5__insert wm a acts))
ldet_5_5__insert_elem_here wm a [] = Here
ldet_5_5__insert_elem_here wm a (b :: bs) with (ldet_5_5__before wm (atuple a) (atuple b))
  ldet_5_5__insert_elem_here wm a (b :: bs) | True = Here
  ldet_5_5__insert_elem_here wm a (b :: bs) | False = There (ldet_5_5__insert_elem_here wm a bs)

--@derives [LDET.5.5]
export
ldet_5_5__insert_elem_old : (wm : Rarc_5_6_4__wm) -> (a : Iret_8_1__act) -> (acts : List Iret_8_1__act) -> (t : Iret_7_1__token) ->
                            Elem t (iret_8_1__tuples acts) -> Elem t (iret_8_1__tuples (ldet_5_5__insert wm a acts))
ldet_5_5__insert_elem_old wm a [] t e = absurd e
ldet_5_5__insert_elem_old wm a (b :: bs) t e with (ldet_5_5__before wm (atuple a) (atuple b))
  ldet_5_5__insert_elem_old wm a (b :: bs) t e | True = There e
  ldet_5_5__insert_elem_old wm a (b :: bs) _ Here | False = Here
  ldet_5_5__insert_elem_old wm a (b :: bs) t (There e) | False = There (ldet_5_5__insert_elem_old wm a bs t e)

--@derives [LDET.5.5]
export
ldet_5_5__insert_distinct : (wm : Rarc_5_6_4__wm) -> (a : Iret_8_1__act) -> (acts : List Iret_8_1__act) ->
                            Iret_11_3__distinct (iret_8_1__tuples acts) -> Not (Elem (atuple a) (iret_8_1__tuples acts)) ->
                            Iret_11_3__distinct (iret_8_1__tuples (ldet_5_5__insert wm a acts))
ldet_5_5__insert_distinct wm a [] DNil na = DCons (\e => absurd e) DNil
ldet_5_5__insert_distinct wm a (b :: bs) (DCons nb d) na with (ldet_5_5__before wm (atuple a) (atuple b))
  ldet_5_5__insert_distinct wm a (b :: bs) (DCons nb d) na | True = DCons na (DCons nb d)
  ldet_5_5__insert_distinct wm a (b :: bs) (DCons nb d) na | False =
    DCons (\e => case ldet_5_5__insert_elem_inv wm a bs (atuple b) e of
                   Left eq => na (replace {p = \z => Elem z (atuple b :: iret_8_1__tuples bs)} eq Here)
                   Right r => nb r)
          (ldet_5_5__insert_distinct wm a bs d (\e => na (There e)))

--@derives [IRET.8.1]
||| Activating new matches adds exactly them.
export
iret_8_1__activate_same_set : (wm : Rarc_5_6_4__wm) -> (new : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> (front : List Iret_7_1__token) ->
                              Iret_7_4__same_set (iret_8_1__tuples acts) front -> Iret_7_4__same_set (iret_8_1__tuples (iret_8_1__activate wm new acts)) (front ++ new)
iret_8_1__activate_same_set wm [] acts front sa = rewrite appendNilRightNeutral front in sa
iret_8_1__activate_same_set wm (t :: ts) acts front sa =
  let step : Iret_7_4__same_set (iret_8_1__tuples (ldet_5_5__insert wm (MkAct t False) acts)) (front ++ [t])
      step = \x => ( \e => case ldet_5_5__insert_elem_inv wm (MkAct t False) acts x e of
                             Left eq => replace {p = \z => Elem z (front ++ [t])} (sym eq) (lcyc_1_1__elem_append_right front Here)
                             Right r => lcyc_1_1__elem_append_left (fst (sa x) r)
                   , \e => case lcyc_1_1__elem_append_inv front e of
                             Left l  => ldet_5_5__insert_elem_old wm (MkAct t False) acts x (snd (sa x) l)
                             Right r => replace {p = \z => Elem z (iret_8_1__tuples (ldet_5_5__insert wm (MkAct t False) acts))} (sym (iret_12__elem_singleton r))
                                          (ldet_5_5__insert_elem_here wm (MkAct t False) acts) )
      ih = iret_8_1__activate_same_set wm ts (ldet_5_5__insert wm (MkAct t False) acts) (front ++ [t]) step
  in replace {p = \z => Iret_7_4__same_set (iret_8_1__tuples (iret_8_1__activate wm ts (ldet_5_5__insert wm (MkAct t False) acts))) z}
       (sym (appendAssociative front [t] ts)) ih

--@derives [IRET.8.1]
export
iret_8_1__activate_distinct : (wm : Rarc_5_6_4__wm) -> (new : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                              Iret_11_3__distinct (iret_8_1__tuples acts) -> Iret_11_3__distinct new ->
                              ((t : Iret_7_1__token) -> Elem t new -> Not (Elem t (iret_8_1__tuples acts))) ->
                              Iret_11_3__distinct (iret_8_1__tuples (iret_8_1__activate wm new acts))
iret_8_1__activate_distinct wm [] acts da DNil disj = da
iret_8_1__activate_distinct wm (t :: ts) acts da (DCons nt d) disj =
  iret_8_1__activate_distinct wm ts (ldet_5_5__insert wm (MkAct t False) acts)
    (ldet_5_5__insert_distinct wm (MkAct t False) acts da (disj t Here)) d
    (\u, eu, e => case ldet_5_5__insert_elem_inv wm (MkAct t False) acts u e of
                    Left eq => nt (replace {p = \z => Elem z ts} eq eu)
                    Right r => disj u (There eu) r)

--@derives [IRET.8.1]
export
iret_8_1__end_elem_inv : (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> (t : Iret_7_1__token) ->
                         Elem t (iret_8_1__tuples (iret_8_1__end gone acts)) -> (Elem t (iret_8_1__tuples acts), Not (Elem t gone))
iret_8_1__end_elem_inv gone [] t e = absurd e
iret_8_1__end_elem_inv gone (a :: as) t e with (rarc_5_6_5__elem (atuple a) gone) proof ag
  iret_8_1__end_elem_inv gone (a :: as) t e | True = let (e', ng) = iret_8_1__end_elem_inv gone as t e in (There e', ng)
  iret_8_1__end_elem_inv gone (a :: as) _ Here | False = (Here, iret_11_3__elem_tok_false (atuple a) gone ag)
  iret_8_1__end_elem_inv gone (a :: as) t (There e) | False = let (e', ng) = iret_8_1__end_elem_inv gone as t e in (There e', ng)

--@derives [IRET.8.1]
export
iret_8_1__end_elem_fwd : (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> (t : Iret_7_1__token) ->
                         Elem t (iret_8_1__tuples acts) -> Not (Elem t gone) -> Elem t (iret_8_1__tuples (iret_8_1__end gone acts))
iret_8_1__end_elem_fwd gone [] t e ng = absurd e
iret_8_1__end_elem_fwd gone (a :: as) t e ng with (rarc_5_6_5__elem (atuple a) gone) proof ag
  iret_8_1__end_elem_fwd gone (a :: as) _ Here ng | True = void (ng (iret_11_3__elem_tok_elem (atuple a) gone ag))
  iret_8_1__end_elem_fwd gone (a :: as) t (There e) ng | True = iret_8_1__end_elem_fwd gone as t e ng
  iret_8_1__end_elem_fwd gone (a :: as) _ Here ng | False = Here
  iret_8_1__end_elem_fwd gone (a :: as) t (There e) ng | False = There (iret_8_1__end_elem_fwd gone as t e ng)

--@derives [IRET.8.1]
||| Ending matches removes exactly them.
export
iret_8_1__end_same_set : (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> (front : List Iret_7_1__token) ->
                         Iret_7_4__same_set (iret_8_1__tuples acts) front ->
                         Iret_7_4__same_set (iret_8_1__tuples (iret_8_1__end gone acts)) (filter (\t => not (rarc_5_6_5__elem t gone)) front)
iret_8_1__end_same_set gone acts front sa = \t =>
  ( \e => let (e', ng) = iret_8_1__end_elem_inv gone acts t e
          in lcyc_1_1__elem_filter_fwd (\u => not (rarc_5_6_5__elem u gone)) front (fst (sa t) e') (iret_12__not_false _ (iret_11_3__not_elem_tok t gone ng))
  , \e => let (e', ng) = lcyc_1_1__elem_filter_inv (\u => not (rarc_5_6_5__elem u gone)) front e
          in iret_8_1__end_elem_fwd gone acts t (snd (sa t) e') (iret_11_3__elem_tok_false t gone (lcyc_1_1__not_true_is_false _ ng)) )

--@derives [IRET.8.1]
export
iret_8_1__end_distinct : (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> Iret_11_3__distinct (iret_8_1__tuples acts) ->
                         Iret_11_3__distinct (iret_8_1__tuples (iret_8_1__end gone acts))
iret_8_1__end_distinct gone acts da = iret_11_3__distinct_map_filter atuple (\a => not (rarc_5_6_5__elem (atuple a) gone)) acts da

-- ---------------------------------------------------------------------
-- The consistency relation
-- ---------------------------------------------------------------------

--@derives [IRET.6.5]
||| Every alpha memory is distinct.
public export
Iret_6_5__distinct_mems : List Iret_6_1__alpha -> Type
Iret_6_5__distinct_mems alphas = (i : Nat) -> Iret_11_3__distinct (iret_6_6__mem_at alphas i)

--@derives [IRET.7.9.4]
||| A node's counts are its blockers, over the tokens named.
public export
Iret_7_9_4__counts_ok : Iret_7_4__beta -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> Type
Iret_7_9_4__counts_ok b mem toks =
  bneg b = True -> (t : Iret_7_1__token) -> Elem t toks -> iret_7_9_4__count t (bcounts b) = iret_7_9_1__blockers (bjoin b) mem t

--@derives [IRET.7.7]
--@derives [IRET.7.4]
--@derives [IRET.7.9.4]
--@derives [IRET.8.1]
||| A chain suffix is CONSISTENT with the alpha memories and the front it
||| receives: each node's left memory is the front it receives, distinct;
||| a NOT node's counts are its blockers; and the terminal holds exactly
||| what the last node passes, distinct.
public export
Iret_7_7__consistent : List Iret_6_1__alpha -> List Iret_7_1__token -> List Iret_7_4__beta -> List Iret_8_1__act -> Type
Iret_7_7__consistent alphas front [] acts =
  (Iret_7_4__same_set (iret_8_1__tuples acts) front, Iret_11_3__distinct (iret_8_1__tuples acts))
Iret_7_7__consistent alphas front (b :: rest) acts =
  ( Iret_7_4__same_set (blmem b) front
  , Iret_11_3__distinct (blmem b)
  , Iret_7_9_4__counts_ok b (iret_6_6__mem_at alphas (balpha b)) (blmem b)
  , Iret_7_7__consistent alphas (iret_7_7__next_of (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front) rest acts )

--@derives [IRET.7.7]
||| Consistency is about the front as a set.
export
iret_7_7__consistent_same_set : (alphas : List Iret_6_1__alpha) -> (front, front' : List Iret_7_1__token) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                Iret_7_4__same_set front front' -> Iret_7_7__consistent alphas front nodes acts -> Iret_7_7__consistent alphas front' nodes acts
iret_7_7__consistent_same_set alphas front front' [] acts ss (sa, da) = (iret_7_4__same_set_trans _ front front' sa ss, da)
iret_7_7__consistent_same_set alphas front front' (b :: rest) acts ss (sl, dl, cnt, rec) =
  ( iret_7_4__same_set_trans _ front front' sl ss
  , dl
  , cnt
  , iret_7_7__consistent_same_set alphas _ _ rest acts (iret_7_7__next_same_set (bneg b) (bjoin b) _ front front' ss) rec )

--@derives [IRET.7.7]
||| A NOT node's counts after storing arrivals.
export
iret_7_7__store_count : (b : Iret_7_4__beta) -> (mem : List Lfac_1_7_1__fact) -> (front : List Iret_7_1__token) -> bneg b = True -> (t : Iret_7_1__token) ->
                        iret_7_9_4__count t (bcounts (iret_7_7__store b mem front)) = iret_7_9_4__count t (iret_7_9_1__record (bjoin b) mem front (bcounts b))
iret_7_7__store_count b mem front bn t with (bneg b)
  iret_7_7__store_count b mem front bn t | True = Refl
  iret_7_7__store_count b mem front bn t | False = absurd bn

-- ---------------------------------------------------------------------
-- The wave theorems
-- ---------------------------------------------------------------------

--@derives [IRET.7.7]
--@derives [IRET.7.9.1]
||| LEFT-ACTIVATION KEEPS THE VIEW. A chain consistent with the front it
||| receives, given new arrivals not among that front, is consistent with
||| the front plus the arrivals after the wave: every node stored them,
||| every NOT node counted them, and the terminal gained exactly the
||| matches they complete.
export
iret_7_7__wave_consistent : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas ->
                            (front, new : List Iret_7_1__token) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                            Iret_7_7__consistent alphas front nodes acts -> Iret_11_3__distinct new -> ((t : Iret_7_1__token) -> Elem t new -> Not (Elem t front)) ->
                            Iret_7_7__consistent alphas (front ++ new) (fst (iret_7_7__wave wm alphas nodes new acts)) (snd (iret_7_7__wave wm alphas nodes new acts))
iret_7_7__wave_consistent wm alphas dm front new [] acts (sa, da) dn disj =
  ( iret_8_1__activate_same_set wm new acts front sa
  , iret_8_1__activate_distinct wm new acts da dn (\t, et, ea => disj t et (fst (sa t) ea)) )
iret_7_7__wave_consistent wm alphas dm front new (b :: rest) acts (sl, dl, cnt, rec) dn disj =
  let ih = iret_7_7__wave_consistent wm alphas dm
             (iret_7_7__next_of (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)
             (iret_7_7__next_of (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) new) rest acts rec
             (iret_7_7__next_distinct (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) (dm (balpha b)) new dn)
             (iret_7_7__next_disjoint (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front new disj)
  in ( iret_7_4__same_set_append (blmem b) front new new sl (iret_7_4__same_set_refl new)
     , iret_11_3__distinct_append (blmem b) new dl dn (\t, el, en => disj t en (fst (sl t) el))
     , \bn, t, e => trans (iret_7_7__store_count b (iret_6_6__mem_at alphas (balpha b)) new bn t)
                          (case lcyc_1_1__elem_append_inv (blmem b) e of
                             Left el => trans (iret_7_9_1__record_miss (bjoin b) (iret_6_6__mem_at alphas (balpha b)) new (bcounts b) t (\en => disj t en (fst (sl t) el))) (cnt bn t el)
                             Right en => iret_7_9_1__record_hit (bjoin b) (iret_6_6__mem_at alphas (balpha b)) new (bcounts b) t en)
     , replace {p = \x => Iret_7_7__consistent alphas x (fst (iret_7_7__wave wm alphas rest (iret_7_7__next b (iret_6_6__mem_at alphas (balpha b)) new) acts))
                                                        (snd (iret_7_7__wave wm alphas rest (iret_7_7__next b (iret_6_6__mem_at alphas (balpha b)) new) acts))}
               (sym (iret_7_7__next_append (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front new)) ih )

--@derives [IRET.7.8]
||| What leaves a node downstream when tokens of its front leave: each is
||| something the node passed on.
export
iret_7_8__gone_sub : (neg : Bool) -> (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) ->
                     (front, gone : List Iret_7_1__token) ->
                     (neg = True -> (t : Iret_7_1__token) -> Elem t front -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                     ((t : Iret_7_1__token) -> Elem t gone -> Elem t front) ->
                     (y : Iret_7_1__token) -> Elem y (iret_7_8__gone_of neg j cs mem gone) -> Elem y (iret_7_7__next_of neg j mem front)
iret_7_8__gone_sub True j cs mem front gone cnt sub y e =
  let (eg, z) = lcyc_1_1__elem_filter_inv (\t => iret_7_9_4__count t cs == 0) gone e
  in iret_7_9_1__pass_elem_fwd j mem front y (sub y eg) (trans (sym (cnt Refl y (sub y eg))) (lcyc_1_1__nat_eq_true _ 0 z))
iret_7_8__gone_sub False j cs mem front gone cnt sub y e =
  let (t ** (f ** (et, ef, jf, eq))) = iret_7_7__extend_elem_inv j mem gone y e
  in replace {p = \z => Elem z (iret_7_7__extend_front j mem front)} (sym eq) (iret_7_7__extend_elem_fwd j mem front t f (sub t et) ef jf)

--@derives [IRET.7.8]
||| What a node passes on after tokens leave is what it passed on, less
||| what left downstream.
export
iret_7_8__next_drop : (neg : Bool) -> (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) ->
                      (front, gone : List Iret_7_1__token) ->
                      (neg = True -> (t : Iret_7_1__token) -> Elem t front -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                      ((t : Iret_7_1__token) -> Elem t gone -> Elem t front) ->
                      Iret_7_4__same_set (iret_7_7__next_of neg j mem (filter (\t => not (rarc_5_6_5__elem t gone)) front))
                                         (filter (\t => not (rarc_5_6_5__elem t (iret_7_8__gone_of neg j cs mem gone))) (iret_7_7__next_of neg j mem front))
iret_7_8__next_drop True j cs mem front gone cnt sub = \y =>
  ( \e => let (ef, z) = iret_7_9_1__pass_elem_inv j mem (filter (\t => not (rarc_5_6_5__elem t gone)) front) y e
              (ey, ng) = lcyc_1_1__elem_filter_inv (\t => not (rarc_5_6_5__elem t gone)) front ef
          in lcyc_1_1__elem_filter_fwd (\t => not (rarc_5_6_5__elem t (filter (\u => iret_7_9_4__count u cs == 0) gone))) (iret_7_9_1__pass j mem front)
               (iret_7_9_1__pass_elem_fwd j mem front y ey z)
               (iret_12__not_false _ (iret_11_3__not_elem_tok y (filter (\u => iret_7_9_4__count u cs == 0) gone)
                  (\eg => iret_11_3__elem_tok_false y gone (lcyc_1_1__not_true_is_false _ ng) (fst (lcyc_1_1__elem_filter_inv (\u => iret_7_9_4__count u cs == 0) gone eg)))))
  , \e => let (ep, ng) = lcyc_1_1__elem_filter_inv (\t => not (rarc_5_6_5__elem t (filter (\u => iret_7_9_4__count u cs == 0) gone))) (iret_7_9_1__pass j mem front) e
              (ey, z) = iret_7_9_1__pass_elem_inv j mem front y ep
              notGone : Not (Elem y gone)
              notGone = \eg => iret_11_3__elem_tok_false y (filter (\u => iret_7_9_4__count u cs == 0) gone) (lcyc_1_1__not_true_is_false _ ng)
                                 (lcyc_1_1__elem_filter_fwd (\u => iret_7_9_4__count u cs == 0) gone eg (rewrite trans (cnt Refl y ey) z in Refl))
          in iret_7_9_1__pass_elem_fwd j mem (filter (\t => not (rarc_5_6_5__elem t gone)) front) y
               (lcyc_1_1__elem_filter_fwd (\t => not (rarc_5_6_5__elem t gone)) front ey (iret_12__not_false _ (iret_11_3__not_elem_tok y gone notGone))) z )
iret_7_8__next_drop False j cs mem front gone cnt sub = \y =>
  ( \e => let (t ** (f ** (et, ef, jf, eq))) = iret_7_7__extend_elem_inv j mem (filter (\u => not (rarc_5_6_5__elem u gone)) front) y e
              (ey, ng) = lcyc_1_1__elem_filter_inv (\u => not (rarc_5_6_5__elem u gone)) front et
          in lcyc_1_1__elem_filter_fwd (\u => not (rarc_5_6_5__elem u (iret_7_7__extend_front j mem gone))) (iret_7_7__extend_front j mem front)
               (replace {p = \z => Elem z (iret_7_7__extend_front j mem front)} (sym eq) (iret_7_7__extend_elem_fwd j mem front t f ey ef jf))
               (iret_12__not_false _ (iret_11_3__not_elem_tok y (iret_7_7__extend_front j mem gone) (\eg =>
                  let (u ** (g ** (eu, _, _, equ))) = iret_7_7__extend_elem_inv j mem gone y eg
                  in iret_11_3__elem_tok_false t gone (lcyc_1_1__not_true_is_false _ ng)
                       (replace {p = \z => Elem z gone} (sym (fst (iret_7_2__snoc_inj t u f g (trans (sym eq) equ)))) eu))))
  , \e => let (ep, ng) = lcyc_1_1__elem_filter_inv (\u => not (rarc_5_6_5__elem u (iret_7_7__extend_front j mem gone))) (iret_7_7__extend_front j mem front) e
              (t ** (f ** (et, ef, jf, eq))) = iret_7_7__extend_elem_inv j mem front y ep
              notGone : Not (Elem t gone)
              notGone = \eg => iret_11_3__elem_tok_false y (iret_7_7__extend_front j mem gone) (lcyc_1_1__not_true_is_false _ ng)
                                 (replace {p = \z => Elem z (iret_7_7__extend_front j mem gone)} (sym eq) (iret_7_7__extend_elem_fwd j mem gone t f eg ef jf))
          in replace {p = \z => Elem z (iret_7_7__extend_front j mem (filter (\u => not (rarc_5_6_5__elem u gone)) front))} (sym eq)
               (iret_7_7__extend_elem_fwd j mem (filter (\u => not (rarc_5_6_5__elem u gone)) front) t f
                  (lcyc_1_1__elem_filter_fwd (\u => not (rarc_5_6_5__elem u gone)) front et (iret_12__not_false _ (iret_11_3__not_elem_tok t gone notGone))) ef jf) )

--@derives [IRET.7.7]
--@derives [IRET.7.8]
||| LEFT-RETRACTION KEEPS THE VIEW. A chain consistent with the front it
||| receives, when tokens of that front leave, is consistent with the
||| front less those tokens after the wave: every node dropped them and
||| their counts, and the terminal lost exactly the matches they
||| completed.
export
iret_7_8__unwave_consistent : (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas ->
                              (front, gone : List Iret_7_1__token) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                              Iret_7_7__consistent alphas front nodes acts -> ((t : Iret_7_1__token) -> Elem t gone -> Elem t front) ->
                              Iret_7_7__consistent alphas (filter (\t => not (rarc_5_6_5__elem t gone)) front)
                                (fst (iret_7_8__unwave alphas nodes gone acts)) (snd (iret_7_8__unwave alphas nodes gone acts))
iret_7_8__unwave_consistent alphas dm front gone [] acts (sa, da) sub =
  (iret_8_1__end_same_set gone acts front sa, iret_8_1__end_distinct gone acts da)
iret_7_8__unwave_consistent alphas dm front gone (b :: rest) acts (sl, dl, cnt, rec) sub =
  let cnt' : (bneg b = True -> (t : Iret_7_1__token) -> Elem t front -> iret_7_9_4__count t (bcounts b) = iret_7_9_1__blockers (bjoin b) (iret_6_6__mem_at alphas (balpha b)) t)
      cnt' = \bn, t, e => cnt bn t (snd (sl t) e)
      ih = iret_7_8__unwave_consistent alphas dm
             (iret_7_7__next_of (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)
             (iret_7_8__gone_of (bneg b) (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) gone) rest acts rec
             (iret_7_8__gone_sub (bneg b) (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) front gone cnt' sub)
  in ( iret_7_4__same_set_filter _ (blmem b) front sl
     , iret_11_3__distinct_filter _ (blmem b) dl
     , \bn, t, e => let (el, ng) = lcyc_1_1__elem_filter_inv (\u => not (rarc_5_6_5__elem u gone)) (blmem b) e
                    in trans (iret_7_9_4__count_filter_keep t gone (iret_11_3__elem_tok_false t gone (lcyc_1_1__not_true_is_false _ ng)) (bcounts b)) (cnt bn t el)
     , iret_7_7__consistent_same_set alphas _ _
         (fst (iret_7_8__unwave alphas rest (iret_7_8__gone_of (bneg b) (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) gone) acts))
         (snd (iret_7_8__unwave alphas rest (iret_7_8__gone_of (bneg b) (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) gone) acts))
         (iret_7_4__same_set_sym _ _ (iret_7_8__next_drop (bneg b) (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) front gone cnt' sub)) ih )

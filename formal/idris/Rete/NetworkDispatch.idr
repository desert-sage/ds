-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE VIEW THEOREM, closed at the top: after any run of the network of
||| Rete/Network.idr — asserts, retracts, firings — every alpha memory is
||| exactly its schema's facts passing its tests [IRET.6.1], [IRET.6.5],
||| every chain is consistent with those memories [IRET.7.4], [IRET.7.9.4],
||| and every terminal holds exactly the rule's matches over working
||| memory [IRET.8.1] — the recompute of RARC.5.6.5. Alpha dispatch
||| [IRET.6.4], [IRET.1.7], [IRET.19.2] is handled one alpha at a time on
||| the path theorems of Rete/NetworkPaths.idr.
|||
||| NORMATIVE COMPANION to Rete/Network.idr.
module Rete.NetworkDispatch

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.Refcount
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
-- Alpha nodes under update
-- ---------------------------------------------------------------------

--@derives [IRET.6.6]
export
iret_6_6__alpha_at_set_eq : (i : Nat) -> (g : Iret_6_1__alpha -> Iret_6_1__alpha) -> (alphas : List Iret_6_1__alpha) -> (a : Iret_6_1__alpha) ->
                            rarc_5_6_5__nth i alphas = Just a -> iret_6_6__alpha_at (rarc_5_6_5__set_at i g alphas) i = g a
iret_6_6__alpha_at_set_eq i g alphas a nt = rewrite lcyc_1_1__nth_set_at_eq i g alphas in rewrite nt in Refl

--@derives [IRET.6.6]
export
iret_6_6__alpha_at_set_neq : (i, j : Nat) -> Not (i = j) -> (g : Iret_6_1__alpha -> Iret_6_1__alpha) -> (alphas : List Iret_6_1__alpha) ->
                             iret_6_6__alpha_at (rarc_5_6_5__set_at i g alphas) j = iret_6_6__alpha_at alphas j
iret_6_6__alpha_at_set_neq i j ne g alphas = rewrite lcyc_1_1__nth_set_at_neq i j ne g alphas in Refl

--@derives [IRET.6.6]
export
iret_6_6__alpha_at_just : (i : Nat) -> (alphas : List Iret_6_1__alpha) -> (a : Iret_6_1__alpha) -> rarc_5_6_5__nth i alphas = Just a -> iret_6_6__alpha_at alphas i = a
iret_6_6__alpha_at_just i alphas a nt = rewrite nt in Refl

--@derives [IRET.6.6]
export
iret_6_6__alpha_at_nothing : (i : Nat) -> (alphas : List Iret_6_1__alpha) -> rarc_5_6_5__nth i alphas = Nothing -> iret_6_6__alpha_at alphas i = MkAlpha 0 (\_ => False) []
iret_6_6__alpha_at_nothing i alphas nt = rewrite nt in Refl

--@derives [IRET.6.4]
||| A dangling reference admits nothing.
export
iret_6_4__admits_some : (i : Nat) -> (alphas : List Iret_6_1__alpha) -> (f : Lfac_1_7_1__fact) -> iret_6_4__admits (iret_6_6__alpha_at alphas i) f = True ->
                        (a ** rarc_5_6_5__nth i alphas = Just a)
iret_6_4__admits_some i alphas f af with (rarc_5_6_5__nth i alphas) proof nt
  iret_6_4__admits_some i alphas f af | (Just a) = (a ** Refl)
  iret_6_4__admits_some i alphas f af | Nothing = absurd (lcyc_1_1__and_true_r (fkind f == 0) False af)

--@derives [IRET.6.5]
export
iret_6_5__dummy_view : (wm : Rarc_5_6_4__wm) -> iret_6_5__view (MkAlpha 0 (\_ => False) []) wm = []
iret_6_5__dummy_view [] = Refl
iret_6_5__dummy_view (g :: gs) with (fkind g == 0)
  iret_6_5__dummy_view (g :: gs) | True = iret_6_5__dummy_view gs
  iret_6_5__dummy_view (g :: gs) | False = iret_6_5__dummy_view gs

--@derives [IRET.6.5]
||| Inserting or removing a fact leaves the node's schema and tests.
export
iret_6_5__view_insert : (f : Lfac_1_7_1__fact) -> (a : Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> iret_6_5__view (iret_6_5__insert f a) wm = iret_6_5__view a wm
iret_6_5__view_insert f a wm = lcyc_1_1__filter_ext _ _ (\g => Refl) wm

--@derives [IRET.6.5]
export
iret_6_5__view_remove : (f : Lfac_1_7_1__fact) -> (a : Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> iret_6_5__view (iret_6_5__remove f a) wm = iret_6_5__view a wm
iret_6_5__view_remove f a wm = lcyc_1_1__filter_ext _ _ (\g => Refl) wm

--@derives [IRET.6.5]
export
iret_6_5__view_append_hit : (a : Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> iret_6_4__admits a f = True ->
                            iret_6_5__view a (wm ++ [f]) = iret_6_5__view a wm ++ [f]
iret_6_5__view_append_hit a wm f af = rewrite iret_7_7__filter_append (iret_6_4__admits a) wm [f] in rewrite af in Refl

--@derives [IRET.6.5]
export
iret_6_5__view_append_miss : (a : Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> iret_6_4__admits a f = False ->
                             iret_6_5__view a (wm ++ [f]) = iret_6_5__view a wm
iret_6_5__view_append_miss a wm f af = rewrite iret_7_7__filter_append (iret_6_4__admits a) wm [f] in rewrite af in appendNilRightNeutral _

--@derives [IRET.6.5]
||| Two filters commute.
export
iret_6_5__filter_comm : (p, q : a -> Bool) -> (xs : List a) -> filter p (filter q xs) = filter q (filter p xs)
iret_6_5__filter_comm p q [] = Refl
iret_6_5__filter_comm p q (x :: xs) with (p x) proof px
  iret_6_5__filter_comm p q (x :: xs) | True with (q x) proof qx
    iret_6_5__filter_comm p q (x :: xs) | True | True = rewrite px in cong (x ::) (iret_6_5__filter_comm p q xs)
    iret_6_5__filter_comm p q (x :: xs) | True | False = iret_6_5__filter_comm p q xs
  iret_6_5__filter_comm p q (x :: xs) | False with (q x) proof qx
    iret_6_5__filter_comm p q (x :: xs) | False | True = rewrite px in iret_6_5__filter_comm p q xs
    iret_6_5__filter_comm p q (x :: xs) | False | False = iret_6_5__filter_comm p q xs

--@derives [IRET.6.5]
export
iret_6_5__view_retract : (a : Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) ->
                         iret_6_5__view a (rarc_5_6_4__remove_exact f wm) = rarc_5_6_4__remove_exact f (iret_6_5__view a wm)
iret_6_5__view_retract a wm f = iret_6_5__filter_comm (iret_6_4__admits a) (\g => not (lfac_2_5_4__same_fact g f)) wm

--@derives [IRET.6.5]
export
iret_6_5__view_retract_miss : (a : Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> iret_6_4__admits a f = False ->
                              iret_6_5__view a (rarc_5_6_4__remove_exact f wm) = iret_6_5__view a wm
iret_6_5__view_retract_miss a wm f af =
  trans (iret_6_5__view_retract a wm f)
        (rarc_5_6_4__remove_exact_absent f (iret_6_5__view a wm) (\e => lcyc_1_1__bool_not_both _ (snd (lcyc_1_1__elem_filter_inv (iret_6_4__admits a) wm e)) af))

-- ---------------------------------------------------------------------
-- Dispatch order [IRET.1.7]
-- ---------------------------------------------------------------------

--@derives [IRET.1.7]
export
iret_1_7__indices_lt : (n, i : Nat) -> Elem i (iret_1_7__indices n) -> LT i n
iret_1_7__indices_lt Z i e = absurd e
iret_1_7__indices_lt (S n) i e = case lcyc_1_1__elem_append_inv (iret_1_7__indices n) e of
  Left l  => lteSuccRight (iret_1_7__indices_lt n i l)
  Right r => rewrite iret_12__elem_singleton r in reflexive

--@derives [IRET.1.7]
export
iret_1_7__indices_all : (n, i : Nat) -> LT i n -> Elem i (iret_1_7__indices n)
iret_1_7__indices_all Z i lt = absurd lt
iret_1_7__indices_all (S n) i (LTESucc lte) with (i == n) proof eq
  iret_1_7__indices_all (S n) i (LTESucc lte) | True = rewrite lcyc_1_1__nat_eq_true i n eq in lcyc_1_1__elem_append_right (iret_1_7__indices n) Here
  iret_1_7__indices_all (S n) i (LTESucc lte) | False = lcyc_1_1__elem_append_left (iret_1_7__indices_all n i (lcyc_1_1__lte_neq_lt i n lte (lcyc_1_1__nat_neq_false i n eq)))

--@derives [IRET.1.7]
export
iret_1_7__indices_distinct : (n : Nat) -> Iret_11_3__distinct (iret_1_7__indices n)
iret_1_7__indices_distinct Z = DNil
iret_1_7__indices_distinct (S n) =
  iret_11_3__distinct_append (iret_1_7__indices n) [n] (iret_1_7__indices_distinct n) (DCons (\e => absurd e) DNil)
    (\x, e, e' => succNotLTEpred (replace {p = \z => LT z n} (iret_12__elem_singleton e') (iret_1_7__indices_lt n x e)))

--@derives [IRET.6.6]
export
iret_6_6__nth_beyond : (i : Nat) -> (xs : List a) -> Not (LT i (length xs)) -> rarc_5_6_5__nth i xs = Nothing
iret_6_6__nth_beyond i [] nl = Refl
iret_6_6__nth_beyond Z (x :: xs) nl = void (nl (LTESucc LTEZero))
iret_6_6__nth_beyond (S i) (x :: xs) nl = iret_6_6__nth_beyond i xs (\lt => nl (LTESucc lt))

-- ---------------------------------------------------------------------
-- The dispatch invariant
-- ---------------------------------------------------------------------

--@derives [IRET.6.4]
--@derives [IRET.19.2]
||| Midway through dispatch: the memories of the alphas still to visit
||| show the old working memory, the others the new; all distinct; every
||| chain consistent with the memories as they stand.
public export
Iret_6_4__dispatch_inv : Rarc_5_6_4__wm -> Rarc_5_6_4__wm -> List Nat -> Rarc_5_3_1__network -> Type
Iret_6_4__dispatch_inv old new is net =
  ( Iret_6_5__distinct_mems (nalphas net)
  , (i : Nat) -> Elem i is -> iret_6_6__mem_at (nalphas net) i = iret_6_5__view (iret_6_6__alpha_at (nalphas net) i) old
  , (i : Nat) -> Not (Elem i is) -> iret_6_6__mem_at (nalphas net) i = iret_6_5__view (iret_6_6__alpha_at (nalphas net) i) new
  , All (\c => Iret_7_7__consistent (nalphas net) [[]] (cnodes c) (cacts c)) (nchains net) )

--@derives [IRET.7.7]
||| Consistency survives any change to the activations' flags.
export
iret_7_7__consistent_tuples : (alphas : List Iret_6_1__alpha) -> (front : List Iret_7_1__token) -> (nodes : List Iret_7_4__beta) -> (acts, acts' : List Iret_8_1__act) ->
                              iret_8_1__tuples acts = iret_8_1__tuples acts' -> Iret_7_7__consistent alphas front nodes acts -> Iret_7_7__consistent alphas front nodes acts'
iret_7_7__consistent_tuples alphas front [] acts acts' eq (sa, da) =
  (replace {p = \ts => Iret_7_4__same_set ts front} eq sa, replace {p = \ts => Iret_11_3__distinct ts} eq da)
iret_7_7__consistent_tuples alphas front (b :: rest) acts acts' eq (sl, dl, cnt, rec) =
  (sl, dl, cnt, iret_7_7__consistent_tuples alphas _ rest acts acts' eq rec)

--@derives [IRET.6.4]
||| ONE ALPHA VISITED ON ASSERT, admitting the fact, keeps the invariant:
||| the fact enters its memory and every chain is right-activated.
export
iret_6_4__dispatch_assert_hit : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> Not (Elem f wm) -> Iret_11_3__distinct (wm ++ [f]) ->
                                (i : Nat) -> (is : List Nat) -> Not (Elem i is) -> (alphas : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                iret_6_4__admits (iret_6_6__alpha_at alphas i) f = True ->
                                Iret_6_4__dispatch_inv wm (wm ++ [f]) (i :: is) (MkNetwork alphas chains) ->
                                Iret_6_4__dispatch_inv wm (wm ++ [f]) is
                                  (MkNetwork (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas)
                                             (map (iret_7_7__activate_chain (wm ++ [f]) (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i f) chains))
iret_6_4__dispatch_assert_hit wm f nf dw i is ni alphas chains af (dm, pend, done, cons) =
    let (a ** nt) = iret_6_4__admits_some i alphas f af
        aEq : (iret_6_6__alpha_at alphas i = a)
        aEq = iret_6_6__alpha_at_just i alphas a nt
        aEq' : (iret_6_6__alpha_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i = iret_6_5__insert f a)
        aEq' = iret_6_6__alpha_at_set_eq i (iret_6_5__insert f) alphas a nt
        memI : (iret_6_6__mem_at alphas i = iret_6_5__view a wm)
        memI = replace {p = \x => iret_6_6__mem_at alphas i = iret_6_5__view x wm} aEq (pend i Here)
        admA : (iret_6_4__admits a f = True)
        admA = replace {p = \x => iret_6_4__admits x f = True} aEq af
        delta : (iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i = iret_6_6__mem_at alphas i ++ [f])
        delta = rewrite aEq' in rewrite aEq in Refl
        frame : ((j : Nat) -> Not (j = i) -> iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) j = iret_6_6__mem_at alphas j)
        frame = \j, ne => cong amem (iret_6_6__alpha_at_set_neq i j (\eq => ne (sym eq)) (iret_6_5__insert f) alphas)
        memI' : (iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i = iret_6_5__view (iret_6_6__alpha_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i) (wm ++ [f]))
        memI' = trans delta (trans (cong (++ [f]) memI) (trans (sym (iret_6_5__view_append_hit a wm f admA)) (sym (trans (cong (\x => iret_6_5__view x (wm ++ [f])) aEq') (iret_6_5__view_insert f a (wm ++ [f]))))))
        memJ : ((j : Nat) -> Not (j = i) -> iret_6_5__view (iret_6_6__alpha_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) j) = iret_6_5__view (iret_6_6__alpha_at alphas j))
        memJ = \j, ne => cong iret_6_5__view (iret_6_6__alpha_at_set_neq i j (\eq => ne (sym eq)) (iret_6_5__insert f) alphas)
        nfI : Not (Elem f (iret_6_6__mem_at alphas i))
        nfI = \e => nf (fst (lcyc_1_1__elem_filter_inv (iret_6_4__admits a) wm (replace {p = \z => Elem f z} memI e)))
        dm' : Iret_6_5__distinct_mems (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas)
        dm' = \j => case decEq j i of
                Yes eq => replace {p = \z => Iret_11_3__distinct (iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) z)} (sym eq)
                            (replace {p = \z => Iret_11_3__distinct z} (sym memI') (iret_11_3__distinct_filter _ (wm ++ [f]) dw))
                No ne  => replace {p = \z => Iret_11_3__distinct z} (sym (frame j ne)) (dm j)
    in ( dm'
       , \j, ej => let ne = \eq => ni (replace {p = \z => Elem z is} eq ej)
                   in trans (frame j ne) (trans (pend j (There ej)) (sym (cong (\v => v wm) (memJ j ne))))
       , \j, nj => case decEq j i of
                     Yes eq => replace {p = \z => iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) z = iret_6_5__view (iret_6_6__alpha_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) z) (wm ++ [f])} (sym eq) memI'
                     No ne  => trans (frame j ne) (trans (done j (\e => case e of
                                                                            Here => ne Refl
                                                                            There e' => nj e'))
                                                        (sym (cong (\v => v (wm ++ [f])) (memJ j ne))))
       , lcyc_1_1__all_map (iret_7_7__activate_chain (wm ++ [f]) (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i f)
           (lcyc_1_1__all_from_elem chains (\c, ec =>
              iret_7_7__right_activate_consistent (wm ++ [f]) alphas (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) dm' i f frame delta nfI
                [[]] (cnodes c) (cacts c) (lcyc_1_1__all_lookup cons ec))) )

--@derives [IRET.6.4]
||| ONE ALPHA VISITED ON ASSERT, not admitting the fact, keeps the
||| invariant: nothing changes, and that memory already shows the new
||| working memory.
export
iret_6_4__dispatch_assert_miss : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) ->
                                 (i : Nat) -> (is : List Nat) -> Not (Elem i is) -> (alphas : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                 iret_6_4__admits (iret_6_6__alpha_at alphas i) f = False ->
                                 Iret_6_4__dispatch_inv wm (wm ++ [f]) (i :: is) (MkNetwork alphas chains) ->
                                 Iret_6_4__dispatch_inv wm (wm ++ [f]) is (MkNetwork alphas chains)
iret_6_4__dispatch_assert_miss wm f i is ni alphas chains af (dm, pend, done, cons) =
    ( dm
    , \j, ej => pend j (There ej)
    , \j, nj => case decEq j i of
                  Yes eq => rewrite eq in trans (pend i Here) (sym (iret_6_5__view_append_miss (iret_6_6__alpha_at alphas i) wm f af))
                  No ne  => done j (\e => case e of
                                             Here => ne Refl
                                             There e' => nj e')
    , cons )

--@derives [IRET.6.4]
||| ALPHA DISPATCH ON ASSERT, over any distinct list of alphas to visit.
export
iret_6_4__dispatch_assert_inv : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> Not (Elem f wm) -> Iret_11_3__distinct (wm ++ [f]) ->
                                (is : List Nat) -> Iret_11_3__distinct is -> (net : Rarc_5_3_1__network) ->
                                Iret_6_4__dispatch_inv wm (wm ++ [f]) is net ->
                                Iret_6_4__dispatch_inv wm (wm ++ [f]) [] (iret_6_4__dispatch_assert (wm ++ [f]) f is net)
iret_6_4__dispatch_assert_inv wm f nf dw [] DNil net inv = inv
iret_6_4__dispatch_assert_inv wm f nf dw (i :: is) (DCons ni d) (MkNetwork alphas chains) inv with (iret_6_4__admits (iret_6_6__alpha_at alphas i) f) proof af
  iret_6_4__dispatch_assert_inv wm f nf dw (i :: is) (DCons ni d) (MkNetwork alphas chains) inv | True =
    iret_6_4__dispatch_assert_inv wm f nf dw is d
      (MkNetwork (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) (map (iret_7_7__activate_chain (wm ++ [f]) (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i f) chains))
      (iret_6_4__dispatch_assert_hit wm f nf dw i is ni alphas chains af inv)
  iret_6_4__dispatch_assert_inv wm f nf dw (i :: is) (DCons ni d) (MkNetwork alphas chains) inv | False =
    iret_6_4__dispatch_assert_inv wm f nf dw is d (MkNetwork alphas chains) (iret_6_4__dispatch_assert_miss wm f i is ni alphas chains af inv)

--@derives [IRET.19.2]
||| ONE ALPHA VISITED ON RETRACT, admitting the fact, keeps the
||| invariant: the fact leaves its memory and every chain is
||| right-retracted.
export
iret_19_2__dispatch_retract_hit : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                                  (i : Nat) -> (is : List Nat) -> Not (Elem i is) -> (alphas : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                  iret_6_4__admits (iret_6_6__alpha_at alphas i) f = True ->
                                  Iret_6_4__dispatch_inv wm (rarc_5_6_4__remove_exact f wm) (i :: is) (MkNetwork alphas chains) ->
                                  Iret_6_4__dispatch_inv wm (rarc_5_6_4__remove_exact f wm) is
                                    (MkNetwork (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas)
                                               (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i f) chains))
iret_19_2__dispatch_retract_hit wm f ef i is ni alphas chains af (dm, pend, done, cons) =
    let (a ** nt) = iret_6_4__admits_some i alphas f af
        aEq : (iret_6_6__alpha_at alphas i = a)
        aEq = iret_6_6__alpha_at_just i alphas a nt
        aEq' : (iret_6_6__alpha_at (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i = iret_6_5__remove f a)
        aEq' = iret_6_6__alpha_at_set_eq i (iret_6_5__remove f) alphas a nt
        memI : (iret_6_6__mem_at alphas i = iret_6_5__view a wm)
        memI = replace {p = \x => iret_6_6__mem_at alphas i = iret_6_5__view x wm} aEq (pend i Here)
        admA : (iret_6_4__admits a f = True)
        admA = replace {p = \x => iret_6_4__admits x f = True} aEq af
        delta : (iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i = rarc_5_6_4__remove_exact f (iret_6_6__mem_at alphas i))
        delta = rewrite aEq' in rewrite aEq in Refl
        frame : ((j : Nat) -> Not (j = i) -> iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) j = iret_6_6__mem_at alphas j)
        frame = \j, ne => cong amem (iret_6_6__alpha_at_set_neq i j (\eq => ne (sym eq)) (iret_6_5__remove f) alphas)
        memI' : (iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i = iret_6_5__view (iret_6_6__alpha_at (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i) (rarc_5_6_4__remove_exact f wm))
        memI' = trans delta (trans (cong (rarc_5_6_4__remove_exact f) memI) (trans (sym (iret_6_5__view_retract a wm f)) (sym (trans (cong (\x => iret_6_5__view x (rarc_5_6_4__remove_exact f wm)) aEq') (iret_6_5__view_remove f a (rarc_5_6_4__remove_exact f wm))))))
        memJ : ((j : Nat) -> Not (j = i) -> iret_6_5__view (iret_6_6__alpha_at (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) j) = iret_6_5__view (iret_6_6__alpha_at alphas j))
        memJ = \j, ne => cong iret_6_5__view (iret_6_6__alpha_at_set_neq i j (\eq => ne (sym eq)) (iret_6_5__remove f) alphas)
        efI : Elem f (iret_6_6__mem_at alphas i)
        efI = replace {p = \z => Elem f z} (sym memI) (lcyc_1_1__elem_filter_fwd (iret_6_4__admits a) wm ef admA)
        dm' : Iret_6_5__distinct_mems (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas)
        dm' = \j => case decEq j i of
                Yes eq => replace {p = \z => Iret_11_3__distinct (iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) z)} (sym eq)
                            (replace {p = \z => Iret_11_3__distinct z} (sym delta) (iret_11_3__distinct_filter _ (iret_6_6__mem_at alphas i) (dm i)))
                No ne  => replace {p = \z => Iret_11_3__distinct z} (sym (frame j ne)) (dm j)
    in ( dm'
       , \j, ej => let ne = \eq => ni (replace {p = \z => Elem z is} eq ej)
                   in trans (frame j ne) (trans (pend j (There ej)) (sym (cong (\v => v wm) (memJ j ne))))
       , \j, nj => case decEq j i of
                     Yes eq => replace {p = \z => iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) z = iret_6_5__view (iret_6_6__alpha_at (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) z) (rarc_5_6_4__remove_exact f wm)} (sym eq) memI'
                     No ne  => trans (frame j ne) (trans (done j (\e => case e of
                                                                            Here => ne Refl
                                                                            There e' => nj e'))
                                                        (sym (cong (\v => v (rarc_5_6_4__remove_exact f wm)) (memJ j ne))))
       , lcyc_1_1__all_map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i f)
           (lcyc_1_1__all_from_elem chains (\c, ec =>
              iret_7_7__right_retract_consistent wm alphas (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) dm dm' i f frame delta efI
                [[]] (cnodes c) (cacts c) (lcyc_1_1__all_lookup cons ec))) )

--@derives [IRET.19.2]
||| ONE ALPHA VISITED ON RETRACT, not admitting the fact, keeps the
||| invariant: the fact was never in that memory.
export
iret_19_2__dispatch_retract_miss : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) ->
                                   (i : Nat) -> (is : List Nat) -> Not (Elem i is) -> (alphas : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                   iret_6_4__admits (iret_6_6__alpha_at alphas i) f = False ->
                                   Iret_6_4__dispatch_inv wm (rarc_5_6_4__remove_exact f wm) (i :: is) (MkNetwork alphas chains) ->
                                   Iret_6_4__dispatch_inv wm (rarc_5_6_4__remove_exact f wm) is (MkNetwork alphas chains)
iret_19_2__dispatch_retract_miss wm f i is ni alphas chains af (dm, pend, done, cons) =
    ( dm
    , \j, ej => pend j (There ej)
    , \j, nj => case decEq j i of
                  Yes eq => rewrite eq in trans (pend i Here) (sym (iret_6_5__view_retract_miss (iret_6_6__alpha_at alphas i) wm f af))
                  No ne  => done j (\e => case e of
                                             Here => ne Refl
                                             There e' => nj e')
    , cons )

--@derives [IRET.19.2]
||| ALPHA DISPATCH ON RETRACT, over any distinct list of alphas to visit.
export
iret_19_2__dispatch_retract_inv : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                                  (is : List Nat) -> Iret_11_3__distinct is -> (net : Rarc_5_3_1__network) ->
                                  Iret_6_4__dispatch_inv wm (rarc_5_6_4__remove_exact f wm) is net ->
                                  Iret_6_4__dispatch_inv wm (rarc_5_6_4__remove_exact f wm) [] (iret_19_2__dispatch_retract wm f is net)
iret_19_2__dispatch_retract_inv wm f ef [] DNil net inv = inv
iret_19_2__dispatch_retract_inv wm f ef (i :: is) (DCons ni d) (MkNetwork alphas chains) inv with (iret_6_4__admits (iret_6_6__alpha_at alphas i) f) proof af
  iret_19_2__dispatch_retract_inv wm f ef (i :: is) (DCons ni d) (MkNetwork alphas chains) inv | True =
    iret_19_2__dispatch_retract_inv wm f ef is d
      (MkNetwork (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i f) chains))
      (iret_19_2__dispatch_retract_hit wm f ef i is ni alphas chains af inv)
  iret_19_2__dispatch_retract_inv wm f ef (i :: is) (DCons ni d) (MkNetwork alphas chains) inv | False =
    iret_19_2__dispatch_retract_inv wm f ef is d (MkNetwork alphas chains) (iret_19_2__dispatch_retract_miss wm f i is ni alphas chains af inv)

-- ---------------------------------------------------------------------
-- The view of an engine, and the operations that keep it
-- ---------------------------------------------------------------------

--@derives [IRET.19]
--@derives [IRET.6.1]
--@derives [IRET.8.1]
||| THE VIEW: working memory is distinct, every alpha memory is distinct
||| and is its schema's facts passing its tests, in working-memory order,
||| and every chain is consistent from the nil token.
public export
Iret_19__view : Iret_19__engine -> Type
Iret_19__view eng =
  ( Iret_11_3__distinct (ewm eng)
  , Iret_6_5__distinct_mems (nalphas (enet eng))
  , (i : Nat) -> iret_6_6__mem_at (nalphas (enet eng)) i = iret_6_5__view (iret_6_6__alpha_at (nalphas (enet eng)) i) (ewm eng)
  , All (\c => Iret_7_7__consistent (nalphas (enet eng)) [[]] (cnodes c) (cacts c)) (nchains (enet eng)) )

--@derives [IRET.1.7]
||| Before a dispatch: every alpha in the dispatch list shows the old
||| working memory; an index beyond the list is the dangling node, which
||| shows nothing under any working memory.
export
iret_1_7__dispatch_start : (old, new : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) ->
                           Iret_6_5__distinct_mems (nalphas net) ->
                           ((i : Nat) -> iret_6_6__mem_at (nalphas net) i = iret_6_5__view (iret_6_6__alpha_at (nalphas net) i) old) ->
                           All (\c => Iret_7_7__consistent (nalphas net) [[]] (cnodes c) (cacts c)) (nchains net) ->
                           Iret_6_4__dispatch_inv old new (iret_1_7__indices (length (nalphas net))) net
iret_1_7__dispatch_start old new net dm mv cons =
  ( dm
  , \i, _ => mv i
  , \i, ni => let an = iret_6_6__alpha_at_nothing i (nalphas net)
                         (iret_6_6__nth_beyond i (nalphas net) (\lt => ni (iret_1_7__indices_all (length (nalphas net)) i lt)))
              in trans (cong amem an) (sym (trans (cong (\a => iret_6_5__view a new) an) (iret_6_5__dummy_view new)))
  , cons )

--@derives [IRET.6.4]
||| After a dispatch: every alpha memory shows the new working memory.
export
iret_6_4__dispatch_finish : (old, new : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> Iret_6_4__dispatch_inv old new [] net ->
                            ( Iret_6_5__distinct_mems (nalphas net)
                            , (i : Nat) -> iret_6_6__mem_at (nalphas net) i = iret_6_5__view (iret_6_6__alpha_at (nalphas net) i) new
                            , All (\c => Iret_7_7__consistent (nalphas net) [[]] (cnodes c) (cacts c)) (nchains net) )
iret_6_4__dispatch_finish old new net (dm, _, done, cons) = (dm, \i => done i (\e => absurd e), cons)

--@derives [IRET.19.1]
--@derives [IRET.6.4]
||| INSERTING A FRESH FACT keeps the view.
export
iret_19_1__insert_view : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Not (Elem f (ewm eng)) ->
                         Iret_19__view eng -> Iret_19__view (iret_19_1__insert f eng)
iret_19_1__insert_view f (MkEngine wm net) nf (dw, dm, mv, cons) =
  let dw' : Iret_11_3__distinct (wm ++ [f])
      dw' = iret_11_3__distinct_append wm [f] dw (DCons (\e => absurd e) DNil)
              (\x, ex, e1 => nf (replace {p = \z => Elem z wm} (iret_12__elem_singleton e1) ex))
  in let (dm', mv', cons') = iret_6_4__dispatch_finish wm (wm ++ [f]) _
                               (iret_6_4__dispatch_assert_inv wm f nf dw' (iret_1_7__indices (length (nalphas net))) (iret_1_7__indices_distinct (length (nalphas net))) net
                                  (iret_1_7__dispatch_start wm (wm ++ [f]) net dm mv cons))
     in (dw', dm', mv', cons')

--@derives [IRET.19.2]
||| RETRACTING A LIVE FACT keeps the view.
export
iret_19_2__retract_view : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Elem f (ewm eng) ->
                          Iret_19__view eng -> Iret_19__view (iret_19_2__retract f eng)
iret_19_2__retract_view f (MkEngine wm net) ef (dw, dm, mv, cons) =
  let (dm', mv', cons') = iret_6_4__dispatch_finish wm (rarc_5_6_4__remove_exact f wm) _
                            (iret_19_2__dispatch_retract_inv wm f ef (iret_1_7__indices (length (nalphas net))) (iret_1_7__indices_distinct (length (nalphas net))) net
                               (iret_1_7__dispatch_start wm (rarc_5_6_4__remove_exact f wm) net dm mv cons))
  in (iret_11_3__distinct_filter _ wm dw, dm', mv', cons')

--@derives [LFAC.2.5.3]
--@derives [IRET.4.4]
||| The fact minted for an assert is not live: its id is fresh.
export
lfac_2_5_3__fresh_not_elem : (avoid : List Nat) -> (wm : Rarc_5_6_4__wm) -> (k, key, pay : Nat) ->
                             Not (Elem (MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay) wm)
lfac_2_5_3__fresh_not_elem avoid wm k key pay e =
  lcyc_1_1__bool_not_both _ (rarc_5_6_4__is_live_of (MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay) wm e) (fst (lfac_2_5_3__fresh_id_free avoid wm))

--@derives [IRET.19.1]
--@derives [LFAC.2.5.1]
--@derives [LFAC.2.5.3]
||| ASSERT UNDER THE LIFECYCLE keeps the view: a no-op changes nothing,
||| an insert is of a fresh fact, and a replace retracts a live fact then
||| inserts a fresh one.
export
iret_19_1__assert_view : (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) ->
                         Iret_19__view eng -> Iret_19__view (iret_19_1__assert life avoid k key pay eng)
iret_19_1__assert_view life avoid k key pay eng v with (life k)
  iret_19_1__assert_view life avoid k key pay eng v | Explicit =
    iret_19_1__insert_view _ eng (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) v
  iret_19_1__assert_view life avoid k key pay eng v | Relation with (iret_19_1__find_relation k key pay (ewm eng))
    iret_19_1__assert_view life avoid k key pay eng v | Relation | (Just old) = v
    iret_19_1__assert_view life avoid k key pay eng v | Relation | Nothing =
      iret_19_1__insert_view _ eng (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) v
  iret_19_1__assert_view life avoid k key pay eng v | Entity with (iret_19_1__find_entity k key (ewm eng)) proof fe
    iret_19_1__assert_view life avoid k key pay eng v | Entity | Nothing =
      iret_19_1__insert_view _ eng (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) v
    iret_19_1__assert_view life avoid k key pay eng v | Entity | (Just old) with (fpay old == pay)
      iret_19_1__assert_view life avoid k key pay eng v | Entity | (Just old) | True = v
      iret_19_1__assert_view life avoid k key pay eng v | Entity | (Just old) | False =
        iret_19_1__insert_view _ (iret_19_2__retract old eng)
          (\e => lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay (fst (rarc_5_6_4__remove_exact_elem_inv old (ewm eng) _ e)))
          (iret_19_2__retract_view old eng (snd (lcyc_1_1__find_just _ (ewm eng) fe)) v)

--@derives [LSCP.2.1.1]
||| A fact some live fact equals is live.
export
lscp_2_1_1__any_same_elem : (f : Lfac_1_7_1__fact) -> (wm : Rarc_5_6_4__wm) ->
                            rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) wm = True -> Elem f wm
lscp_2_1_1__any_same_elem f wm an =
  let (g ** (eg, sg)) = iret_12_2__any_true (\g => lfac_2_5_4__same_fact g f) wm an
  in replace {p = \z => Elem z wm} (lfac_2_5_4__same_fact_eq g f sg) eg

--@derives [LSCP.2.1.1]
||| WITHDRAW keeps the view: a retraction of a live fact, or nothing.
export
lscp_2_1_1__withdraw_view : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Iret_19__view eng -> Iret_19__view (lscp_2_1_1__withdraw f eng)
lscp_2_1_1__withdraw_view f eng v with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng)) proof an
  lscp_2_1_1__withdraw_view f eng v | True = iret_19_2__retract_view f eng (lscp_2_1_1__any_same_elem f (ewm eng) an) v
  lscp_2_1_1__withdraw_view f eng v | False = v

-- ---------------------------------------------------------------------
-- Firing keeps the view
-- ---------------------------------------------------------------------

--@derives [IDAT.6.2.2]
||| Marking an activation fired leaves its tuple.
export
idat_6_2_2__mark_atuple : (a : Iret_8_1__act) -> atuple (idat_6_2_2__mark_act a) = atuple a
idat_6_2_2__mark_atuple a with (a)
  idat_6_2_2__mark_atuple a | (MkAct t fr) = Refl

--@derives [IDAT.6.2.2]
||| Any change to one activation that leaves its tuple leaves the tuples.
export
idat_6_2_2__set_at_tuples : (g : Iret_8_1__act -> Iret_8_1__act) -> ((a : Iret_8_1__act) -> atuple (g a) = atuple a) ->
                            (j : Nat) -> (acts : List Iret_8_1__act) ->
                            iret_8_1__tuples (rarc_5_6_5__set_at j g acts) = iret_8_1__tuples acts
idat_6_2_2__set_at_tuples g h j [] = Refl
idat_6_2_2__set_at_tuples g h Z (a :: as) = cong (:: map atuple as) (h a)
idat_6_2_2__set_at_tuples g h (S j) (a :: as) = cong (atuple a ::) (idat_6_2_2__set_at_tuples g h j as)

--@derives [IDAT.6.2.2]
||| Marking an activation fired leaves the tuples.
export
idat_6_2_2__mark_tuples : (j : Nat) -> (acts : List Iret_8_1__act) ->
                          iret_8_1__tuples (idat_6_2_2__mark_acts j acts) = iret_8_1__tuples acts
idat_6_2_2__mark_tuples j acts = idat_6_2_2__set_at_tuples idat_6_2_2__mark_act idat_6_2_2__mark_atuple j acts

--@derives [IDAT.6.2.2]
export
idat_6_2_2__mark_chain_view : (alphas : List Iret_6_1__alpha) -> (j : Nat) -> (c : Rlow_4_2_1__chain) ->
                              Iret_7_7__consistent alphas [[]] (cnodes c) (cacts c) ->
                              Iret_7_7__consistent alphas [[]] (cnodes (idat_6_2_2__mark_chain j c)) (cacts (idat_6_2_2__mark_chain j c))
idat_6_2_2__mark_chain_view alphas j (MkChain nodes acts actions) cons =
  iret_7_7__consistent_tuples alphas [[]] nodes acts _ (sym (idat_6_2_2__mark_tuples j acts)) cons

--@derives [IDAT.6.2.2]
--@derives [IRET.11.3.1]
||| SETTING `fired` keeps the view.
export
idat_6_2_2__mark_net_view : (r, j : Nat) -> (eng : Iret_19__engine) -> Iret_19__view eng -> Iret_19__view (idat_6_2_2__mark_net r j eng)
idat_6_2_2__mark_net_view r j (MkEngine wm (MkNetwork alphas chains)) (dw, dm, mv, cons) =
  (dw, dm, mv, lcyc_1_1__all_set_at (idat_6_2_2__mark_chain j) (\c, pc => idat_6_2_2__mark_chain_view alphas j c pc) r chains cons)

--@derives [RARC.5.6.7]
||| ONE RHS ACTION keeps the view.
export
rarc_5_6_7__do_action_net_view : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                                 Iret_19__view eng -> Iret_19__view (rarc_5_6_7__do_action_net life bound a eng)
rarc_5_6_7__do_action_net_view life bound (Emit k value) eng v =
  iret_19_1__assert_view life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) eng v
rarc_5_6_7__do_action_net_view life bound (Withdraw i) eng v with (rarc_5_6_5__nth i bound)
  rarc_5_6_7__do_action_net_view life bound (Withdraw i) eng v | Nothing = v
  rarc_5_6_7__do_action_net_view life bound (Withdraw i) eng v | (Just f) = lscp_2_1_1__withdraw_view f eng v

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_actions_net_view : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (as : List Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                                  Iret_19__view eng -> Iret_19__view (rarc_5_6_7__do_actions_net life bound as eng)
rarc_5_6_7__do_actions_net_view life bound [] eng v = v
rarc_5_6_7__do_actions_net_view life bound (a :: as) eng v =
  rarc_5_6_7__do_actions_net_view life bound as (rarc_5_6_7__do_action_net life bound a eng) (rarc_5_6_7__do_action_net_view life bound a eng v)

--@derives [IRET.11.4]
||| ONE FIRING keeps the view.
export
iret_11_4__step_net_view : (life : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) -> Iret_19__view eng ->
                           (eng' : Iret_19__engine) -> iret_11_4__step_net life eng = Just eng' -> Iret_19__view eng'
iret_11_4__step_net_view life eng v eng' eq with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__step_net_view life eng v eng' eq | Nothing = void (absurd eq)
  iret_11_4__step_net_view life eng v eng' eq | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng)))
    iret_11_4__step_net_view life eng v eng' eq | (Just (r, j)) | Nothing = void (absurd eq)
    iret_11_4__step_net_view life eng v eng' eq | (Just (r, j)) | (Just c) with (rarc_5_6_5__nth j (cacts c))
      iret_11_4__step_net_view life eng v eng' eq | (Just (r, j)) | (Just c) | Nothing = void (absurd eq)
      iret_11_4__step_net_view life eng v eng' eq | (Just (r, j)) | (Just c) | (Just a) =
        replace {p = Iret_19__view} (iret_11_4__just_inj eq)
          (rarc_5_6_7__do_actions_net_view life (atuple a) (cactions c) (idat_6_2_2__mark_net r j eng) (idat_6_2_2__mark_net_view r j eng v))

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| A RUN keeps the view, however it halts.
export
iret_11_4__run_net_view : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) -> Iret_19__view eng ->
                          Iret_19__view (fst (iret_11_4__run_net life fuel eng))
iret_11_4__run_net_view life Z eng v = v
iret_11_4__run_net_view life (S fuel) eng v with (iret_11_4__step_net life eng) proof st
  iret_11_4__run_net_view life (S fuel) eng v | Nothing = v
  iret_11_4__run_net_view life (S fuel) eng v | (Just eng') with (iret_11_4__run_net life fuel eng') proof rr
    iret_11_4__run_net_view life (S fuel) eng v | (Just eng') | (e, h, n) =
      replace {p = \x => Iret_19__view (fst x)} rr (iret_11_4__run_net_view life fuel eng' (iret_11_4__step_net_view life eng v eng' st))

-- ---------------------------------------------------------------------
-- Histories keep the view
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.4]
||| AN INPUT keeps the view.
export
rarc_5_6_4__apply_net_view : (life : Nat -> Lscp_1_3__lifecycle) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                             Iret_19__view eng -> Iret_19__view (rarc_5_6_4__apply_net life ev eng)
rarc_5_6_4__apply_net_view life (Assert k key pay) eng v = iret_19_1__assert_view life [] k key pay eng v
rarc_5_6_4__apply_net_view life (Retract i) eng v with (rarc_5_6_4__lookup_fact i (ewm eng)) proof lk
  rarc_5_6_4__apply_net_view life (Retract i) eng v | Nothing = v
  rarc_5_6_4__apply_net_view life (Retract i) eng v | (Just f) = iret_19_2__retract_view f eng (fst (rarc_5_6_4__lookup_elem i (ewm eng) f lk)) v

--@derives [LFST.9.2.1]
export
lfst_9_2_1__boundary_net_view : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                                Iret_19__view eng -> Iret_19__view (lfst_9_2_1__boundary_net life fuel ev eng)
lfst_9_2_1__boundary_net_view life fuel ev eng v = iret_11_4__run_net_view life fuel _ (rarc_5_6_4__apply_net_view life ev eng v)

--@derives [LFST.9.2.1]
||| EVERY HISTORY keeps the view.
export
lfst_9_2_1__replay_net_view : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                            Iret_19__view eng -> Iret_19__view (lfst_9_2_1__replay_net life fuel evs eng)
lfst_9_2_1__replay_net_view life fuel [] eng v = v
lfst_9_2_1__replay_net_view life fuel (ev :: evs) eng v =
  lfst_9_2_1__replay_net_view life fuel evs _ (lfst_9_2_1__boundary_net_view life fuel ev eng v)

-- ---------------------------------------------------------------------
-- The loaded network has the view
-- ---------------------------------------------------------------------

--@derives [IRET.16.4]
||| A loaded alpha node's memory is empty.
export
iret_16_4__alpha_node_mem : (kt : (Nat, Lfac_1_7_1__fact -> Bool)) -> amem (iret_16_4__alpha_node kt) = []
iret_16_4__alpha_node_mem kt with (kt)
  iret_16_4__alpha_node_mem kt | (k, test) = Refl

--@derives [IRET.16.4]
||| Every loaded alpha memory is empty, dangling references included.
export
iret_16_4__mem_empty : (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (i : Nat) -> iret_6_6__mem_at (iret_16_4__alpha_nodes alphas) i = []
iret_16_4__mem_empty [] i = Refl
iret_16_4__mem_empty (x :: xs) Z = iret_16_4__alpha_node_mem x
iret_16_4__mem_empty (x :: xs) (S i) = iret_16_4__mem_empty xs i

--@derives [IRET.7.7]
||| A node passes nothing on from nothing.
export
iret_7_7__next_of_nil : (neg : Bool) -> (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> iret_7_7__next_of neg j mem [] = []
iret_7_7__next_of_nil True j mem = Refl
iret_7_7__next_of_nil False j mem = Refl

--@derives [IRET.16.5]
||| A loaded beta node's left memory is empty.
export
iret_16_5__beta_node_lmem : (n : (Nat, Iret_7_5__join, Bool)) -> blmem (iret_16_5__beta_node n) = []
iret_16_5__beta_node_lmem n with (n)
  iret_16_5__beta_node_lmem n | (a, j, neg) = Refl

--@derives [IRET.16.5]
||| A chain as loaded is consistent with the empty front.
export
iret_16_5__empty_consistent : (alphas : List Iret_6_1__alpha) -> (nodes : List (Nat, Iret_7_5__join, Bool)) ->
                              Iret_7_7__consistent alphas [] (iret_16_5__beta_nodes nodes) []
iret_16_5__empty_consistent alphas [] = (iret_7_4__same_set_refl [], DNil)
iret_16_5__empty_consistent alphas (n :: ns) =
  ( iret_7_4__same_set_of_eq _ _ (iret_16_5__beta_node_lmem n)
  , replace {p = \z => Iret_11_3__distinct z} (sym (iret_16_5__beta_node_lmem n)) DNil
  , \_, t, e => absurd (replace {p = \z => Elem t z} (iret_16_5__beta_node_lmem n) e)
  , replace {p = \fr => Iret_7_7__consistent alphas fr (iret_16_5__beta_nodes ns) []}
      (sym (iret_7_7__next_of_nil (bneg (iret_16_5__beta_node n)) (bjoin (iret_16_5__beta_node n)) (iret_6_6__mem_at alphas (balpha (iret_16_5__beta_node n)))))
      (iret_16_5__empty_consistent alphas ns) )

--@derives [RDSC.4a.5]
--@derives [RDSC.4a.7]
||| SEEDING keeps the view: the nil token's wave over the loaded chain.
export
rdsc_4a_5__seed_view : (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas ->
                       (r : (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                       Iret_7_7__consistent alphas [[]] (cnodes (rdsc_4a_5__seed alphas (iret_16_6__terminal r))) (cacts (rdsc_4a_5__seed alphas (iret_16_6__terminal r)))
rdsc_4a_5__seed_view alphas dm (nodes, actions) =
  iret_7_7__wave_consistent [] alphas dm [] [[]] (iret_16_5__beta_nodes nodes) []
    (iret_16_5__empty_consistent alphas nodes) (DCons (\e => absurd e) DNil) (\t, _, e => absurd e)

--@derives [RDSC.4a.5]
--@derives [IRET.18.2]
||| THE LOADED NETWORK HAS THE VIEW.
export
rdsc_4a_5__load_view : (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                       Iret_19__view (rdsc_4a_5__load alphas rules)
rdsc_4a_5__load_view alphas rules =
  let dm : Iret_6_5__distinct_mems (iret_16_4__alpha_nodes alphas)
      dm = \i => replace {p = \z => Iret_11_3__distinct z} (sym (iret_16_4__mem_empty alphas i)) DNil
  in ( DNil
     , dm
     , \i => iret_16_4__mem_empty alphas i
     , lcyc_1_1__all_map (rdsc_4a_5__seed (iret_16_4__alpha_nodes alphas))
         (lcyc_1_1__all_map iret_16_6__terminal
            (lcyc_1_1__all_from_elem rules (\r, _ => rdsc_4a_5__seed_view (iret_16_4__alpha_nodes alphas) dm r))) )

-- ---------------------------------------------------------------------
-- THE VIEW THEOREM, closed at the top
-- ---------------------------------------------------------------------

--@derives [IRET.7.7]
||| Consistency, read through the alpha view, is the recompute: the
||| terminal holds exactly what the chain passes from the front over
||| working memory.
export
iret_7_7__consistent_view : (alphas : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) ->
                            ((i : Nat) -> iret_6_6__mem_at alphas i = iret_6_5__view (iret_6_6__alpha_at alphas i) wm) ->
                            (front : List Iret_7_1__token) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                            Iret_7_7__consistent alphas front nodes acts -> Iret_7_4__same_set (iret_8_1__tuples acts) (iret_7_7__view alphas wm nodes front)
iret_7_7__consistent_view alphas wm mv front [] acts (sa, _) = sa
iret_7_7__consistent_view alphas wm mv front (b :: rest) acts (_, _, _, rec) =
  iret_7_7__consistent_view alphas wm mv _ rest acts
    (replace {p = \m => Iret_7_7__consistent alphas (iret_7_7__next_of (bneg b) (bjoin b) m front) rest acts} (mv (balpha b)) rec)

--@derives [IRET.7.7]
--@derives [IRET.11.3]
||| A consistent chain's activations are distinct.
export
iret_7_7__consistent_distinct : (alphas : List Iret_6_1__alpha) -> (front : List Iret_7_1__token) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                Iret_7_7__consistent alphas front nodes acts -> Iret_11_3__distinct (iret_8_1__tuples acts)
iret_7_7__consistent_distinct alphas front [] acts (_, da) = da
iret_7_7__consistent_distinct alphas front (b :: rest) acts (_, _, _, rec) = iret_7_7__consistent_distinct alphas _ rest acts rec

--@derives [RARC.5.6.5]
--@derives [IRET.6.1]
--@derives [IRET.8.1]
||| What the view says of an engine: every alpha memory is its schema's
||| facts passing its tests, and every terminal holds exactly its chain's
||| recompute over working memory, without duplicates.
public export
Rarc_5_6_5__recomputed : Iret_19__engine -> Type
Rarc_5_6_5__recomputed eng =
  ( (i : Nat) -> iret_6_6__mem_at (nalphas (enet eng)) i = iret_6_5__view (iret_6_6__alpha_at (nalphas (enet eng)) i) (ewm eng)
  , (c : Rlow_4_2_1__chain) -> Elem c (nchains (enet eng)) ->
      ( Iret_7_4__same_set (iret_8_1__tuples (cacts c)) (iret_7_7__view (nalphas (enet eng)) (ewm eng) (cnodes c) [[]])
      , Iret_11_3__distinct (iret_8_1__tuples (cacts c)) ) )

--@derives [RARC.5.6.5]
export
rarc_5_6_5__view_recomputed : (eng : Iret_19__engine) -> Iret_19__view eng -> Rarc_5_6_5__recomputed eng
rarc_5_6_5__view_recomputed (MkEngine wm (MkNetwork alphas chains)) (dw, dm, mv, cons) =
  ( mv
  , \c, ec => let k = lcyc_1_1__all_lookup cons ec
              in ( iret_7_7__consistent_view alphas wm mv [[]] (cnodes c) (cacts c) k
                 , iret_7_7__consistent_distinct alphas [[]] (cnodes c) (cacts c) k ) )

--@derives [RARC.5.6.5]
--@derives [IRET.7.7]
--@derives [IRET.8.1]
||| THE VIEW THEOREM. After any history from a loaded network — every
||| input pumped, in order [LFST.9.2.1] — incremental propagation has
||| left every alpha memory and every terminal exactly as the recompute
||| over working memory would: the memories are the schema's admitted
||| facts, the activations are the chain's matches, none twice.
export
rarc_5_6_5__recompute_after_history : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                      (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                      Rarc_5_6_5__recomputed (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules))
rarc_5_6_5__recompute_after_history life fuel evs alphas rules =
  rarc_5_6_5__view_recomputed _ (lfst_9_2_1__replay_net_view life fuel evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_view alphas rules))

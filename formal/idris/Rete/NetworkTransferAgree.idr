-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE TRANSFER, PART TWO (iv): THE AGREEMENT AND ITS STEP. The
||| relation between a network engine and a FireLoop state: one working
||| memory; each rule of the program is, extensionally, the lowering of
||| the corresponding chain (RLOW.4.2.1); each table's unblocked tokens
||| are the corresponding terminal's activations, in order and with their
||| `fired` flags ([IRET.11], [IDAT.6.2.2]); and each side well-formed.
||| The step: after any one change of working memory the agreement
||| holds again -- the tuples agree because both sides hold exactly the
||| unblocked matches in the key's order, and two sorted lists with the
||| same members are one list; the flags agree because the network keeps
||| an activation whose match survives and FireLoop keeps its token, and
||| both make a released or new match unfired.
module Rete.NetworkTransferAgree

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
import Rete.NetworkCorollaries
import Rete.NetworkAgree
import Rete.NetworkTransferOrder
import Rete.NetworkTransferTable
import Rete.NetworkTransferFlags
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
-- Shapes: what the propagation paths never change
-- ---------------------------------------------------------------------

--@spec [IRET.6.1]
||| Two alpha lists of one shape: at every index the same schema and the
||| same tests; the memories may differ.
public export
Iret_6_1__same_alphas : List Iret_6_1__alpha -> List Iret_6_1__alpha -> Type
Iret_6_1__same_alphas alphas alphas' =
  (i : Nat) -> ( akind (iret_6_6__alpha_at alphas' i) = akind (iret_6_6__alpha_at alphas i)
               , (f : Lfac_1_7_1__fact) -> atest (iret_6_6__alpha_at alphas' i) f = atest (iret_6_6__alpha_at alphas i) f )

--@derives [IRET.6.1]
export
iret_6_1__same_alphas_refl : (alphas : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas
iret_6_1__same_alphas_refl alphas = \i => (Refl, \f => Refl)

--@derives [IRET.6.1]
export
iret_6_1__same_alphas_trans : (a1, a2, a3 : List Iret_6_1__alpha) -> Iret_6_1__same_alphas a1 a2 -> Iret_6_1__same_alphas a2 a3 -> Iret_6_1__same_alphas a1 a3
iret_6_1__same_alphas_trans a1 a2 a3 s12 s23 = \i => (trans (fst (s23 i)) (fst (s12 i)), \f => trans (snd (s23 i) f) (snd (s12 i) f))

--@derives [IRET.6.4]
||| Alphas of one shape admit the same facts.
export
iret_6_4__admits_same : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' -> (i : Nat) -> (f : Lfac_1_7_1__fact) ->
                        iret_6_4__admits (iret_6_6__alpha_at alphas' i) f = iret_6_4__admits (iret_6_6__alpha_at alphas i) f
iret_6_4__admits_same alphas alphas' sa i f = cong2 (\x, y => x && y) (cong (fkind f ==) (fst (sa i))) (snd (sa i) f)

--@derives [IRET.6.5]
||| Updating an index past the list changes nothing.
export
iret_6_5__set_at_none : (i : Nat) -> (g : a -> a) -> (xs : List a) -> rarc_5_6_5__nth i xs = Nothing -> rarc_5_6_5__set_at i g xs = xs
iret_6_5__set_at_none i g [] nt = Refl
iret_6_5__set_at_none Z g (x :: xs) nt = absurd nt
iret_6_5__set_at_none (S i) g (x :: xs) nt = cong (x ::) (iret_6_5__set_at_none i g xs nt)

--@derives [IRET.6.5]
||| Inserting a fact into one alpha keeps the shape.
export
iret_6_5__insert_same_alphas : (i : Nat) -> (f : Lfac_1_7_1__fact) -> (alphas : List Iret_6_1__alpha) ->
                               Iret_6_1__same_alphas alphas (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas)
iret_6_5__insert_same_alphas i f alphas j with (decEq i j)
  iret_6_5__insert_same_alphas i f alphas j | (No ne) = rewrite iret_6_6__alpha_at_set_neq i j ne (iret_6_5__insert f) alphas in (Refl, \g => Refl)
  iret_6_5__insert_same_alphas i f alphas i | (Yes Refl) with (rarc_5_6_5__nth i alphas) proof nt
    iret_6_5__insert_same_alphas i f alphas i | (Yes Refl) | Nothing = rewrite iret_6_5__set_at_none i (iret_6_5__insert f) alphas nt in rewrite nt in (Refl, \g => Refl)
    iret_6_5__insert_same_alphas i f alphas i | (Yes Refl) | (Just a) =
      rewrite iret_6_6__alpha_at_set_eq i (iret_6_5__insert f) alphas a nt in (Refl, \g => Refl)

--@derives [IRET.6.5]
||| Removing a fact from one alpha keeps the shape.
export
iret_6_5__remove_same_alphas : (i : Nat) -> (f : Lfac_1_7_1__fact) -> (alphas : List Iret_6_1__alpha) ->
                               Iret_6_1__same_alphas alphas (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas)
iret_6_5__remove_same_alphas i f alphas j with (decEq i j)
  iret_6_5__remove_same_alphas i f alphas j | (No ne) = rewrite iret_6_6__alpha_at_set_neq i j ne (iret_6_5__remove f) alphas in (Refl, \g => Refl)
  iret_6_5__remove_same_alphas i f alphas i | (Yes Refl) with (rarc_5_6_5__nth i alphas) proof nt
    iret_6_5__remove_same_alphas i f alphas i | (Yes Refl) | Nothing = rewrite iret_6_5__set_at_none i (iret_6_5__remove f) alphas nt in rewrite nt in (Refl, \g => Refl)
    iret_6_5__remove_same_alphas i f alphas i | (Yes Refl) | (Just a) =
      rewrite iret_6_6__alpha_at_set_eq i (iret_6_5__remove f) alphas a nt in (Refl, \g => Refl)

--@spec [RLOW.4.2.1]
--@spec [IRET.7.4]
||| Two chains of one shape: node by node the same alpha, join tests and
||| flag; the memories and counts may differ.
public export
data Rlow_4_2_1__same_shape : List Iret_7_4__beta -> List Iret_7_4__beta -> Type where
  SSNil  : Rlow_4_2_1__same_shape [] []
  SSCons : (b, b' : Iret_7_4__beta) -> balpha b' = balpha b -> bjoin b' = bjoin b -> bneg b' = bneg b -> Rlow_4_2_1__same_shape rest rest' ->
           Rlow_4_2_1__same_shape (b :: rest) (b' :: rest')

--@derives [RLOW.4.2.1]
--@derives [IRET.7.4]
export
rlow_4_2_1__same_shape_refl : (nodes : List Iret_7_4__beta) -> Rlow_4_2_1__same_shape nodes nodes
rlow_4_2_1__same_shape_refl [] = SSNil
rlow_4_2_1__same_shape_refl (b :: rest) = SSCons _ _ Refl Refl Refl (rlow_4_2_1__same_shape_refl rest)

--@derives [RLOW.4.2.1]
--@derives [IRET.7.4]
export
rlow_4_2_1__same_shape_trans : (n1, n2, n3 : List Iret_7_4__beta) -> Rlow_4_2_1__same_shape n1 n2 -> Rlow_4_2_1__same_shape n2 n3 -> Rlow_4_2_1__same_shape n1 n3
rlow_4_2_1__same_shape_trans [] [] [] SSNil SSNil = SSNil
rlow_4_2_1__same_shape_trans (b1 :: r1) (b2 :: r2) (b3 :: r3) (SSCons _ _ a12 j12 n12 s12) (SSCons _ _ a23 j23 n23 s23) =
  SSCons _ _ (trans a23 a12) (trans j23 j12) (trans n23 n12) (rlow_4_2_1__same_shape_trans r1 r2 r3 s12 s23)

--@derives [IRET.7.7]
export
iret_7_7__wave_shape : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (front : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                       Rlow_4_2_1__same_shape nodes (fst (iret_7_7__wave wm alphas nodes front acts))
iret_7_7__wave_shape wm alphas [] front acts = SSNil
iret_7_7__wave_shape wm alphas (b :: rest) front acts = SSCons _ _ Refl Refl Refl (iret_7_7__wave_shape wm alphas rest _ acts)

--@derives [IRET.7.8]
export
iret_7_8__unwave_shape : (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                         Rlow_4_2_1__same_shape nodes (fst (iret_7_8__unwave alphas nodes gone acts))
iret_7_8__unwave_shape alphas [] gone acts = SSNil
iret_7_8__unwave_shape alphas (b :: rest) gone acts = SSCons _ _ Refl Refl Refl (iret_7_8__unwave_shape alphas rest _ acts)

--@derives [IRET.7.7]
export
iret_7_7__right_activate_shape : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) ->
                                 (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                 Rlow_4_2_1__same_shape nodes (fst (iret_7_7__right_activate wm alphas a f nodes acts))
iret_7_7__right_activate_shape wm alphas a f [] acts = SSNil
iret_7_7__right_activate_shape wm alphas a f (b :: rest) acts with (balpha b == a)
  iret_7_7__right_activate_shape wm alphas a f (b :: rest) acts | False = SSCons _ _ Refl Refl Refl (iret_7_7__right_activate_shape wm alphas a f rest acts)
  iret_7_7__right_activate_shape wm alphas a f (b :: rest) acts | True with (bneg b)
    iret_7_7__right_activate_shape wm alphas a f (b :: rest) acts | True | True =
      SSCons _ _ Refl Refl Refl (rlow_4_2_1__same_shape_trans _ _ _ (iret_7_7__right_activate_shape wm alphas a f rest acts) (iret_7_8__unwave_shape alphas _ _ _))
    iret_7_7__right_activate_shape wm alphas a f (b :: rest) acts | True | False =
      SSCons _ _ Refl Refl Refl (rlow_4_2_1__same_shape_trans _ _ _ (iret_7_7__right_activate_shape wm alphas a f rest acts) (iret_7_7__wave_shape wm alphas _ _ _))

--@derives [IRET.7.7]
export
iret_7_7__right_retract_shape : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) ->
                                (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                Rlow_4_2_1__same_shape nodes (fst (iret_7_7__right_retract wm alphas a f nodes acts))
iret_7_7__right_retract_shape wm alphas a f [] acts = SSNil
iret_7_7__right_retract_shape wm alphas a f (b :: rest) acts with (balpha b == a)
  iret_7_7__right_retract_shape wm alphas a f (b :: rest) acts | False = SSCons _ _ Refl Refl Refl (iret_7_7__right_retract_shape wm alphas a f rest acts)
  iret_7_7__right_retract_shape wm alphas a f (b :: rest) acts | True with (bneg b)
    iret_7_7__right_retract_shape wm alphas a f (b :: rest) acts | True | True =
      SSCons _ _ Refl Refl Refl (rlow_4_2_1__same_shape_trans _ _ _ (iret_7_7__right_retract_shape wm alphas a f rest acts) (iret_7_7__wave_shape wm alphas _ _ _))
    iret_7_7__right_retract_shape wm alphas a f (b :: rest) acts | True | False =
      SSCons _ _ Refl Refl Refl (rlow_4_2_1__same_shape_trans _ _ _ (iret_7_7__right_retract_shape wm alphas a f rest acts) (iret_7_8__unwave_shape alphas _ _ _))

--@derives [IRET.6.4]
||| ALPHA DISPATCH ON ASSERT keeps every shape: the alphas', and each
||| chain's nodes and actions.
export
iret_6_4__dispatch_assert_shape : (wm' : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (is : List Nat) -> (net : Rarc_5_3_1__network) ->
                                  ( Iret_6_1__same_alphas (nalphas net) (nalphas (iret_6_4__dispatch_assert wm' f is net))
                                  , (i : Nat) -> (c, c' : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i (nchains net) = Just c ->
                                    rarc_5_6_5__nth i (nchains (iret_6_4__dispatch_assert wm' f is net)) = Just c' ->
                                    (Rlow_4_2_1__same_shape (cnodes c) (cnodes c'), cactions c' = cactions c) )
iret_6_4__dispatch_assert_shape wm' f [] net =
  ( iret_6_1__same_alphas_refl (nalphas net)
  , \i, c, c', n, n' => replace {p = \z => (Rlow_4_2_1__same_shape (cnodes c) (cnodes z), cactions z = cactions c)} (iret_11_4__just_inj (trans (sym n) n'))
                          (rlow_4_2_1__same_shape_refl (cnodes c), Refl) )
iret_6_4__dispatch_assert_shape wm' f (k :: is) (MkNetwork alphas chains) with (iret_6_4__admits (iret_6_6__alpha_at alphas k) f)
  iret_6_4__dispatch_assert_shape wm' f (k :: is) (MkNetwork alphas chains) | False = iret_6_4__dispatch_assert_shape wm' f is (MkNetwork alphas chains)
  iret_6_4__dispatch_assert_shape wm' f (k :: is) (MkNetwork alphas chains) | True =
    let (sa, sc) = iret_6_4__dispatch_assert_shape wm' f is
                     (MkNetwork (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) (map (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f) chains))
    in ( iret_6_1__same_alphas_trans _ _ _ (iret_6_5__insert_same_alphas k f alphas) sa
       , \i, c, c', n, n' =>
           let n1 : (rarc_5_6_5__nth i (map (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f) chains)
                     = Just (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f c))
               n1 = trans (lcyc_1_1__nth_map (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f) i chains) (cong (map _) n)
           in let (s2, a2) = sc i (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f c) c' n1 n'
              in ( rlow_4_2_1__same_shape_trans _ _ _ (iret_7_7__right_activate_shape wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f (cnodes c) (cacts c)) s2
                 , a2 ) )

--@derives [IRET.19.2]
||| ALPHA DISPATCH ON RETRACT keeps every shape.
export
iret_19_2__dispatch_retract_shape : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (is : List Nat) -> (net : Rarc_5_3_1__network) ->
                                    ( Iret_6_1__same_alphas (nalphas net) (nalphas (iret_19_2__dispatch_retract wm f is net))
                                    , (i : Nat) -> (c, c' : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i (nchains net) = Just c ->
                                      rarc_5_6_5__nth i (nchains (iret_19_2__dispatch_retract wm f is net)) = Just c' ->
                                      (Rlow_4_2_1__same_shape (cnodes c) (cnodes c'), cactions c' = cactions c) )
iret_19_2__dispatch_retract_shape wm f [] net =
  ( iret_6_1__same_alphas_refl (nalphas net)
  , \i, c, c', n, n' => replace {p = \z => (Rlow_4_2_1__same_shape (cnodes c) (cnodes z), cactions z = cactions c)} (iret_11_4__just_inj (trans (sym n) n'))
                          (rlow_4_2_1__same_shape_refl (cnodes c), Refl) )
iret_19_2__dispatch_retract_shape wm f (k :: is) (MkNetwork alphas chains) with (iret_6_4__admits (iret_6_6__alpha_at alphas k) f)
  iret_19_2__dispatch_retract_shape wm f (k :: is) (MkNetwork alphas chains) | False = iret_19_2__dispatch_retract_shape wm f is (MkNetwork alphas chains)
  iret_19_2__dispatch_retract_shape wm f (k :: is) (MkNetwork alphas chains) | True =
    let (sa, sc) = iret_19_2__dispatch_retract_shape wm f is
                     (MkNetwork (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f) chains))
    in ( iret_6_1__same_alphas_trans _ _ _ (iret_6_5__remove_same_alphas k f alphas) sa
       , \i, c, c', n, n' =>
           let n1 : (rarc_5_6_5__nth i (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f) chains)
                     = Just (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f c))
               n1 = trans (lcyc_1_1__nth_map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f) i chains) (cong (map _) n)
           in let (s2, a2) = sc i (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f c) c' n1 n'
              in ( rlow_4_2_1__same_shape_trans _ _ _ (iret_7_7__right_retract_shape wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f (cnodes c) (cacts c)) s2
                 , a2 ) )

-- ---------------------------------------------------------------------
-- Rules, extensionally
-- ---------------------------------------------------------------------

--@spec [RLOW.5.3]
||| Two blocker lists that read the same kinds and decide alike.
public export
data Rlow_5_3__same_negs : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool) -> List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool) -> Type where
  SNNil  : Rlow_5_3__same_negs [] []
  SNCons : {nb, nb' : (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)} ->
           {rest, rest' : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)} ->
           Builtin.fst nb' = Builtin.fst nb -> ((u : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) -> Builtin.snd nb' u f = Builtin.snd nb u f) ->
           Rlow_5_3__same_negs rest rest' -> Rlow_5_3__same_negs (nb :: rest) (nb' :: rest')

--@derives [RLOW.5.3]
export
rlow_5_3__same_negs_refl : (negs : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) -> Rlow_5_3__same_negs negs negs
rlow_5_3__same_negs_refl [] = SNNil
rlow_5_3__same_negs_refl (nb :: rest) = SNCons Refl (\u, f => Refl) (rlow_5_3__same_negs_refl rest)

--@derives [RLOW.5.3]
export
rlow_5_3__same_negs_trans : (n1, n2, n3 : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) ->
                            Rlow_5_3__same_negs n1 n2 -> Rlow_5_3__same_negs n2 n3 -> Rlow_5_3__same_negs n1 n3
rlow_5_3__same_negs_trans [] [] [] SNNil SNNil = SNNil
rlow_5_3__same_negs_trans (a :: r1) (b :: r2) (c :: r3) (SNCons k12 t12 s12) (SNCons k23 t23 s23) =
  SNCons (trans k23 k12) (\u, f => trans (t23 u f) (t12 u f)) (rlow_5_3__same_negs_trans r1 r2 r3 s12 s23)

--@spec [LGRA.6.1]
--@spec [RLOW.4.2.1]
--@spec [IRET.7.4]
||| TWO RULES THAT ARE ONE, extensionally: the same positive kinds, a
||| guard that decides alike on every tuple, blockers that read the same
||| kinds and decide alike, the same actions. What a run can tell.
public export
Lgra_6_1__same_rule : Lgra_6_1__rule -> Lgra_6_1__rule -> Type
Lgra_6_1__same_rule r r' =
  ( posKinds r' = posKinds r
  , (fs : Iret_7_1__token) -> guard r' fs = guard r fs
  , Rlow_5_3__same_negs (negs r) (negs r')
  , actions r' = actions r )

--@derives [LGRA.6.1]
--@derives [RLOW.4.2.1]
export
lgra_6_1__same_rule_refl : (r : Lgra_6_1__rule) -> Lgra_6_1__same_rule r r
lgra_6_1__same_rule_refl r = (Refl, \fs => Refl, rlow_5_3__same_negs_refl (negs r), Refl)

--@derives [LGRA.6.1]
--@derives [RLOW.4.2.1]
export
lgra_6_1__same_rule_trans : (r1, r2, r3 : Lgra_6_1__rule) -> Lgra_6_1__same_rule r1 r2 -> Lgra_6_1__same_rule r2 r3 -> Lgra_6_1__same_rule r1 r3
lgra_6_1__same_rule_trans r1 r2 r3 (k12, g12, n12, a12) (k23, g23, n23, a23) =
  (trans k23 k12, \fs => trans (g23 fs) (g12 fs), rlow_5_3__same_negs_trans _ _ _ n12 n23, trans a23 a12)

--@derives [IRET.7.4]
||| Rules that are one match the same tuples.
export
iret_7_4__match_tuples_same : (r, r' : Lgra_6_1__rule) -> Lgra_6_1__same_rule r r' -> (wm : Rarc_5_6_4__wm) ->
                              iret_7_4__match_tuples r' wm = iret_7_4__match_tuples r wm
iret_7_4__match_tuples_same r r' (pk, g, _, _) wm =
  rewrite pk in lcyc_1_1__filter_ext (guard r') (guard r) g (iret_7_4__tuples (posKinds r) wm)

--@derives [IRET.7.9]
||| Blocking, blocker by blocker.
public export
iret_7_9__blocked_negs : Rarc_5_6_4__wm -> List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool) -> Iret_7_1__token -> Bool
iret_7_9__blocked_negs wm [] fs = False
iret_7_9__blocked_negs wm (nb :: rest) fs =
  if rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm) then True else iret_7_9__blocked_negs wm rest fs

--@derives [IRET.7.9]
export
iret_7_9__bool_of_false : (x, y : Bool) -> (x = False -> y = False) -> (y = False -> x = False) -> x = y
iret_7_9__bool_of_false False False _ _ = Refl
iret_7_9__bool_of_false False True h _ = absurd (h Refl)
iret_7_9__bool_of_false True False _ h = absurd (h Refl)
iret_7_9__bool_of_false True True _ _ = Refl

--@derives [IRET.7.9]
export
iret_7_9__blocked_negs_cons_inv : (wm : Rarc_5_6_4__wm) -> (nb : (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) -> (rest : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) ->
                                  (fs : Iret_7_1__token) -> iret_7_9__blocked_negs wm (nb :: rest) fs = False ->
                                  (rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm) = False, iret_7_9__blocked_negs wm rest fs = False)
iret_7_9__blocked_negs_cons_inv wm nb rest fs h with (rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm))
  iret_7_9__blocked_negs_cons_inv wm nb rest fs h | True = absurd h
  iret_7_9__blocked_negs_cons_inv wm nb rest fs h | False = (Refl, h)

--@derives [IRET.7.9]
export
iret_7_9__blocked_negs_cons : (wm : Rarc_5_6_4__wm) -> (nb : (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) -> (rest : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) ->
                              (fs : Iret_7_1__token) -> rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm) = False -> iret_7_9__blocked_negs wm rest fs = False ->
                              iret_7_9__blocked_negs wm (nb :: rest) fs = False
iret_7_9__blocked_negs_cons wm nb rest fs h1 h2 = rewrite h1 in h2

--@derives [IRET.7.9]
||| FireLoop's blocking over the zipped blockers is blocking blocker by blocker.
export
iret_7_9__is_blocked_negs : (wm : Rarc_5_6_4__wm) -> (negs : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) -> (fs : Iret_7_1__token) ->
                            iret_7_9__is_blocked_with (rlow_5_3__tests negs) (rlow_5_3__facts wm negs) fs = iret_7_9__blocked_negs wm negs fs
iret_7_9__is_blocked_negs wm [] fs = Refl
iret_7_9__is_blocked_negs wm (nb :: rest) fs =
  iret_7_9__bool_of_false _ _
    (\h => let (h1, h2) = iret_7_9__blocked_cons_inv (snd nb) (rlow_5_3__tests rest) (rarc_5_6_4__facts_of_kind (fst nb) wm) (rlow_5_3__facts wm rest) fs h
           in iret_7_9__blocked_negs_cons wm nb rest fs h1 (trans (sym (iret_7_9__is_blocked_negs wm rest fs)) h2))
    (\h => let (h1, h2) = iret_7_9__blocked_negs_cons_inv wm nb rest fs h
           in iret_7_9__blocked_cons (snd nb) (rlow_5_3__tests rest) (rarc_5_6_4__facts_of_kind (fst nb) wm) (rlow_5_3__facts wm rest) fs h1
                (trans (iret_7_9__is_blocked_negs wm rest fs) h2))

--@derives [IRET.7.9]
export
iret_7_9__any_ext : (p, q : a -> Bool) -> (xs : List a) -> ((x : a) -> Elem x xs -> p x = q x) -> rarc_5_6_5__any p xs = rarc_5_6_5__any q xs
iret_7_9__any_ext p q [] h = Refl
iret_7_9__any_ext p q (x :: xs) h with (p x) proof px
  iret_7_9__any_ext p q (x :: xs) h | True = rewrite trans (sym (h x Here)) px in Refl
  iret_7_9__any_ext p q (x :: xs) h | False = rewrite trans (sym (h x Here)) px in iret_7_9__any_ext p q xs (\y, ey => h y (There ey))

--@derives [IRET.7.9]
||| Blockers that are one block alike.
export
iret_7_9__blocked_negs_same : (wm : Rarc_5_6_4__wm) -> (negs, negs' : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) -> Rlow_5_3__same_negs negs negs' ->
                              (fs : Iret_7_1__token) -> iret_7_9__blocked_negs wm negs' fs = iret_7_9__blocked_negs wm negs fs
iret_7_9__blocked_negs_same wm [] [] SNNil fs = Refl
iret_7_9__blocked_negs_same wm (nb :: rest) (nb' :: rest') (SNCons kk tt srest) fs =
  let eqC : (rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm) = rarc_5_6_5__any (snd nb' fs) (rarc_5_6_4__facts_of_kind (fst nb') wm))
      eqC = trans (sym (iret_7_9__any_ext (snd nb' fs) (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm) (\g, _ => tt fs g)))
                  (cong (\k => rarc_5_6_5__any (snd nb' fs) (rarc_5_6_4__facts_of_kind k wm)) (sym kk))
      ih : (iret_7_9__blocked_negs wm rest' fs = iret_7_9__blocked_negs wm rest fs)
      ih = iret_7_9__blocked_negs_same wm rest rest' srest fs
  in iret_7_9__bool_of_false _ _
       (\h => let (h1, h2) = iret_7_9__blocked_negs_cons_inv wm nb' rest' fs h
              in iret_7_9__blocked_negs_cons wm nb rest fs (trans eqC h1) (trans (sym ih) h2))
       (\h => let (h1, h2) = iret_7_9__blocked_negs_cons_inv wm nb rest fs h
              in iret_7_9__blocked_negs_cons wm nb' rest' fs (trans (sym eqC) h1) (trans ih h2))

--@derives [IRET.7.9]
||| Rules that are one block the same tuples.
export
iret_7_9__is_blocked_same : (r, r' : Lgra_6_1__rule) -> Lgra_6_1__same_rule r r' -> (wm : Rarc_5_6_4__wm) -> (fs : Iret_7_1__token) ->
                            iret_7_9__is_blocked r' wm fs = iret_7_9__is_blocked r wm fs
iret_7_9__is_blocked_same r r' (_, _, sn, _) wm fs =
  trans (iret_7_9__is_blocked_negs wm (negs r') fs) (trans (iret_7_9__blocked_negs_same wm (negs r) (negs r') sn fs) (sym (iret_7_9__is_blocked_negs wm (negs r) fs)))

--@derives [RLOW.5.1]
||| One node of one shape, given the rest.
export
rlow_5_1__pos_kinds_node : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' ->
                           (a : Nat) -> (j : Iret_7_5__join) -> (n : Bool) -> (lm : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) ->
                           (lm' : List Iret_7_1__token) -> (cs' : List (Iret_7_1__token, Nat)) -> (rest, rest' : List Iret_7_4__beta) ->
                           rlow_5_1__pos_kinds alphas' rest' = rlow_5_1__pos_kinds alphas rest ->
                           rlow_5_1__pos_kinds alphas' (MkBeta a j n lm' cs' :: rest') = rlow_5_1__pos_kinds alphas (MkBeta a j n lm cs :: rest)
rlow_5_1__pos_kinds_node alphas alphas' sa a j True lm cs lm' cs' rest rest' ih = ih
rlow_5_1__pos_kinds_node alphas alphas' sa a j False lm cs lm' cs' rest rest' ih = cong2 (::) (fst (sa a)) ih

--@derives [RLOW.5.1]
export
rlow_5_1__pos_kinds_same : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' ->
                           (nodes, nodes' : List Iret_7_4__beta) -> Rlow_4_2_1__same_shape nodes nodes' ->
                           rlow_5_1__pos_kinds alphas' nodes' = rlow_5_1__pos_kinds alphas nodes
rlow_5_1__pos_kinds_same alphas alphas' sa [] [] SSNil = Refl
rlow_5_1__pos_kinds_same alphas alphas' sa (MkBeta a j n lm cs :: rest) (MkBeta a' j' n' lm' cs' :: rest') (SSCons _ _ ba bj bn srest) =
  rewrite ba in rewrite bj in rewrite bn in
  rlow_5_1__pos_kinds_node alphas alphas' sa a j n lm cs lm' cs' rest rest' (rlow_5_1__pos_kinds_same alphas alphas' sa rest rest' srest)

--@derives [RLOW.5.5]
||| One node of one shape, given the rest at every position.
export
rlow_5_5__guard_from_node : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' ->
                            (a : Nat) -> (j : Iret_7_5__join) -> (n : Bool) -> (lm : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) ->
                            (lm' : List Iret_7_1__token) -> (cs' : List (Iret_7_1__token, Nat)) -> (rest, rest' : List Iret_7_4__beta) ->
                            ((i' : Nat) -> (tuple : Iret_7_1__token) -> rlow_5_5__guard_from alphas' rest' i' tuple = rlow_5_5__guard_from alphas rest i' tuple) ->
                            (i : Nat) -> (tuple : Iret_7_1__token) ->
                            rlow_5_5__guard_from alphas' (MkBeta a j n lm' cs' :: rest') i tuple = rlow_5_5__guard_from alphas (MkBeta a j n lm cs :: rest) i tuple
rlow_5_5__guard_from_node alphas alphas' sa a j True lm cs lm' cs' rest rest' ih i tuple = ih i tuple
rlow_5_5__guard_from_node alphas alphas' sa a j False lm cs lm' cs' rest rest' ih i tuple with (rarc_5_6_5__nth i tuple)
  rlow_5_5__guard_from_node alphas alphas' sa a j False lm cs lm' cs' rest rest' ih i tuple | Nothing = Refl
  rlow_5_5__guard_from_node alphas alphas' sa a j False lm cs lm' cs' rest rest' ih i tuple | (Just f) =
    cong2 (\x, y => x && y) (cong2 (\x, y => x && y) (iret_6_4__admits_same alphas alphas' sa a f) Refl) (ih (S i) tuple)

--@derives [RLOW.5.5]
export
rlow_5_5__guard_from_same : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' ->
                            (nodes, nodes' : List Iret_7_4__beta) -> Rlow_4_2_1__same_shape nodes nodes' -> (i : Nat) -> (tuple : Iret_7_1__token) ->
                            rlow_5_5__guard_from alphas' nodes' i tuple = rlow_5_5__guard_from alphas nodes i tuple
rlow_5_5__guard_from_same alphas alphas' sa [] [] SSNil i tuple = Refl
rlow_5_5__guard_from_same alphas alphas' sa (MkBeta a j n lm cs :: rest) (MkBeta a' j' n' lm' cs' :: rest') (SSCons _ _ ba bj bn srest) i tuple =
  rewrite ba in rewrite bj in rewrite bn in
  rlow_5_5__guard_from_node alphas alphas' sa a j n lm cs lm' cs' rest rest' (\i', t => rlow_5_5__guard_from_same alphas alphas' sa rest rest' srest i' t) i tuple

--@derives [RLOW.5.3]
||| One node of one shape, given the rest at every position.
export
rlow_5_3__negs_from_node : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' ->
                           (a : Nat) -> (j : Iret_7_5__join) -> (n : Bool) -> (lm : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) ->
                           (lm' : List Iret_7_1__token) -> (cs' : List (Iret_7_1__token, Nat)) -> (rest, rest' : List Iret_7_4__beta) ->
                           ((i' : Nat) -> Rlow_5_3__same_negs (rlow_5_3__negs_from alphas rest i') (rlow_5_3__negs_from alphas' rest' i')) -> (i : Nat) ->
                           Rlow_5_3__same_negs (rlow_5_3__negs_from alphas (MkBeta a j n lm cs :: rest) i) (rlow_5_3__negs_from alphas' (MkBeta a j n lm' cs' :: rest') i)
rlow_5_3__negs_from_node alphas alphas' sa a j True lm cs lm' cs' rest rest' ih i =
  SNCons (fst (sa a)) (\u, f => cong2 (\x, y => x && y) (iret_6_4__admits_same alphas alphas' sa a f) Refl) (ih i)
rlow_5_3__negs_from_node alphas alphas' sa a j False lm cs lm' cs' rest rest' ih i = ih (S i)

--@derives [RLOW.5.3]
export
rlow_5_3__negs_from_same : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' ->
                           (nodes, nodes' : List Iret_7_4__beta) -> Rlow_4_2_1__same_shape nodes nodes' -> (i : Nat) ->
                           Rlow_5_3__same_negs (rlow_5_3__negs_from alphas nodes i) (rlow_5_3__negs_from alphas' nodes' i)
rlow_5_3__negs_from_same alphas alphas' sa [] [] SSNil i = SNNil
rlow_5_3__negs_from_same alphas alphas' sa (MkBeta a j n lm cs :: rest) (MkBeta a' j' n' lm' cs' :: rest') (SSCons _ _ ba bj bn srest) i =
  rewrite ba in rewrite bj in rewrite bn in
  rlow_5_3__negs_from_node alphas alphas' sa a j n lm cs lm' cs' rest rest' (\i' => rlow_5_3__negs_from_same alphas alphas' sa rest rest' srest i') i

--@derives [RLOW.4.2.1]
||| A CHAIN'S RULE DOES NOT CHANGE: through every change of memories and
||| flags the chain lowers to one rule, extensionally.
export
rlow_4_2_1__rule_of_same : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' ->
                           (c, c' : Rlow_4_2_1__chain) -> Rlow_4_2_1__same_shape (cnodes c) (cnodes c') -> cactions c' = cactions c ->
                           Lgra_6_1__same_rule (rlow_4_2_1__rule_of alphas c) (rlow_4_2_1__rule_of alphas' c')
rlow_4_2_1__rule_of_same alphas alphas' sa c c' ss ac =
  ( rlow_5_1__pos_kinds_same alphas alphas' sa (cnodes c) (cnodes c') ss
  , \fs => rlow_5_5__guard_from_same alphas alphas' sa (cnodes c) (cnodes c') ss 0 fs
  , rlow_5_3__negs_from_same alphas alphas' sa (cnodes c) (cnodes c') ss 0
  , ac )

-- ---------------------------------------------------------------------
-- Tokens as activations
-- ---------------------------------------------------------------------

--@spec [IRET.11]
||| A FireLoop token as the activation the network holds: the match and
||| whether it fired.
public export
iret_11__to_act : Iret_11__tok -> Iret_8_1__act
iret_11__to_act t = MkAct (tfacts t) (fired t)

--@spec [IRET.11]
||| Tokens as activations; named so that no statement mentions the
||| conversion unapplied.
public export
iret_11__to_acts : List Iret_11__tok -> List Iret_8_1__act
iret_11__to_acts ts = map iret_11__to_act ts

--@spec [IRET.11.3.1]
||| The unblocked tokens of a table, as activations, in table order.
public export
iret_11_3_1__unblocked_acts : List Iret_11__tok -> List Iret_8_1__act
iret_11_3_1__unblocked_acts ts = iret_11__to_acts (filter (\t => not (blocked t)) ts)

--@derives [IRET.11.3.1]
export
iret_11_3_1__unblocked_inv : (ts : List Iret_11__tok) -> (a : Iret_8_1__act) -> Elem a (iret_11_3_1__unblocked_acts ts) ->
                             (t ** (Elem t ts, blocked t = False, a = iret_11__to_act t))
iret_11_3_1__unblocked_inv ts a e =
  let (t ** (et, teq)) = lcyc_1_1__elem_map_inv iret_11__to_act (filter (\t => not (blocked t)) ts) e
      (ets, nb) = lcyc_1_1__elem_filter_inv (\t => not (blocked t)) ts et
  in (t ** (ets, lcyc_1_1__not_true_is_false _ nb, sym teq))

--@derives [IRET.11.3.1]
export
iret_11_3_1__unblocked_fwd : (ts : List Iret_11__tok) -> (t : Iret_11__tok) -> Elem t ts -> blocked t = False -> Elem (iret_11__to_act t) (iret_11_3_1__unblocked_acts ts)
iret_11_3_1__unblocked_fwd ts t e nb = lcyc_1_1__elem_map_fwd iret_11__to_act (lcyc_1_1__elem_filter_fwd (\t => not (blocked t)) ts e (cong not nb))

--@derives [IRET.11.3.1]
export
iret_11_3_1__unblocked_tuples : (xs : List Iret_11__tok) -> iret_8_1__tuples (iret_11__to_acts xs) = iret_11_3__tuples_of xs
iret_11_3_1__unblocked_tuples [] = Refl
iret_11_3_1__unblocked_tuples (x :: xs) = cong (tfacts x ::) (iret_11_3_1__unblocked_tuples xs)

--@derives [IRET.11.3]
||| With distinct tuples, two tokens of one table with one tuple are one
||| token.
export
iret_11_3__same_tuple_same_tok : (ts : List Iret_11__tok) -> Iret_11_3__distinct (iret_11_3__tuples_of ts) ->
                                 (t, u : Iret_11__tok) -> Elem t ts -> Elem u ts -> tfacts t = tfacts u -> t = u
iret_11_3__same_tuple_same_tok (x :: xs) (DCons nx d) t u et eu eq =
  case (iret_11_3__elem_cons et, iret_11_3__elem_cons eu) of
    (Left pt, Left pu) => trans pt (sym pu)
    (Left pt, Right eu') => void (nx (replace {p = \z => Elem z (iret_11_3__tuples_of xs)} (trans (sym eq) (cong tfacts pt)) (lcyc_1_1__elem_map_fwd tfacts eu')))
    (Right et', Left pu) => void (nx (replace {p = \z => Elem z (iret_11_3__tuples_of xs)} (trans eq (cong tfacts pu)) (lcyc_1_1__elem_map_fwd tfacts et')))
    (Right et', Right eu') => iret_11_3__same_tuple_same_tok xs d t u et' eu' eq

--@derives [IRET.8.1]
||| Two activation lists with the same tuples and the same flag on each
||| tuple are one list.
export
iret_8_1__acts_ext : (xs, ys : List Iret_8_1__act) -> iret_8_1__tuples xs = iret_8_1__tuples ys ->
                     ((a : Iret_8_1__act) -> Elem a xs -> (b : Iret_8_1__act) -> Elem b ys -> atuple a = atuple b -> afired a = afired b) -> xs = ys
iret_8_1__acts_ext [] [] _ _ = Refl
iret_8_1__acts_ext [] (y :: ys) eq _ = absurd eq
iret_8_1__acts_ext (x :: xs) [] eq _ = absurd eq
iret_8_1__acts_ext (MkAct t f :: xs) (MkAct t' f' :: ys) eq h =
  let (hd, tl) = consInjective eq
      ff : (f = f')
      ff = h (MkAct t f) Here (MkAct t' f') Here hd
  in cong2 (::) (cong2 MkAct hd ff) (iret_8_1__acts_ext xs ys tl (\a, ea, b, eb, ab => h a (There ea) b (There eb) ab))

--@derives [LDET.5.9]
export
ldet_5_9__refresh_fired_unblocked : (blk : Bool) -> (k : Iret_11__tok) -> blocked k = False -> fired (ldet_5_9__refresh_with blk k) = fired k
ldet_5_9__refresh_fired_unblocked blk k h = rewrite h in Refl

--@derives [LDET.5.9]
export
ldet_5_9__refresh_fired_released : (blk : Bool) -> (k : Iret_11__tok) -> blocked k = True -> blk = False -> fired (ldet_5_9__refresh_with blk k) = False
ldet_5_9__refresh_fired_released blk k h1 h2 = rewrite h1 in rewrite h2 in Refl

--@derives [IRET.8.1]
--@derives [IRET.4.4]
||| A SETTLED, LIVE TABLE'S UNBLOCKED TUPLES are the unblocked matches:
||| the ids of settledness identify facts under unique ids.
export
iret_8_1__settled_unblocked_set : (r : Lgra_6_1__rule) -> (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (ts : List Iret_11__tok) ->
                                  All (\t => Ldet_5_5__live wm (tfacts t)) ts ->
                                  Iret_8_1__settled r (iret_7_4__match_tuples r wm) (iret_7_9__neg_facts r wm) ts ->
                                  Iret_7_4__same_set (iret_11_3__tuples_of (filter (\t => not (blocked t)) ts))
                                                     (filter (\t => not (iret_7_9__is_blocked r wm t)) (iret_7_4__match_tuples r wm))
iret_8_1__settled_unblocked_set r wm uq ts lv (allT, allN) = \x =>
  ( \e => let (t ** (et, teq)) = lcyc_1_1__elem_map_inv tfacts (filter (\t => not (blocked t)) ts) e
              (ets, nb) = lcyc_1_1__elem_filter_inv (\t => not (blocked t)) ts et
              (blkEq, inNow) = lcyc_1_1__all_lookup allT ets
              (fs ** (efs, idsEq)) = lcyc_1_1__elem_map_inv iret_11_3__fact_ids (iret_7_4__match_tuples r wm) (lcyc_1_1__elem_ll_elem _ _ inNow)
              lfs : All (\g => Elem g wm) fs
              lfs = lcyc_1_1__all_lookup (iret_7_4__tuples_live (posKinds r) wm) (fst (lcyc_1_1__elem_filter_inv (guard r) (iret_7_4__tuples (posKinds r) wm) efs))
              same : (tfacts t = fs)
              same = iret_4_4__ids_identify wm uq wm (\g, eg => Left eg) (tfacts t) fs (lcyc_1_1__all_lookup lv ets) lfs (sym idsEq)
              unb : (iret_7_9__is_blocked r wm (tfacts t) = False)
              unb = trans (sym blkEq) (lcyc_1_1__not_true_is_false _ nb)
          in replace {p = \z => Elem z (filter (\t => not (iret_7_9__is_blocked r wm t)) (iret_7_4__match_tuples r wm))} teq
               (lcyc_1_1__elem_filter_fwd (\t => not (iret_7_9__is_blocked r wm t)) (iret_7_4__match_tuples r wm)
                  (replace {p = \z => Elem z (iret_7_4__match_tuples r wm)} (sym same) efs) (cong not unb))
  , \e => let (ex, unb) = lcyc_1_1__elem_filter_inv (\t => not (iret_7_9__is_blocked r wm t)) (iret_7_4__match_tuples r wm) e
              inToks = lcyc_1_1__all_lookup allN ex
              (t ** (et, idsEq)) = lcyc_1_1__elem_map_inv iret_11_3__ids ts (lcyc_1_1__elem_ll_elem _ _ inToks)
              lx : All (\g => Elem g wm) x
              lx = lcyc_1_1__all_lookup (iret_7_4__tuples_live (posKinds r) wm) (fst (lcyc_1_1__elem_filter_inv (guard r) (iret_7_4__tuples (posKinds r) wm) ex))
              same : (tfacts t = x)
              same = iret_4_4__ids_identify wm uq wm (\g, eg => Left eg) (tfacts t) x (lcyc_1_1__all_lookup lv et) lx idsEq
          in let (blkEq, _) = lcyc_1_1__all_lookup allT et
             in let nb : (blocked t = False)
                    nb = trans blkEq (replace {p = \z => iret_7_9__is_blocked r wm z = False} (sym same) (lcyc_1_1__not_true_is_false _ unb))
                in replace {p = \z => Elem z (iret_11_3__tuples_of (filter (\t => not (blocked t)) ts))} same
                     (lcyc_1_1__elem_map_fwd tfacts (lcyc_1_1__elem_filter_fwd (\t => not (blocked t)) ts et (cong not nb))) )

-- ---------------------------------------------------------------------
-- The step of the agreement, per rule
-- ---------------------------------------------------------------------

--@derives [RLOW.4.2.1]
--@derives [IRET.8.1]
--@derives [IDAT.6.2.2]
--@derives [LDET.5.9]
||| THE UNBLOCKED TOKENS AFTER A PROPAGATION ARE THE NETWORK'S
||| ACTIVATIONS after the same change, given: the two agreed before; the
||| network's new terminal is sorted and holds exactly the unblocked
||| matches; every new activation is an old one or unfired; every old
||| activation whose match survives is still there.
export
rlow_4_2_1__prop_agree : (r : Lgra_6_1__rule) -> (wm, wm' : Rarc_5_6_4__wm) -> Iret_4_4__unique wm' ->
                         (old : List Iret_11__tok) -> Iret_8_1__well wm old -> (acts : List Iret_8_1__act) -> iret_11_3_1__unblocked_acts old = acts ->
                         Iret_8_1__well wm' (rarc_5_6_5__prop_rule r wm' old) ->
                         Iret_8_1__settled r (iret_7_4__match_tuples r wm') (iret_7_9__neg_facts r wm') (rarc_5_6_5__prop_rule r wm' old) ->
                         (acts' : List Iret_8_1__act) -> Ldet_5_5__sorted wm' acts' -> Iret_11_3__distinct (iret_8_1__tuples acts') ->
                         Iret_7_4__same_set (iret_8_1__tuples acts') (filter (\t => not (iret_7_9__is_blocked r wm' t)) (iret_7_4__match_tuples r wm')) ->
                         ((a' : Iret_8_1__act) -> Elem a' acts' -> Either (Elem a' acts) (afired a' = False)) ->
                         ((a : Iret_8_1__act) -> Elem a acts -> Elem (atuple a) (iret_8_1__tuples acts') -> Elem a acts') ->
                         iret_11_3_1__unblocked_acts (rarc_5_6_5__prop_rule r wm' old) = acts'
rlow_4_2_1__prop_agree r wm wm' uq' old (lvOld, soOld) acts agreeOld (lv', so') stl' acts' sorted' dt' sameSet p1 p2 =
  let tupEq : (iret_8_1__tuples (iret_11_3_1__unblocked_acts (rarc_5_6_5__prop_rule r wm' old)) = iret_8_1__tuples acts')
      tupEq = trans (iret_11_3_1__unblocked_tuples _)
                (ldet_5_9__sorted_tuples_unique wm' _ _
                   (ldet_5_5__sorted_tuples_of_filter wm' (\t => not (blocked t)) _ so')
                   (ldet_5_5__sorted_tuples_of_acts wm' acts' sorted')
                   (iret_7_4__same_set_trans _ _ _ (iret_8_1__settled_unblocked_set r wm' uq' _ lv' stl') (iret_7_4__same_set_sym _ _ sameSet)))
      dOld : Iret_11_3__distinct (iret_11_3__tuples_of old)
      dOld = ldet_5_5__sorted_tuples_distinct wm _ soOld
      flags : (a' : Iret_8_1__act) -> Elem a' (iret_11_3_1__unblocked_acts (rarc_5_6_5__prop_rule r wm' old)) ->
              (b : Iret_8_1__act) -> Elem b acts' -> atuple a' = atuple b -> afired a' = afired b
      flags = \a', ea', b, eb, ab =>
        let (t' ** (et', unb', aeq)) = iret_11_3_1__unblocked_inv _ a' ea'
            (k ** (ek, keq)) = lcyc_1_1__elem_map_inv (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm')) _ et'
            blkEq : (blocked t' = iret_7_9__is_blocked_with (iret_7_9__blockers r) (iret_7_9__neg_facts r wm') (tfacts k))
            blkEq = cong blocked (sym keq)
            blkFalse : (iret_7_9__is_blocked_with (iret_7_9__blockers r) (iret_7_9__neg_facts r wm') (tfacts k) = False)
            blkFalse = trans (sym blkEq) unb'
            tupA : (atuple a' = tfacts k)
            tupA = trans (cong atuple aeq) (cong tfacts (sym keq))
        in case lcyc_1_1__elem_append_inv (iret_8_1__kept_of (iret_7_4__match_tuples r wm') old) ek of
             Left ekept =>
               let (eold, _) = lcyc_1_1__elem_filter_inv (\u => rarc_5_6_5__elem (iret_11_3__ids u) (iret_11_3__now_ids (iret_7_4__match_tuples r wm'))) old ekept
               in case p1 b eb of
                    Left ebOld =>
                      let (k0 ** (ek0, unb0, beq)) = iret_11_3_1__unblocked_inv old b (replace {p = \z => Elem b z} (sym agreeOld) ebOld)
                          kk : (k0 = k)
                          kk = iret_11_3__same_tuple_same_tok old dOld k0 k ek0 eold (trans (sym (cong atuple beq)) (trans (sym ab) tupA))
                          unbK : (blocked k = False)
                          unbK = replace {p = \z => blocked z = False} kk unb0
                      in trans (cong afired aeq) (trans (cong fired (sym keq))
                           (trans (ldet_5_9__refresh_fired_unblocked _ k unbK) (trans (cong fired (sym kk)) (sym (cong afired beq)))))
                    Right nfb => case decEq (blocked k) True of
                      Yes blkK => trans (cong afired aeq) (trans (cong fired (sym keq)) (trans (ldet_5_9__refresh_fired_released _ k blkK blkFalse) (sym nfb)))
                      No nblk =>
                        let unbK : (blocked k = False)
                            unbK = iret_12__bool_false_of _ nblk
                            inActs : Elem (iret_11__to_act k) acts
                            inActs = replace {p = \z => Elem (iret_11__to_act k) z} agreeOld (iret_11_3_1__unblocked_fwd old k eold unbK)
                            inActs' : Elem (iret_11__to_act k) acts'
                            inActs' = p2 (iret_11__to_act k) inActs (replace {p = \z => Elem z (iret_8_1__tuples acts')} (trans (sym ab) tupA) (lcyc_1_1__elem_map_fwd atuple eb))
                            bk : (b = iret_11__to_act k)
                            bk = iret_11_3__same_tuple_same_act acts' dt' b (iret_11__to_act k) eb inActs' (trans (sym ab) tupA)
                        in trans (cong afired aeq) (trans (cong fired (sym keq)) (trans (ldet_5_9__refresh_fired_unblocked _ k unbK) (sym (cong afired bk))))
             Right eadded =>
               let (fs ** (efs, kfresh)) = lcyc_1_1__elem_map_inv iret_8_1__fresh_tok _ eadded
                   (_, notOld) = lcyc_1_1__elem_filter_inv (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) (iret_7_4__match_tuples r wm') efs
                   unbK : (blocked k = False)
                   unbK = cong blocked (sym kfresh)
                   firedA : (afired a' = False)
                   firedA = trans (cong afired aeq) (trans (cong fired (sym keq)) (trans (ldet_5_9__refresh_fired_unblocked _ k unbK) (cong fired (sym kfresh))))
               in case p1 b eb of
                    Left ebOld =>
                      let (k0 ** (ek0, _, beq)) = iret_11_3_1__unblocked_inv old b (replace {p = \z => Elem b z} (sym agreeOld) ebOld)
                          tk0 : (tfacts k0 = fs)
                          tk0 = trans (sym (cong atuple beq)) (trans (sym ab) (trans tupA (cong tfacts (sym kfresh))))
                          inOld : (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old) = True)
                          inOld = lcyc_1_1__elem_ll_true _ _ (replace {p = \z => Elem (iret_11_3__fact_ids z) (iret_11_3__tok_ids old)} tk0 (lcyc_1_1__elem_map_fwd iret_11_3__ids ek0))
                      in absurd (trans (sym inOld) (lcyc_1_1__not_true_is_false _ notOld))
                    Right nfb => trans firedA (sym nfb)
  in iret_8_1__acts_ext _ acts' tupEq flags

-- ---------------------------------------------------------------------
-- The agreement
-- ---------------------------------------------------------------------

--@spec [RLOW.4.2.1]
||| Each rule of the program is, extensionally, the lowering of the
||| corresponding chain.
public export
data Rlow_4_2_1__rules_agree : List Iret_6_1__alpha -> List Rlow_4_2_1__chain -> List Lgra_6_1__rule -> Type where
  RANil  : Rlow_4_2_1__rules_agree alphas [] []
  RACons : Lgra_6_1__same_rule r (rlow_4_2_1__rule_of alphas c) -> Rlow_4_2_1__rules_agree alphas cs rs -> Rlow_4_2_1__rules_agree alphas (c :: cs) (r :: rs)

--@spec [RLOW.4.2.1]
--@spec [IRET.11]
--@spec [IDAT.6.2.2]
||| Each table's unblocked tokens are the corresponding terminal's
||| activations, in order and with their flags.
public export
data Rlow_4_2_1__tables_agree : List (List Iret_11__tok) -> List Rlow_4_2_1__chain -> Type where
  TANil  : Rlow_4_2_1__tables_agree [] []
  TACons : iret_11_3_1__unblocked_acts ts = cacts c -> Rlow_4_2_1__tables_agree tss cs -> Rlow_4_2_1__tables_agree (ts :: tss) (c :: cs)

--@spec [RLOW.4.2.1]
--@spec [RARC.5.6.5]
||| THE NETWORK AND FIRELOOP AGREE: one working memory; each rule the
||| lowering of its chain; each table's unblocked tokens its terminal's
||| activations; both sides well-formed.
public export
Rlow_4_2_1__agree : Lcyc_3_2_1__program -> Rarc_5_6_4__wm -> Rarc_5_3_1__network -> List (List Iret_11__tok) -> Type
Rlow_4_2_1__agree p wm net toks =
  ( Rlow_4_2_1__rules_agree (nalphas net) (nchains net) (rules p)
  , Rlow_4_2_1__tables_agree toks (nchains net)
  , Ldet_5_9__ordered (MkEngine wm net)
  , Rarc_5_6_5__well p (MkState wm toks) )

--@derives [RLOW.4.2.1]
||| Rules agree with the new chains when the shapes are kept.
export
rlow_4_2_1__rules_agree_shape : (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_1__same_alphas alphas alphas' ->
                                (cs, cs' : List Rlow_4_2_1__chain) -> (rs : List Lgra_6_1__rule) -> Rlow_4_2_1__rules_agree alphas cs rs ->
                                length cs' = length cs ->
                                ((i : Nat) -> (c, c' : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i cs = Just c -> rarc_5_6_5__nth i cs' = Just c' ->
                                 (Rlow_4_2_1__same_shape (cnodes c) (cnodes c'), cactions c' = cactions c)) ->
                                Rlow_4_2_1__rules_agree alphas' cs' rs
rlow_4_2_1__rules_agree_shape alphas alphas' sa [] [] [] RANil _ _ = RANil
rlow_4_2_1__rules_agree_shape alphas alphas' sa [] (c' :: cs') [] RANil len _ = absurd len
rlow_4_2_1__rules_agree_shape alphas alphas' sa (c :: cs) [] (r :: rs) (RACons _ _) len _ = absurd len
rlow_4_2_1__rules_agree_shape alphas alphas' sa (c :: cs) (c' :: cs') (r :: rs) (RACons sr rest) len sh =
  let (ss, ac) = sh 0 c c' Refl Refl
  in RACons (lgra_6_1__same_rule_trans r (rlow_4_2_1__rule_of alphas c) (rlow_4_2_1__rule_of alphas' c') sr (rlow_4_2_1__rule_of_same alphas alphas' sa c c' ss ac))
            (rlow_4_2_1__rules_agree_shape alphas alphas' sa cs cs' rs rest (cong pred len) (\i, d, d', n, n' => sh (S i) d d' n n'))

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.5]
||| Tables agree with the new terminals after a propagation, rule by rule.
export
rlow_4_2_1__tables_agree_step : (alphas' : List Iret_6_1__alpha) -> (wm, wm' : Rarc_5_6_4__wm) -> Iret_4_4__unique wm' ->
                                (cs, cs' : List Rlow_4_2_1__chain) -> (rs : List Lgra_6_1__rule) -> (tss : List (List Iret_11__tok)) ->
                                Rlow_4_2_1__rules_agree alphas' cs' rs -> Rlow_4_2_1__tables_agree tss cs ->
                                Rarc_5_6_5__tables_well wm rs tss -> Rarc_5_6_5__tables_well wm' rs (zipWith (\r, ts => rarc_5_6_5__prop_rule r wm' ts) rs tss) ->
                                All (\c => Ldet_5_5__ordered_acts wm' (cacts c)) cs' ->
                                ((c' : Rlow_4_2_1__chain) -> Elem c' cs' -> Iret_11_3__distinct (iret_8_1__tuples (cacts c'))) ->
                                ((c' : Rlow_4_2_1__chain) -> Elem c' cs' ->
                                 Iret_7_4__same_set (iret_8_1__tuples (cacts c'))
                                   (filter (\t => not (iret_7_9__is_blocked (rlow_4_2_1__rule_of alphas' c') wm' t)) (iret_7_4__match_tuples (rlow_4_2_1__rule_of alphas' c') wm'))) ->
                                ((i : Nat) -> (c, c' : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i cs = Just c -> rarc_5_6_5__nth i cs' = Just c' ->
                                 ( (a' : Iret_8_1__act) -> Elem a' (cacts c') -> Either (Elem a' (cacts c)) (afired a' = False)
                                 , (a : Iret_8_1__act) -> Elem a (cacts c) -> Elem (atuple a) (iret_8_1__tuples (cacts c')) -> Elem a (cacts c') )) ->
                                Rlow_4_2_1__tables_agree (zipWith (\r, ts => rarc_5_6_5__prop_rule r wm' ts) rs tss) cs'
rlow_4_2_1__tables_agree_step alphas' wm wm' uq' [] [] [] [] RANil TANil TWNil TWNil [] _ _ _ = TANil
rlow_4_2_1__tables_agree_step _ _ _ _ [] (_ :: _) _ _ (RACons _ _) TANil _ _ _ _ _ _ impossible
rlow_4_2_1__tables_agree_step _ _ _ _ (_ :: _) [] _ _ RANil (TACons _ _) _ _ _ _ _ _ impossible
rlow_4_2_1__tables_agree_step alphas' wm wm' uq' (c :: cs) (c' :: cs') (r :: rs) (ts :: tss) (RACons sr rrest) (TACons ag trest) (TWCons w s wrest) (TWCons w' s' wrest') (oc :: orest) dist same fl =
  let (p1, p2) = fl 0 c c' Refl Refl
      (sorted', _) = oc
      sameR : Iret_7_4__same_set (iret_8_1__tuples (cacts c')) (filter (\t => not (iret_7_9__is_blocked r wm' t)) (iret_7_4__match_tuples r wm'))
      sameR = replace {p = \z => Iret_7_4__same_set (iret_8_1__tuples (cacts c')) z}
                (trans (lcyc_1_1__filter_ext _ _ (\t => cong not (iret_7_9__is_blocked_same r (rlow_4_2_1__rule_of alphas' c') sr wm' t)) _)
                       (cong (filter (\t => not (iret_7_9__is_blocked r wm' t))) (iret_7_4__match_tuples_same r (rlow_4_2_1__rule_of alphas' c') sr wm')))
                (same c' Here)
  in TACons (rlow_4_2_1__prop_agree r wm wm' uq' ts w (cacts c) ag w' s' (cacts c') sorted' (dist c' Here) sameR p1 p2)
            (rlow_4_2_1__tables_agree_step alphas' wm wm' uq' cs cs' rs tss rrest trest wrest wrest' orest
               (\d, e => dist d (There e)) (\d, e => same d (There e)) (\i, d, d', n, n' => fl (S i) d d' n n'))

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.5]
||| THE AGREEMENT SURVIVES A CHANGE OF WORKING MEMORY: given the network
||| after the change, ordered; FireLoop's state after one propagation,
||| well-formed; the shapes kept; and the flags persisting.
export
rlow_4_2_1__change_agree : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                           Rlow_4_2_1__agree p wm net toks ->
                           (wm' : Rarc_5_6_4__wm) -> (net' : Rarc_5_3_1__network) -> Ldet_5_9__ordered (MkEngine wm' net') ->
                           Rarc_5_6_5__well p (MkState wm' (rarc_5_6_5__propagate p wm' toks)) ->
                           Iret_6_1__same_alphas (nalphas net) (nalphas net') -> length (nchains net') = length (nchains net) ->
                           ((i : Nat) -> (c, c' : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i (nchains net) = Just c -> rarc_5_6_5__nth i (nchains net') = Just c' ->
                            (Rlow_4_2_1__same_shape (cnodes c) (cnodes c'), cactions c' = cactions c)) ->
                           ((i : Nat) -> (c, c' : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i (nchains net) = Just c -> rarc_5_6_5__nth i (nchains net') = Just c' ->
                            ( (a' : Iret_8_1__act) -> Elem a' (cacts c') -> Either (Elem a' (cacts c)) (afired a' = False)
                            , (a : Iret_8_1__act) -> Elem a (cacts c) -> Elem (atuple a) (iret_8_1__tuples (cacts c')) -> Elem a (cacts c') )) ->
                           Rlow_4_2_1__agree p wm' net' (rarc_5_6_5__propagate p wm' toks)
rlow_4_2_1__change_agree p wm net toks (ra, ta, ord, (dw, uq, tw)) wm' net' ord' well' sa len sh fl =
  let ra' : Rlow_4_2_1__rules_agree (nalphas net') (nchains net') (rules p)
      ra' = rlow_4_2_1__rules_agree_shape (nalphas net) (nalphas net') sa (nchains net) (nchains net') (rules p) ra len sh
  in let (v', ordActs) = ord'
         (dw', uq', tw') = well'
  in ( ra'
     , rlow_4_2_1__tables_agree_step (nalphas net') wm wm' uq' (nchains net) (nchains net') (rules p) toks ra' ta tw tw' ordActs
         (\c', e => snd (snd (rarc_5_6_5__view_recomputed (MkEngine wm' net') v') c' e))
         (\c', e => rlow_4_2_1__terminal_agrees (MkEngine wm' net') v' c' e)
         fl
     , ord'
     , well' )

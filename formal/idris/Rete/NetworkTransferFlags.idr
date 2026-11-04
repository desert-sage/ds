-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE TRANSFER, PART TWO (iii): THE `fired` FLAG PERSISTS. A terminal
||| changes only by ending activations and activating new, unfired ones
||| ([IRET.8.1]); so after any change of working memory every activation
||| is an old one, flag and all, or a new one unfired. What this module
||| adds is the two facts that make the flag a function of the match's
||| history: an assertion creates only matches holding the new fact, and
||| a retraction ends only matches holding the retracted one -- so an
||| activation whose match survives the change is the same activation
||| afterwards. That is Rete/FireLoop.idr's `kept_of` on the network
||| side: [IDAT.6.2.2]'s "stays with `fired = true` until the LHS
||| changes", proved of the four propagation paths.
module Rete.NetworkTransferFlags

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
-- How a terminal evolves
-- ---------------------------------------------------------------------

--@spec [IRET.8.1]
--@spec [IDAT.6.2.2]
||| HOW A TERMINAL EVOLVES through some ended and some created matches:
||| every activation afterwards is an old one whose match did not end,
||| or an unfired one for a match created; every old activation whose
||| match did not end is still there.
public export
Iret_8_1__evolves : List Iret_8_1__act -> List Iret_8_1__act -> List Iret_7_1__token -> List Iret_7_1__token -> Type
Iret_8_1__evolves acts acts' ended created =
  ( (a' : Iret_8_1__act) -> Elem a' acts' -> Either (Elem a' acts, Not (Elem (atuple a') ended)) (Elem (atuple a') created, afired a' = False)
  , (a : Iret_8_1__act) -> Elem a acts -> Not (Elem (atuple a) ended) -> Elem a acts' )

--@derives [IRET.8.1]
export
iret_8_1__evolves_refl : (acts : List Iret_8_1__act) -> Iret_8_1__evolves acts acts [] []
iret_8_1__evolves_refl acts = (\a', e => Left (e, \x => absurd x), \a, e, _ => e)

--@derives [IRET.8.1]
||| Ending matches: the ended leave, nothing is created.
export
iret_8_1__evolves_end : (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> Iret_8_1__evolves acts (iret_8_1__end gone acts) gone []
iret_8_1__evolves_end gone acts =
  ( \a', e => let (ea, ng) = lcyc_1_1__elem_filter_inv (\a => not (rarc_5_6_5__elem (atuple a) gone)) acts e
              in Left (ea, iret_11_3__elem_tok_false (atuple a') gone (lcyc_1_1__not_true_is_false _ ng))
  , \a, e, ng => lcyc_1_1__elem_filter_fwd (\a => not (rarc_5_6_5__elem (atuple a) gone)) acts e (cong not (iret_11_3__not_elem_tok (atuple a) gone ng)) )

--@derives [IRET.8.1]
||| Activating matches: nothing ends, the matches are created unfired.
export
iret_8_1__evolves_activate : (wm : Rarc_5_6_4__wm) -> (ts : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                             Iret_8_1__evolves acts (iret_8_1__activate wm ts acts) [] ts
iret_8_1__evolves_activate wm [] acts = iret_8_1__evolves_refl acts
iret_8_1__evolves_activate wm (t :: ts) acts =
  let (e1, e2) = iret_8_1__evolves_activate wm ts (ldet_5_5__insert wm (MkAct t False) acts)
  in ( \a', e => case e1 a' e of
         Left (ei, _) => case iret_8_2__insert_act_inv wm (MkAct t False) acts a' ei of
           Left p   => Right (replace {p = \z => Elem (atuple z) (t :: ts)} (sym p) Here, cong afired p)
           Right ea => Left (ea, \x => absurd x)
         Right (ec, nf) => Right (There ec, nf)
     , \a, e, _ => e2 a (iret_8_1__insert_keeps wm (MkAct t False) acts a e) (\x => absurd x) )

--@derives [IRET.8.1]
||| Two evolutions compose.
export
iret_8_1__evolves_trans : (a1, a2, a3 : List Iret_8_1__act) -> (e1, c1, e2, c2 : List Iret_7_1__token) ->
                          Iret_8_1__evolves a1 a2 e1 c1 -> Iret_8_1__evolves a2 a3 e2 c2 -> Iret_8_1__evolves a1 a3 (e1 ++ e2) (c1 ++ c2)
iret_8_1__evolves_trans a1 a2 a3 e1 c1 e2 c2 (f1, g1) (f2, g2) =
  ( \a', e => case f2 a' e of
      Left (ea2, ne2) => case f1 a' ea2 of
        Left (ea1, ne1) => Left (ea1, \x => case lcyc_1_1__elem_append_inv e1 x of
                                               Left l  => ne1 l
                                               Right r => ne2 r)
        Right (ec1, nf) => Right (lcyc_1_1__elem_append_left ec1, nf)
      Right (ec2, nf) => Right (lcyc_1_1__elem_append_right c1 ec2, nf)
  , \a, e, ne => g2 a (g1 a e (\x => ne (lcyc_1_1__elem_append_left x))) (\x => ne (lcyc_1_1__elem_append_right e1 x)) )

-- ---------------------------------------------------------------------
-- What the paths end and create
-- ---------------------------------------------------------------------

--@derives [IRET.7.9.1]
||| A token that passes clear from a prefix extends it.
export
iret_7_9_1__clear_prefix : (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (u, tok : Iret_7_1__token) ->
                           Iret_7_9_1__clear alphas nodes u tok -> (s ** tok = u ++ s)
iret_7_9_1__clear_prefix alphas [] u tok eq = ([] ** trans (sym eq) (sym (appendNilRightNeutral u)))
iret_7_9_1__clear_prefix alphas (MkBeta a j True lm cs :: rest) u tok (_, cl) = iret_7_9_1__clear_prefix alphas rest u tok cl
iret_7_9_1__clear_prefix alphas (MkBeta a j False lm cs :: rest) u tok (f ** (_, _, cl)) =
  let (s ** eq) = iret_7_9_1__clear_prefix alphas rest (u ++ [f]) tok cl
  in ((f :: s) ** trans eq (sym (appendAssociative u [f] s)))

--@derives [IRET.7.8]
||| What leaves a chain when tokens leave its front extends one of them.
export
iret_7_8__through_gone_prefix : (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (gone : List Iret_7_1__token) -> (tok : Iret_7_1__token) ->
                                Elem tok (iret_7_8__through_gone alphas nodes gone) -> (u ** (Elem u gone, (s ** tok = u ++ s)))
iret_7_8__through_gone_prefix alphas [] gone tok e = (tok ** (e, ([] ** sym (appendNilRightNeutral tok))))
iret_7_8__through_gone_prefix alphas (MkBeta a j True lm cs :: rest) gone tok e =
  let (u ** (eu, ext)) = iret_7_8__through_gone_prefix alphas rest _ tok e
  in (u ** (fst (lcyc_1_1__elem_filter_inv (\t => iret_7_9_4__count t cs == 0) gone eu), ext))
iret_7_8__through_gone_prefix alphas (MkBeta a j False lm cs :: rest) gone tok e =
  let (u' ** (eu', (s ** eq))) = iret_7_8__through_gone_prefix alphas rest _ tok e
      (u ** (f ** (eu, _, _, ueq))) = iret_7_7__extend_elem_inv j (iret_6_6__mem_at alphas a) gone u' eu'
  in (u ** (eu, ((f :: s) ** trans eq (trans (cong (\x => x ++ s) ueq) (sym (appendAssociative u [f] s))))))

--@derives [IRET.7.7]
--@derives [IRET.8.1]
||| LEFT-ACTIVATION ends nothing and creates what the chain passes.
export
iret_7_7__wave_evolves : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (front : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                         Iret_8_1__evolves acts (snd (iret_7_7__wave wm alphas nodes front acts)) [] (iret_7_7__through alphas nodes front)
iret_7_7__wave_evolves wm alphas nodes front acts =
  replace {p = \z => Iret_8_1__evolves acts z [] (iret_7_7__through alphas nodes front)} (sym (iret_7_7__wave_snd wm alphas nodes front acts))
    (iret_8_1__evolves_activate wm (iret_7_7__through alphas nodes front) acts)

--@derives [IRET.7.8]
--@derives [IRET.8.1]
||| LEFT-RETRACTION creates nothing and ends what leaves the chain.
export
iret_7_8__unwave_evolves : (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                           Iret_8_1__evolves acts (snd (iret_7_8__unwave alphas nodes gone acts)) (iret_7_8__through_gone alphas nodes gone) []
iret_7_8__unwave_evolves alphas nodes gone acts =
  replace {p = \z => Iret_8_1__evolves acts z (iret_7_8__through_gone alphas nodes gone) []} (sym (iret_7_8__unwave_snd alphas nodes gone acts))
    (iret_8_1__evolves_end (iret_7_8__through_gone alphas nodes gone) acts)

--@derives [IRET.7.7]
--@derives [IRET.7.9.2]
--@derives [IRET.8.1]
||| RIGHT-ACTIVATION by a fact creates only matches holding it: the
||| extensions the fact makes, passed down the chain.
export
iret_7_7__right_activate_evolves : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) ->
                                   (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                   (ended ** (created ** ( Iret_8_1__evolves acts (snd (iret_7_7__right_activate wm alphas a f nodes acts)) ended created
                                                         , All (\t => Elem f t) created )))
iret_7_7__right_activate_evolves wm alphas a f [] acts = ([] ** ([] ** (iret_8_1__evolves_refl acts, [])))
iret_7_7__right_activate_evolves wm alphas a f (b :: rest) acts with (balpha b == a)
  iret_7_7__right_activate_evolves wm alphas a f (b :: rest) acts | False = iret_7_7__right_activate_evolves wm alphas a f rest acts
  iret_7_7__right_activate_evolves wm alphas a f (b :: rest) acts | True with (bneg b)
    iret_7_7__right_activate_evolves wm alphas a f (b :: rest) acts | True | True =
      let (e1 ** (c1 ** (ev1, pc1))) = iret_7_7__right_activate_evolves wm alphas a f rest acts
      in ((e1 ++ iret_7_8__through_gone alphas (fst (iret_7_7__right_activate wm alphas a f rest acts))
                   (filter (\t => iret_7_9_4__count t (bcounts b) == 0) (filter (\t => bjoin b t f) (blmem b)))) **
          ((c1 ++ []) **
           ( iret_8_1__evolves_trans _ _ _ e1 c1 _ [] ev1
               (iret_7_8__unwave_evolves alphas (fst (iret_7_7__right_activate wm alphas a f rest acts))
                  (filter (\t => iret_7_9_4__count t (bcounts b) == 0) (filter (\t => bjoin b t f) (blmem b)))
                  (snd (iret_7_7__right_activate wm alphas a f rest acts)))
           , lcyc_1_1__all_append pc1 [] )))
    iret_7_7__right_activate_evolves wm alphas a f (b :: rest) acts | True | False =
      let (e1 ** (c1 ** (ev1, pc1))) = iret_7_7__right_activate_evolves wm alphas a f rest acts
          created2 : All (\t => Elem f t) (iret_7_7__through alphas (fst (iret_7_7__right_activate wm alphas a f rest acts)) (map (\t => t ++ [f]) (filter (\t => bjoin b t f) (blmem b))))
          created2 = lcyc_1_1__all_from_elem _ (\tok, e =>
                       let (u ** (eu, cl)) = iret_7_7__through_clear alphas (fst (iret_7_7__right_activate wm alphas a f rest acts)) _ tok e
                           (t ** (_, ueq)) = lcyc_1_1__elem_map_inv (\t => t ++ [f]) (filter (\t => bjoin b t f) (blmem b)) eu
                           (s ** teq) = iret_7_9_1__clear_prefix alphas (fst (iret_7_7__right_activate wm alphas a f rest acts)) u tok cl
                           inU : Elem f u
                           inU = replace {p = \z => Elem f z} ueq (lcyc_1_1__elem_append_right t Here)
                       in replace {p = \z => Elem f z} (sym teq) (lcyc_1_1__elem_append_left inU))
      in ((e1 ++ []) **
          ((c1 ++ iret_7_7__through alphas (fst (iret_7_7__right_activate wm alphas a f rest acts)) (map (\t => t ++ [f]) (filter (\t => bjoin b t f) (blmem b)))) **
           ( iret_8_1__evolves_trans _ _ _ e1 c1 [] _ ev1
               (iret_7_7__wave_evolves wm alphas (fst (iret_7_7__right_activate wm alphas a f rest acts))
                  (map (\t => t ++ [f]) (filter (\t => bjoin b t f) (blmem b))) (snd (iret_7_7__right_activate wm alphas a f rest acts)))
           , lcyc_1_1__all_append pc1 created2 )))

--@derives [IRET.7.7]
--@derives [IRET.7.9.3]
--@derives [IRET.8.1]
||| RIGHT-RETRACTION of a fact ends only matches holding it: the
||| extensions it had made, withdrawn down the chain.
export
iret_7_7__right_retract_evolves : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) ->
                                  (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                  (ended ** (created ** ( Iret_8_1__evolves acts (snd (iret_7_7__right_retract wm alphas a f nodes acts)) ended created
                                                        , All (\t => Elem f t) ended )))
iret_7_7__right_retract_evolves wm alphas a f [] acts = ([] ** ([] ** (iret_8_1__evolves_refl acts, [])))
iret_7_7__right_retract_evolves wm alphas a f (b :: rest) acts with (balpha b == a)
  iret_7_7__right_retract_evolves wm alphas a f (b :: rest) acts | False = iret_7_7__right_retract_evolves wm alphas a f rest acts
  iret_7_7__right_retract_evolves wm alphas a f (b :: rest) acts | True with (bneg b)
    iret_7_7__right_retract_evolves wm alphas a f (b :: rest) acts | True | True =
      let (e1 ** (c1 ** (ev1, pe1))) = iret_7_7__right_retract_evolves wm alphas a f rest acts
      in ((e1 ++ []) **
          ((c1 ++ iret_7_7__through alphas (fst (iret_7_7__right_retract wm alphas a f rest acts))
                    (filter (\t => iret_7_9_4__count t (bcounts b) == 1) (filter (\t => bjoin b t f) (blmem b)))) **
           ( iret_8_1__evolves_trans _ _ _ e1 c1 [] _ ev1
               (iret_7_7__wave_evolves wm alphas (fst (iret_7_7__right_retract wm alphas a f rest acts))
                  (filter (\t => iret_7_9_4__count t (bcounts b) == 1) (filter (\t => bjoin b t f) (blmem b)))
                  (snd (iret_7_7__right_retract wm alphas a f rest acts)))
           , lcyc_1_1__all_append pe1 [] )))
    iret_7_7__right_retract_evolves wm alphas a f (b :: rest) acts | True | False =
      let (e1 ** (c1 ** (ev1, pe1))) = iret_7_7__right_retract_evolves wm alphas a f rest acts
          ended2 : All (\t => Elem f t) (iret_7_8__through_gone alphas (fst (iret_7_7__right_retract wm alphas a f rest acts)) (map (\t => t ++ [f]) (filter (\t => bjoin b t f) (blmem b))))
          ended2 = lcyc_1_1__all_from_elem _ (\tok, e =>
                     let (u ** (eu, (s ** teq))) = iret_7_8__through_gone_prefix alphas (fst (iret_7_7__right_retract wm alphas a f rest acts)) _ tok e
                         (t ** (_, ueq)) = lcyc_1_1__elem_map_inv (\t => t ++ [f]) (filter (\t => bjoin b t f) (blmem b)) eu
                         inU : Elem f u
                         inU = replace {p = \z => Elem f z} ueq (lcyc_1_1__elem_append_right t Here)
                     in replace {p = \z => Elem f z} (sym teq) (lcyc_1_1__elem_append_left inU))
      in ((e1 ++ iret_7_8__through_gone alphas (fst (iret_7_7__right_retract wm alphas a f rest acts)) (map (\t => t ++ [f]) (filter (\t => bjoin b t f) (blmem b)))) **
          ((c1 ++ []) **
           ( iret_8_1__evolves_trans _ _ _ e1 c1 _ [] ev1
               (iret_7_8__unwave_evolves alphas (fst (iret_7_7__right_retract wm alphas a f rest acts))
                  (map (\t => t ++ [f]) (filter (\t => bjoin b t f) (blmem b))) (snd (iret_7_7__right_retract wm alphas a f rest acts)))
           , lcyc_1_1__all_append pe1 ended2 )))

-- ---------------------------------------------------------------------
-- Through alpha dispatch
-- ---------------------------------------------------------------------

--@derives [IRET.6.4]
--@derives [IRET.8.1]
||| ALPHA DISPATCH ON ASSERT evolves every terminal creating only matches
||| that hold the fact.
export
iret_6_4__dispatch_assert_evolves : (wm' : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (is : List Nat) -> (net : Rarc_5_3_1__network) ->
                                    (i : Nat) -> (c, c' : Rlow_4_2_1__chain) ->
                                    rarc_5_6_5__nth i (nchains net) = Just c -> rarc_5_6_5__nth i (nchains (iret_6_4__dispatch_assert wm' f is net)) = Just c' ->
                                    (ended ** (created ** (Iret_8_1__evolves (cacts c) (cacts c') ended created, All (\t => Elem f t) created)))
iret_6_4__dispatch_assert_evolves wm' f [] net i c c' n n' =
  replace {p = \z => (ended ** (created ** (Iret_8_1__evolves (cacts c) (cacts z) ended created, All (\t => Elem f t) created)))}
    (iret_11_4__just_inj (trans (sym n) n')) ([] ** ([] ** (iret_8_1__evolves_refl (cacts c), [])))
iret_6_4__dispatch_assert_evolves wm' f (k :: is) (MkNetwork alphas chains) i c c' n n' with (iret_6_4__admits (iret_6_6__alpha_at alphas k) f)
  iret_6_4__dispatch_assert_evolves wm' f (k :: is) (MkNetwork alphas chains) i c c' n n' | False =
    iret_6_4__dispatch_assert_evolves wm' f is (MkNetwork alphas chains) i c c' n n'
  iret_6_4__dispatch_assert_evolves wm' f (k :: is) (MkNetwork alphas chains) i c c' n n' | True =
    let n1 : (rarc_5_6_5__nth i (map (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f) chains)
              = Just (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f c))
        n1 = trans (lcyc_1_1__nth_map (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f) i chains) (cong (map _) n)
    in let (e1 ** (c1 ** (ev1, pc1))) = iret_7_7__right_activate_evolves wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f (cnodes c) (cacts c)
       in let (e2 ** (c2 ** (ev2, pc2))) = iret_6_4__dispatch_assert_evolves wm' f is
                                             (MkNetwork (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) (map (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f) chains))
                                             i (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f c) c' n1 n'
          in ((e1 ++ e2) ** ((c1 ++ c2) ** (iret_8_1__evolves_trans _ _ _ e1 c1 e2 c2 ev1 ev2, lcyc_1_1__all_append pc1 pc2)))

--@derives [IRET.19.2]
--@derives [IRET.8.1]
||| ALPHA DISPATCH ON RETRACT evolves every terminal ending only matches
||| that hold the fact.
export
iret_19_2__dispatch_retract_evolves : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (is : List Nat) -> (net : Rarc_5_3_1__network) ->
                                      (i : Nat) -> (c, c' : Rlow_4_2_1__chain) ->
                                      rarc_5_6_5__nth i (nchains net) = Just c -> rarc_5_6_5__nth i (nchains (iret_19_2__dispatch_retract wm f is net)) = Just c' ->
                                      (ended ** (created ** (Iret_8_1__evolves (cacts c) (cacts c') ended created, All (\t => Elem f t) ended)))
iret_19_2__dispatch_retract_evolves wm f [] net i c c' n n' =
  replace {p = \z => (ended ** (created ** (Iret_8_1__evolves (cacts c) (cacts z) ended created, All (\t => Elem f t) ended)))}
    (iret_11_4__just_inj (trans (sym n) n')) ([] ** ([] ** (iret_8_1__evolves_refl (cacts c), [])))
iret_19_2__dispatch_retract_evolves wm f (k :: is) (MkNetwork alphas chains) i c c' n n' with (iret_6_4__admits (iret_6_6__alpha_at alphas k) f)
  iret_19_2__dispatch_retract_evolves wm f (k :: is) (MkNetwork alphas chains) i c c' n n' | False =
    iret_19_2__dispatch_retract_evolves wm f is (MkNetwork alphas chains) i c c' n n'
  iret_19_2__dispatch_retract_evolves wm f (k :: is) (MkNetwork alphas chains) i c c' n n' | True =
    let n1 : (rarc_5_6_5__nth i (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f) chains)
              = Just (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f c))
        n1 = trans (lcyc_1_1__nth_map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f) i chains) (cong (map _) n)
    in let (e1 ** (c1 ** (ev1, pe1))) = iret_7_7__right_retract_evolves wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f (cnodes c) (cacts c)
       in let (e2 ** (c2 ** (ev2, pe2))) = iret_19_2__dispatch_retract_evolves wm f is
                                             (MkNetwork (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f) chains))
                                             i (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f c) c' n1 n'
          in ((e1 ++ e2) ** ((c1 ++ c2) ** (iret_8_1__evolves_trans _ _ _ e1 c1 e2 c2 ev1 ev2, lcyc_1_1__all_append pe1 pe2)))

-- ---------------------------------------------------------------------
-- The flag persists
-- ---------------------------------------------------------------------

--@derives [IRET.11.3]
||| With distinct identities, two activations of one terminal with one
||| match are one activation.
export
iret_11_3__same_tuple_same_act : (acts : List Iret_8_1__act) -> Iret_11_3__distinct (iret_8_1__tuples acts) ->
                                 (a, b : Iret_8_1__act) -> Elem a acts -> Elem b acts -> atuple a = atuple b -> a = b
iret_11_3__same_tuple_same_act (x :: xs) (DCons nx d) a b ea eb eq =
  case (iret_11_3__elem_cons ea, iret_11_3__elem_cons eb) of
    (Left pa, Left pb) => trans pa (sym pb)
    (Left pa, Right eb') => void (nx (replace {p = \z => Elem z (iret_8_1__tuples xs)} (trans (sym eq) (cong atuple pa)) (lcyc_1_1__elem_map_fwd atuple eb')))
    (Right ea', Left pb) => void (nx (replace {p = \z => Elem z (iret_8_1__tuples xs)} (trans eq (cong atuple pb)) (lcyc_1_1__elem_map_fwd atuple ea')))
    (Right ea', Right eb') => iret_11_3__same_tuple_same_act xs d a b ea' eb' eq

--@derives [IDAT.6.2.2]
--@derives [IRET.19.1]
--@derives [IRET.8.1]
||| INSERTING A FRESH FACT: every activation afterwards is an old one or
||| unfired, and every old activation whose match survives is still
||| there, flag and all -- the fact is in no old match, so no old match
||| is created anew.
export
iret_19_1__insert_flags : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Not (Elem f (ewm eng)) -> Iret_19__view eng ->
                          (i : Nat) -> (c, c' : Rlow_4_2_1__chain) ->
                          rarc_5_6_5__nth i (nchains (enet eng)) = Just c -> rarc_5_6_5__nth i (nchains (enet (iret_19_1__insert f eng))) = Just c' ->
                          ( (a' : Iret_8_1__act) -> Elem a' (cacts c') -> Either (Elem a' (cacts c)) (Elem f (atuple a'), afired a' = False)
                          , (a : Iret_8_1__act) -> Elem a (cacts c) -> Elem (atuple a) (iret_8_1__tuples (cacts c')) -> Elem a (cacts c') )
iret_19_1__insert_flags f (MkEngine wm (MkNetwork alphas chains)) nf v i c c' n n' =
  let (dw, dm, mv, cons) = v
      (ended ** (created ** ((e1, e2), pc))) = iret_6_4__dispatch_assert_evolves (wm ++ [f]) f (iret_1_7__indices (length alphas)) (MkNetwork alphas chains) i c c' n n'
      ec : Elem c chains
      ec = lcyc_1_1__nth_elem i chains n
      dt : Iret_11_3__distinct (iret_8_1__tuples (cacts c))
      dt = iret_7_7__consistent_distinct alphas [[]] (cnodes c) (cacts c) (lcyc_1_1__all_lookup cons ec)
      liveOld : Ldet_5_5__live_acts wm (cacts c)
      liveOld = lcyc_1_1__all_lookup (ldet_5_5__view_live_acts (MkEngine wm (MkNetwork alphas chains)) v) ec
  in ( \a', e => case e1 a' e of
         Left (ea, _) => Left ea
         Right (ecr, nfa) => Right (lcyc_1_1__all_lookup pc ecr, nfa)
     , \a, ea, et =>
         let (a'' ** (ea'', teq)) = lcyc_1_1__elem_map_inv atuple (cacts c') et
         in case e1 a'' ea'' of
              Left (eold, _) => replace {p = \z => Elem z (cacts c')} (iret_11_3__same_tuple_same_act (cacts c) dt a'' a eold ea teq) ea''
              Right (ecr, _) => void (nf (lcyc_1_1__all_lookup (lcyc_1_1__all_lookup liveOld ea)
                                            (replace {p = \z => Elem f z} teq (lcyc_1_1__all_lookup pc ecr)))) )

--@derives [IDAT.6.2.2]
--@derives [IRET.19.2]
--@derives [IRET.8.1]
||| RETRACTING A LIVE FACT: every activation afterwards is an old one or
||| unfired, and every old activation whose match survives is still
||| there, flag and all -- only matches holding the fact end, and no
||| surviving match holds it.
export
iret_19_2__retract_flags : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Elem f (ewm eng) -> Iret_19__view eng ->
                           (i : Nat) -> (c, c' : Rlow_4_2_1__chain) ->
                           rarc_5_6_5__nth i (nchains (enet eng)) = Just c -> rarc_5_6_5__nth i (nchains (enet (iret_19_2__retract f eng))) = Just c' ->
                           ( (a' : Iret_8_1__act) -> Elem a' (cacts c') -> Either (Elem a' (cacts c)) (afired a' = False)
                           , (a : Iret_8_1__act) -> Elem a (cacts c) -> Elem (atuple a) (iret_8_1__tuples (cacts c')) -> Elem a (cacts c') )
iret_19_2__retract_flags f (MkEngine wm (MkNetwork alphas chains)) ef v i c c' n n' =
  let (ended ** (created ** ((e1, e2), pe))) = iret_19_2__dispatch_retract_evolves wm f (iret_1_7__indices (length alphas)) (MkNetwork alphas chains) i c c' n n'
      v' = iret_19_2__retract_view f (MkEngine wm (MkNetwork alphas chains)) ef v
      liveNew : Ldet_5_5__live_acts (rarc_5_6_4__remove_exact f wm) (cacts c')
      liveNew = lcyc_1_1__all_lookup (ldet_5_5__view_live_acts (iret_19_2__retract f (MkEngine wm (MkNetwork alphas chains))) v')
                  (lcyc_1_1__nth_elem i _ n')
  in ( \a', e => case e1 a' e of
         Left (ea, _) => Left ea
         Right (_, nfa) => Right nfa
     , \a, ea, et =>
         let (a'' ** (ea'', teq)) = lcyc_1_1__elem_map_inv atuple (cacts c') et
             notF : Not (Elem f (atuple a))
             notF = \x => snd (rarc_5_6_4__remove_exact_elem_inv f wm f
                                 (lcyc_1_1__all_lookup (lcyc_1_1__all_lookup liveNew ea'') (replace {p = \z => Elem f z} (sym teq) x))) Refl
         in e2 a ea (\x => notF (lcyc_1_1__all_lookup pe x)) )

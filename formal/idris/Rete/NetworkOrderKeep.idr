-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE ORDER THEOREM, closed at the top [LDET.5.5], [LDET.5.9]: after
||| any history from a loaded network, every terminal's activations are,
||| in order, the canonical order over working memory of the chain's
||| recompute. The agenda order is a function of the activation set and
||| of working memory, never of how the set was reached — batched equals
||| incremental in order [IRET.11.3.3], a released match fires where it
||| first completed [LDET.5.9], and no two activations of one rule share
||| a timetag RARC.5.4.9, [IRET.11.1]. Each propagation path, each
||| dispatch and each engine operation of Rete/Network.idr keeps every
||| terminal sorted by the order of Rete/NetworkOrder.idr.
|||
||| NORMATIVE COMPANION to Rete/Network.idr.
module Rete.NetworkOrderKeep

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.NetworkOrder
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
-- What reaches the terminal
-- ---------------------------------------------------------------------

--@derives [IRET.7.7]
||| The tokens a front becomes at the terminal, through the memories as
||| they stand: what a wave activates.
public export
iret_7_7__through : List Iret_6_1__alpha -> List Iret_7_4__beta -> List Iret_7_1__token -> List Iret_7_1__token
iret_7_7__through alphas [] front = front
iret_7_7__through alphas (b :: rest) front = iret_7_7__through alphas rest (iret_7_7__next b (iret_6_6__mem_at alphas (balpha b)) front)

--@derives [IRET.7.7]
export
iret_7_7__wave_snd : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (new : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                     snd (iret_7_7__wave wm alphas nodes new acts) = iret_8_1__activate wm (iret_7_7__through alphas nodes new) acts
iret_7_7__wave_snd wm alphas [] new acts = Refl
iret_7_7__wave_snd wm alphas (b :: rest) new acts = iret_7_7__wave_snd wm alphas rest (iret_7_7__next b (iret_6_6__mem_at alphas (balpha b)) new) acts

--@derives [IRET.7.8]
||| The tokens departing tokens end at the terminal: what an unwave ends.
public export
iret_7_8__through_gone : List Iret_6_1__alpha -> List Iret_7_4__beta -> List Iret_7_1__token -> List Iret_7_1__token
iret_7_8__through_gone alphas [] gone = gone
iret_7_8__through_gone alphas (b :: rest) gone = iret_7_8__through_gone alphas rest (iret_7_8__gone b (iret_6_6__mem_at alphas (balpha b)) gone)

--@derives [IRET.7.8]
export
iret_7_8__unwave_snd : (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                       snd (iret_7_8__unwave alphas nodes gone acts) = iret_8_1__end (iret_7_8__through_gone alphas nodes gone) acts
iret_7_8__unwave_snd alphas [] gone acts = Refl
iret_7_8__unwave_snd alphas (b :: rest) gone acts = iret_7_8__unwave_snd alphas rest (iret_7_8__gone b (iret_6_6__mem_at alphas (balpha b)) gone) acts

--@derives [IRET.7.7]
export
iret_7_7__through_distinct : (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas -> (nodes : List Iret_7_4__beta) ->
                             (front : List Iret_7_1__token) -> Iret_11_3__distinct front -> Iret_11_3__distinct (iret_7_7__through alphas nodes front)
iret_7_7__through_distinct alphas dm [] front df = df
iret_7_7__through_distinct alphas dm (b :: rest) front df =
  iret_7_7__through_distinct alphas dm rest _ (iret_7_7__next_distinct (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) (dm (balpha b)) front df)

--@derives [IRET.7.7]
export
iret_7_7__through_disjoint : (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (xs, ys : List Iret_7_1__token) ->
                             ((t : Iret_7_1__token) -> Elem t ys -> Not (Elem t xs)) ->
                             (y : Iret_7_1__token) -> Elem y (iret_7_7__through alphas nodes ys) -> Not (Elem y (iret_7_7__through alphas nodes xs))
iret_7_7__through_disjoint alphas [] xs ys disj y ey ex = disj y ey ex
iret_7_7__through_disjoint alphas (b :: rest) xs ys disj y ey ex =
  iret_7_7__through_disjoint alphas rest _ _ (iret_7_7__next_disjoint (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) xs ys disj) y ey ex

--@derives [IRET.7.7]
||| A consistent chain's terminal holds what its front becomes.
export
iret_7_7__consistent_through : (alphas : List Iret_6_1__alpha) -> (front : List Iret_7_1__token) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                               Iret_7_7__consistent alphas front nodes acts -> Iret_7_4__same_set (iret_8_1__tuples acts) (iret_7_7__through alphas nodes front)
iret_7_7__consistent_through alphas front [] acts (sa, _) = sa
iret_7_7__consistent_through alphas front (b :: rest) acts (_, _, _, rec) = iret_7_7__consistent_through alphas _ rest acts rec

--@derives [IRET.6.5]
||| Every alpha memory holds live facts.
public export
Iret_6_5__mems_live : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> Type
Iret_6_5__mems_live wm alphas = (i : Nat) -> (g : Lfac_1_7_1__fact) -> Elem g (iret_6_6__mem_at alphas i) -> Elem g wm

--@derives [IRET.7.7]
||| What a node passes on from live tokens, over a live memory, is live.
export
iret_7_7__next_live : (wm : Rarc_5_6_4__wm) -> (neg : Bool) -> (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) ->
                      ((g : Lfac_1_7_1__fact) -> Elem g mem -> Elem g wm) ->
                      (front : List Iret_7_1__token) -> All (Ldet_5_5__live wm) front -> All (Ldet_5_5__live wm) (iret_7_7__next_of neg j mem front)
iret_7_7__next_live wm True j mem ml front lv = lcyc_1_1__all_filter (\t => iret_7_9_1__blockers j mem t == 0) front lv
iret_7_7__next_live wm False j mem ml front lv =
  lcyc_1_1__all_from_elem (iret_7_7__extend_front j mem front) (\y, ey =>
    let (t ** (f ** (et, ef, _, eq))) = iret_7_7__extend_elem_inv j mem front y ey
    in replace {p = \z => Ldet_5_5__live wm z} (sym eq) (lcyc_1_1__all_append (lcyc_1_1__all_lookup lv et) [ml f ef]))

--@derives [IRET.7.7]
export
iret_7_7__through_live : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> Iret_6_5__mems_live wm alphas -> (nodes : List Iret_7_4__beta) ->
                         (front : List Iret_7_1__token) -> All (Ldet_5_5__live wm) front -> All (Ldet_5_5__live wm) (iret_7_7__through alphas nodes front)
iret_7_7__through_live wm alphas ml [] front lv = lv
iret_7_7__through_live wm alphas ml (b :: rest) front lv =
  iret_7_7__through_live wm alphas ml rest _ (iret_7_7__next_live wm (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) (\g, e => ml (balpha b) g e) front lv)

--@derives [IRET.6.5]
||| A memory that shows the working-memory view holds live facts.
export
iret_6_5__view_live : (wm, target : Rarc_5_6_4__wm) -> ((g : Lfac_1_7_1__fact) -> Elem g wm -> Elem g target) ->
                      (a : Iret_6_1__alpha) -> (g : Lfac_1_7_1__fact) -> Elem g (iret_6_5__view a wm) -> Elem g target
iret_6_5__view_live wm target sub a g e = sub g (fst (lcyc_1_1__elem_filter_inv (iret_6_4__admits a) wm e))

--@derives [IRET.6.4]
||| Midway through a dispatch every memory holds facts of one of the two
||| working memories.
export
iret_6_4__dispatch_inv_live : (old, new, target : Rarc_5_6_4__wm) -> (is : List Nat) -> (net : Rarc_5_3_1__network) ->
                              Iret_6_4__dispatch_inv old new is net ->
                              ((g : Lfac_1_7_1__fact) -> Elem g old -> Elem g target) -> ((g : Lfac_1_7_1__fact) -> Elem g new -> Elem g target) ->
                              Iret_6_5__mems_live target (nalphas net)
iret_6_4__dispatch_inv_live old new target is net (_, pend, done, _) so sn i g e = case isElem i is of
  Yes ei => iret_6_5__view_live old target so _ g (replace {p = \z => Elem g z} (pend i ei) e)
  No ni  => iret_6_5__view_live new target sn _ g (replace {p = \z => Elem g z} (done i ni) e)

-- ---------------------------------------------------------------------
-- The order through the propagation paths
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
||| A terminal in agenda order, of live activations.
public export
Ldet_5_5__ordered_acts : Rarc_5_6_4__wm -> List Iret_8_1__act -> Type
Ldet_5_5__ordered_acts wm acts = (Ldet_5_5__sorted wm acts, Ldet_5_5__live_acts wm acts)

--@derives [LDET.5.5]
--@derives [IRET.7.7]
||| LEFT-ACTIVATION KEEPS THE ORDER: the matches new arrivals complete
||| take their places.
export
iret_7_7__wave_ordered : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas -> Iret_6_5__mems_live wm alphas ->
                         (front, new : List Iret_7_1__token) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                         Iret_7_7__consistent alphas front nodes acts -> Iret_11_3__distinct new -> All (Ldet_5_5__live wm) new ->
                         ((t : Iret_7_1__token) -> Elem t new -> Not (Elem t front)) ->
                         Ldet_5_5__ordered_acts wm acts -> Ldet_5_5__ordered_acts wm (snd (iret_7_7__wave wm alphas nodes new acts))
iret_7_7__wave_ordered wm dw alphas dm ml front new nodes acts cons dn ln disj (sa, la) =
  replace {p = \x => Ldet_5_5__ordered_acts wm x} (sym (iret_7_7__wave_snd wm alphas nodes new acts))
    (iret_8_1__activate_sorted wm dw (iret_7_7__through alphas nodes new) (iret_7_7__through_distinct alphas dm nodes new dn)
       (iret_7_7__through_live wm alphas ml nodes new ln) acts sa la
       (\t, et, e => iret_7_7__through_disjoint alphas nodes front new disj t et (fst (iret_7_7__consistent_through alphas front nodes acts cons t) e)))

--@derives [LDET.5.5]
--@derives [IRET.7.8]
||| LEFT-RETRACTION KEEPS THE ORDER.
export
iret_7_8__unwave_ordered : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                           Ldet_5_5__ordered_acts wm acts -> Ldet_5_5__ordered_acts wm (snd (iret_7_8__unwave alphas nodes gone acts))
iret_7_8__unwave_ordered wm alphas nodes gone acts (sa, la) =
  replace {p = \x => Ldet_5_5__ordered_acts wm x} (sym (iret_7_8__unwave_snd alphas nodes gone acts))
    (iret_8_1__end_sorted wm _ acts sa, iret_8_1__end_live wm _ acts la)

--@derives [LDET.5.5]
||| A stored token is live: its node's left memory is the live front.
export
ldet_5_5__lmem_live : (wm : Rarc_5_6_4__wm) -> (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front -> All (Ldet_5_5__live wm) front ->
                      (t : Iret_7_1__token) -> Elem t lm -> Ldet_5_5__live wm t
ldet_5_5__lmem_live wm lm front sl lf t e = lcyc_1_1__all_lookup lf (fst (sl t) e)

--@derives [LDET.5.5]
--@derives [IRET.7.7]
--@derives [IRET.7.9.2]
||| RIGHT-ACTIVATION KEEPS THE ORDER: at a positive node the extensions
||| by the new fact take their places; at a NOT node the newly blocked
||| leave.
export
iret_7_7__right_activate_ordered : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas' ->
                                   Iret_6_5__mems_live wm alphas -> Iret_6_5__mems_live wm alphas' ->
                                   (a : Nat) -> (f : Lfac_1_7_1__fact) ->
                                   ((i : Nat) -> Not (i = a) -> iret_6_6__mem_at alphas' i = iret_6_6__mem_at alphas i) ->
                                   iret_6_6__mem_at alphas' a = iret_6_6__mem_at alphas a ++ [f] -> Not (Elem f (iret_6_6__mem_at alphas a)) -> Elem f wm ->
                                   (front : List Iret_7_1__token) -> All (Ldet_5_5__live wm) front -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                   Iret_7_7__consistent alphas front nodes acts -> Ldet_5_5__ordered_acts wm acts ->
                                   Ldet_5_5__ordered_acts wm (snd (iret_7_7__right_activate wm alphas' a f nodes acts))
iret_7_7__right_activate_ordered wm dw alphas alphas' dm ml ml' a f frame delta nf ef front lf [] acts c oa = oa
iret_7_7__right_activate_ordered wm dw alphas alphas' dm ml ml' a f frame delta nf ef front lf (b :: rest) acts (sl, dl, cnt, rec) oa with (balpha b == a) proof ba
  iret_7_7__right_activate_ordered wm dw alphas alphas' dm ml ml' a f frame delta nf ef front lf (b :: rest) acts (sl, dl, cnt, rec) oa | True with (bneg b) proof bn
    iret_7_7__right_activate_ordered wm dw alphas alphas' dm ml ml' a f frame delta nf ef front lf (b :: rest) acts (sl, dl, cnt, rec) oa | True | True =
      iret_7_8__unwave_ordered wm alphas' _ _ _
        (iret_7_7__right_activate_ordered wm dw alphas alphas' dm ml ml' a f frame delta nf ef
           (iret_7_9_1__pass (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)
           (iret_7_7__next_live wm True (bjoin b) (iret_6_6__mem_at alphas (balpha b)) (\g, e => ml (balpha b) g e) front lf)
           rest acts rec oa)
    iret_7_7__right_activate_ordered wm dw alphas alphas' dm ml ml' a f frame delta nf ef front lf (b :: rest) acts (sl, dl, cnt, rec) oa | True | False =
      let memEq : (iret_6_6__mem_at alphas' (balpha b) = iret_6_6__mem_at alphas (balpha b) ++ [f])
          memEq = replace {p = \i => iret_6_6__mem_at alphas' i = iret_6_6__mem_at alphas i ++ [f]} (sym (lcyc_1_1__nat_eq_true (balpha b) a ba)) delta
          nf' : Not (Elem f (iret_6_6__mem_at alphas (balpha b)))
          nf' = replace {p = \i => Not (Elem f (iret_6_6__mem_at alphas i))} (sym (lcyc_1_1__nat_eq_true (balpha b) a ba)) nf
          front' : List Iret_7_1__token
          front' = iret_7_7__extend_front (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front
          lf' : All (Ldet_5_5__live wm) front'
          lf' = iret_7_7__next_live wm False (bjoin b) (iret_6_6__mem_at alphas (balpha b)) (\g, e => ml (balpha b) g e) front lf
          hit : List Iret_7_1__token
          hit = filter (\u => bjoin b u f) (blmem b)
          ih = iret_7_7__right_activate_ordered wm dw alphas alphas' dm ml ml' a f frame delta nf ef front' lf' rest acts rec oa
          consR = iret_7_7__right_activate_consistent wm alphas alphas' dm a f frame delta nf front' rest acts rec
      in iret_7_7__wave_ordered wm dw alphas' dm ml' front' (map (\t => t ++ [f]) hit) _ _ consR
           (iret_11_3__distinct_map_inj (\t => t ++ [f]) (\t, u, eq => fst (iret_7_2__snoc_inj t u f f eq)) hit (iret_11_3__distinct_filter _ (blmem b) dl))
           (lcyc_1_1__all_from_elem (map (\t => t ++ [f]) hit) (\y, ey =>
              let (t ** (et, eq)) = iret_7_2__map_snoc_inv f hit y ey
                  (el, _) = lcyc_1_1__elem_filter_inv (\u => bjoin b u f) (blmem b) et
              in replace {p = \z => Ldet_5_5__live wm z} (sym eq) (lcyc_1_1__all_append (ldet_5_5__lmem_live wm (blmem b) front sl lf t el) [ef])))
           (iret_7_7__extend_new_disjoint (bjoin b) (iret_6_6__mem_at alphas (balpha b)) f nf' hit front)
           ih
  iret_7_7__right_activate_ordered wm dw alphas alphas' dm ml ml' a f frame delta nf ef front lf (b :: rest) acts (sl, dl, cnt, rec) oa | False =
    iret_7_7__right_activate_ordered wm dw alphas alphas' dm ml ml' a f frame delta nf ef
      (iret_7_7__next_of (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)
      (iret_7_7__next_live wm (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) (\g, e => ml (balpha b) g e) front lf)
      rest acts rec oa

--@derives [LDET.5.9]
--@derives [IRET.7.7]
--@derives [IRET.7.9.3]
||| RIGHT-RETRACTION KEEPS THE ORDER: at a positive node the extensions
||| by the fact leave; at a NOT node the released take the places their
||| keys give them — the order is stamped against the working memory the
||| retraction found.
export
iret_7_7__right_retract_ordered : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (alphas, alphas' : List Iret_6_1__alpha) ->
                                  Iret_6_5__distinct_mems alphas -> Iret_6_5__distinct_mems alphas' ->
                                  Iret_6_5__mems_live wm alphas -> Iret_6_5__mems_live wm alphas' ->
                                  (a : Nat) -> (f : Lfac_1_7_1__fact) ->
                                  ((i : Nat) -> Not (i = a) -> iret_6_6__mem_at alphas' i = iret_6_6__mem_at alphas i) ->
                                  iret_6_6__mem_at alphas' a = rarc_5_6_4__remove_exact f (iret_6_6__mem_at alphas a) -> Elem f (iret_6_6__mem_at alphas a) ->
                                  (front : List Iret_7_1__token) -> All (Ldet_5_5__live wm) front -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                  Iret_7_7__consistent alphas front nodes acts -> Ldet_5_5__ordered_acts wm acts ->
                                  Ldet_5_5__ordered_acts wm (snd (iret_7_7__right_retract wm alphas' a f nodes acts))
iret_7_7__right_retract_ordered wm dw alphas alphas' dm0 dm ml ml' a f frame delta ef front lf [] acts c oa = oa
iret_7_7__right_retract_ordered wm dw alphas alphas' dm0 dm ml ml' a f frame delta ef front lf (b :: rest) acts (sl, dl, cnt, rec) oa with (balpha b == a) proof ba
  iret_7_7__right_retract_ordered wm dw alphas alphas' dm0 dm ml ml' a f frame delta ef front lf (b :: rest) acts (sl, dl, cnt, rec) oa | True with (bneg b) proof bn
    iret_7_7__right_retract_ordered wm dw alphas alphas' dm0 dm ml ml' a f frame delta ef front lf (b :: rest) acts (sl, dl, cnt, rec) oa | True | True =
      let front' : List Iret_7_1__token
          front' = iret_7_9_1__pass (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front
          lf' : All (Ldet_5_5__live wm) front'
          lf' = iret_7_7__next_live wm True (bjoin b) (iret_6_6__mem_at alphas (balpha b)) (\g, e => ml (balpha b) g e) front lf
          released : List Iret_7_1__token
          released = filter (\u => iret_7_9_4__count u (bcounts b) == 1) (filter (\u => bjoin b u f) (blmem b))
          ih = iret_7_7__right_retract_ordered wm dw alphas alphas' dm0 dm ml ml' a f frame delta ef front' lf' rest acts rec oa
          consR = iret_7_7__right_retract_consistent wm alphas alphas' dm0 dm a f frame delta ef front' rest acts rec
      in iret_7_7__wave_ordered wm dw alphas' dm ml' front' released _ _ consR
           (iret_11_3__distinct_filter _ _ (iret_11_3__distinct_filter _ (blmem b) dl))
           (lcyc_1_1__all_from_elem released (\t, et =>
              ldet_5_5__lmem_live wm (blmem b) front sl lf t (fst (lcyc_1_1__elem_filter_inv (\u => bjoin b u f) (blmem b) (fst (lcyc_1_1__elem_filter_inv (\u => iret_7_9_4__count u (bcounts b) == 1) _ et))))))
           (iret_7_9_3__released_disjoint (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) f (blmem b) front sl (cnt Refl))
           ih
    iret_7_7__right_retract_ordered wm dw alphas alphas' dm0 dm ml ml' a f frame delta ef front lf (b :: rest) acts (sl, dl, cnt, rec) oa | True | False =
      iret_7_8__unwave_ordered wm alphas' _ _ _
        (iret_7_7__right_retract_ordered wm dw alphas alphas' dm0 dm ml ml' a f frame delta ef
           (iret_7_7__extend_front (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)
           (iret_7_7__next_live wm False (bjoin b) (iret_6_6__mem_at alphas (balpha b)) (\g, e => ml (balpha b) g e) front lf)
           rest acts rec oa)
  iret_7_7__right_retract_ordered wm dw alphas alphas' dm0 dm ml ml' a f frame delta ef front lf (b :: rest) acts (sl, dl, cnt, rec) oa | False =
    iret_7_7__right_retract_ordered wm dw alphas alphas' dm0 dm ml ml' a f frame delta ef
      (iret_7_7__next_of (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)
      (iret_7_7__next_live wm (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) (\g, e => ml (balpha b) g e) front lf)
      rest acts rec oa

-- ---------------------------------------------------------------------
-- The order through alpha dispatch
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
||| Every terminal of the network in agenda order, of live activations.
public export
Ldet_5_5__ordered_net : Rarc_5_6_4__wm -> Rarc_5_3_1__network -> Type
Ldet_5_5__ordered_net wm net = All (\c => Ldet_5_5__ordered_acts wm (cacts c)) (nchains net)

--@derives [IRET.6.4]
--@derives [LDET.5.5]
||| ONE ALPHA VISITED ON ASSERT, admitting the fact, keeps the order.
export
iret_6_4__dispatch_assert_ordered_step : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> Not (Elem f wm) -> Iret_11_3__distinct (wm ++ [f]) ->
                                         (i : Nat) -> (is : List Nat) -> Not (Elem i is) -> (alphas : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                         iret_6_4__admits (iret_6_6__alpha_at alphas i) f = True ->
                                         Iret_6_4__dispatch_inv wm (wm ++ [f]) (i :: is) (MkNetwork alphas chains) ->
                                         Ldet_5_5__ordered_net (wm ++ [f]) (MkNetwork alphas chains) ->
                                         Ldet_5_5__ordered_net (wm ++ [f])
                                           (MkNetwork (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas)
                                                      (map (iret_7_7__activate_chain (wm ++ [f]) (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i f) chains))
iret_6_4__dispatch_assert_ordered_step wm f nf dw i is ni alphas chains af inv ord =
  let (dm, pend, done, cons) = inv
      (a ** nt) = iret_6_4__admits_some i alphas f af
      aEq : (iret_6_6__alpha_at alphas i = a)
      aEq = iret_6_6__alpha_at_just i alphas a nt
      aEq' : (iret_6_6__alpha_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i = iret_6_5__insert f a)
      aEq' = iret_6_6__alpha_at_set_eq i (iret_6_5__insert f) alphas a nt
      memI : (iret_6_6__mem_at alphas i = iret_6_5__view a wm)
      memI = replace {p = \x => iret_6_6__mem_at alphas i = iret_6_5__view x wm} aEq (pend i Here)
      delta : (iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i = iret_6_6__mem_at alphas i ++ [f])
      delta = rewrite aEq' in rewrite aEq in Refl
      frame : ((j : Nat) -> Not (j = i) -> iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) j = iret_6_6__mem_at alphas j)
      frame = \j, ne => cong amem (iret_6_6__alpha_at_set_neq i j (\eq => ne (sym eq)) (iret_6_5__insert f) alphas)
      nfI : Not (Elem f (iret_6_6__mem_at alphas i))
      nfI = \e => nf (fst (lcyc_1_1__elem_filter_inv (iret_6_4__admits a) wm (replace {p = \z => Elem f z} memI e)))
      ml : Iret_6_5__mems_live (wm ++ [f]) alphas
      ml = iret_6_4__dispatch_inv_live wm (wm ++ [f]) (wm ++ [f]) (i :: is) (MkNetwork alphas chains) inv (\g, e => lcyc_1_1__elem_append_left e) (\g, e => e)
      ml' : Iret_6_5__mems_live (wm ++ [f]) (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas)
      ml' = \j, g, e => case decEq j i of
              Yes eq => case lcyc_1_1__elem_append_inv (iret_6_6__mem_at alphas i)
                               (replace {p = \z => Elem g z} (trans (cong (iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas)) eq) delta) e) of
                          Left l  => ml i g l
                          Right r => replace {p = \z => Elem z (wm ++ [f])} (sym (iret_12__elem_singleton r)) (lcyc_1_1__elem_append_right wm Here)
              No ne  => ml j g (replace {p = \z => Elem g z} (frame j ne) e)
      dm' : Iret_6_5__distinct_mems (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas)
      dm' = fst (iret_6_4__dispatch_assert_hit wm f nf dw i is ni alphas chains af inv)
  in lcyc_1_1__all_map (iret_7_7__activate_chain (wm ++ [f]) (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i f)
       (lcyc_1_1__all_from_elem chains (\c, ec =>
          iret_7_7__right_activate_ordered (wm ++ [f]) dw alphas (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) dm' ml ml' i f frame delta nfI
            (lcyc_1_1__elem_append_right wm Here) [[]] [[]] (cnodes c) (cacts c) (lcyc_1_1__all_lookup cons ec) (lcyc_1_1__all_lookup ord ec)))

--@derives [IRET.6.4]
--@derives [LDET.5.5]
||| ALPHA DISPATCH ON ASSERT keeps the order.
export
iret_6_4__dispatch_assert_ordered : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> Not (Elem f wm) -> Iret_11_3__distinct (wm ++ [f]) ->
                                    (is : List Nat) -> Iret_11_3__distinct is -> (net : Rarc_5_3_1__network) ->
                                    Iret_6_4__dispatch_inv wm (wm ++ [f]) is net -> Ldet_5_5__ordered_net (wm ++ [f]) net ->
                                    Ldet_5_5__ordered_net (wm ++ [f]) (iret_6_4__dispatch_assert (wm ++ [f]) f is net)
iret_6_4__dispatch_assert_ordered wm f nf dw [] DNil net inv ord = ord
iret_6_4__dispatch_assert_ordered wm f nf dw (i :: is) (DCons ni d) (MkNetwork alphas chains) inv ord with (iret_6_4__admits (iret_6_6__alpha_at alphas i) f) proof af
  iret_6_4__dispatch_assert_ordered wm f nf dw (i :: is) (DCons ni d) (MkNetwork alphas chains) inv ord | True =
    iret_6_4__dispatch_assert_ordered wm f nf dw is d
      (MkNetwork (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) (map (iret_7_7__activate_chain (wm ++ [f]) (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i f) chains))
      (iret_6_4__dispatch_assert_hit wm f nf dw i is ni alphas chains af inv)
      (iret_6_4__dispatch_assert_ordered_step wm f nf dw i is ni alphas chains af inv ord)
  iret_6_4__dispatch_assert_ordered wm f nf dw (i :: is) (DCons ni d) (MkNetwork alphas chains) inv ord | False =
    iret_6_4__dispatch_assert_ordered wm f nf dw is d (MkNetwork alphas chains) (iret_6_4__dispatch_assert_miss wm f i is ni alphas chains af inv) ord

--@derives [IRET.19.2]
--@derives [LDET.5.9]
||| ONE ALPHA VISITED ON RETRACT, admitting the fact, keeps the order
||| under the working memory the retraction found.
export
iret_19_2__dispatch_retract_ordered_step : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                                           (i : Nat) -> (is : List Nat) -> Not (Elem i is) -> (alphas : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                           iret_6_4__admits (iret_6_6__alpha_at alphas i) f = True ->
                                           Iret_6_4__dispatch_inv wm (rarc_5_6_4__remove_exact f wm) (i :: is) (MkNetwork alphas chains) ->
                                           Ldet_5_5__ordered_net wm (MkNetwork alphas chains) ->
                                           Ldet_5_5__ordered_net wm
                                             (MkNetwork (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas)
                                                        (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i f) chains))
iret_19_2__dispatch_retract_ordered_step wm dw f ef i is ni alphas chains af inv ord =
  let (dm, pend, done, cons) = inv
      (a ** nt) = iret_6_4__admits_some i alphas f af
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
      efI : Elem f (iret_6_6__mem_at alphas i)
      efI = replace {p = \z => Elem f z} (sym memI) (lcyc_1_1__elem_filter_fwd (iret_6_4__admits a) wm ef admA)
      ml : Iret_6_5__mems_live wm alphas
      ml = iret_6_4__dispatch_inv_live wm (rarc_5_6_4__remove_exact f wm) wm (i :: is) (MkNetwork alphas chains) inv
             (\g, e => e) (\g, e => fst (rarc_5_6_4__remove_exact_elem_inv f wm g e))
      ml' : Iret_6_5__mems_live wm (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas)
      ml' = \j, g, e => case decEq j i of
              Yes eq => ml i g (fst (rarc_5_6_4__remove_exact_elem_inv f (iret_6_6__mem_at alphas i) g
                                  (replace {p = \z => Elem g z} (trans (cong (iret_6_6__mem_at (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas)) eq) delta) e)))
              No ne  => ml j g (replace {p = \z => Elem g z} (frame j ne) e)
      dm' : Iret_6_5__distinct_mems (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas)
      dm' = fst (iret_19_2__dispatch_retract_hit wm f ef i is ni alphas chains af inv)
  in lcyc_1_1__all_map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i f)
       (lcyc_1_1__all_from_elem chains (\c, ec =>
          iret_7_7__right_retract_ordered wm dw alphas (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) dm dm' ml ml' i f frame delta efI
            [[]] [[]] (cnodes c) (cacts c) (lcyc_1_1__all_lookup cons ec) (lcyc_1_1__all_lookup ord ec)))

--@derives [IRET.19.2]
--@derives [LDET.5.9]
||| ALPHA DISPATCH ON RETRACT keeps the order under the working memory
||| the retraction found.
export
iret_19_2__dispatch_retract_ordered : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                                      (is : List Nat) -> Iret_11_3__distinct is -> (net : Rarc_5_3_1__network) ->
                                      Iret_6_4__dispatch_inv wm (rarc_5_6_4__remove_exact f wm) is net -> Ldet_5_5__ordered_net wm net ->
                                      Ldet_5_5__ordered_net wm (iret_19_2__dispatch_retract wm f is net)
iret_19_2__dispatch_retract_ordered wm dw f ef [] DNil net inv ord = ord
iret_19_2__dispatch_retract_ordered wm dw f ef (i :: is) (DCons ni d) (MkNetwork alphas chains) inv ord with (iret_6_4__admits (iret_6_6__alpha_at alphas i) f) proof af
  iret_19_2__dispatch_retract_ordered wm dw f ef (i :: is) (DCons ni d) (MkNetwork alphas chains) inv ord | True =
    iret_19_2__dispatch_retract_ordered wm dw f ef is d
      (MkNetwork (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i f) chains))
      (iret_19_2__dispatch_retract_hit wm f ef i is ni alphas chains af inv)
      (iret_19_2__dispatch_retract_ordered_step wm dw f ef i is ni alphas chains af inv ord)
  iret_19_2__dispatch_retract_ordered wm dw f ef (i :: is) (DCons ni d) (MkNetwork alphas chains) inv ord | False =
    iret_19_2__dispatch_retract_ordered wm dw f ef is d (MkNetwork alphas chains) (iret_19_2__dispatch_retract_miss wm f i is ni alphas chains af inv) ord

-- ---------------------------------------------------------------------
-- The order through every engine operation
-- ---------------------------------------------------------------------

--@derives [LDET.5.9]
--@derives [LDET.5.5]
--@derives [IRET.1.9]
||| THE ORDERED VIEW: the view, and every terminal in agenda order.
public export
Ldet_5_9__ordered : Iret_19__engine -> Type
Ldet_5_9__ordered eng = (Iret_19__view eng, Ldet_5_5__ordered_net (ewm eng) (enet eng))

--@derives [LDET.5.5]
||| Under the view every activation is live: its tuple is in the
||| recompute, which is built from the memories, which show working
||| memory.
export
ldet_5_5__view_live_acts : (eng : Iret_19__engine) -> Iret_19__view eng -> All (\c => Ldet_5_5__live_acts (ewm eng) (cacts c)) (nchains (enet eng))
ldet_5_5__view_live_acts (MkEngine wm (MkNetwork alphas chains)) (dw, dm, mv, cons) =
  lcyc_1_1__all_from_elem chains (\c, ec =>
    let k = lcyc_1_1__all_lookup cons ec
        ml : Iret_6_5__mems_live wm alphas
        ml = \i, g, e => iret_6_5__view_live wm wm (\_, x => x) (iret_6_6__alpha_at alphas i) g (replace {p = \z => Elem g z} (mv i) e)
        thr = iret_7_7__through_live wm alphas ml (cnodes c) [[]] [[]]
    in lcyc_1_1__all_from_elem (cacts c) (\a, ea =>
         lcyc_1_1__all_lookup thr (fst (iret_7_7__consistent_through alphas [[]] (cnodes c) (cacts c) k (atuple a)) (lcyc_1_1__elem_map_fwd atuple ea))))

--@derives [IRET.19.1]
--@derives [LDET.5.5]
||| INSERTING A FRESH FACT keeps the order: the survivors' order is the
||| same under the grown working memory, and the new matches take their
||| places.
export
iret_19_1__insert_ordered : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Not (Elem f (ewm eng)) ->
                            Ldet_5_9__ordered eng -> Ldet_5_9__ordered (iret_19_1__insert f eng)
iret_19_1__insert_ordered f (MkEngine wm net) nf (v, ord) =
  let (dw, dm, mv, cons) = v
      v' = iret_19_1__insert_view f (MkEngine wm net) nf v
      (dw', _, _, _) = v'
      ord' : Ldet_5_5__ordered_net (wm ++ [f]) net
      ord' = lcyc_1_1__all_imp (nchains net) (\c, (sa, la) =>
               ( ldet_5_5__sorted_append wm f (cacts c) la sa
               , lcyc_1_1__all_imp (cacts c) (\a, l => lcyc_1_1__all_imp (atuple a) (\g, eg => lcyc_1_1__elem_append_left eg) l) la )) ord
  in (v', iret_6_4__dispatch_assert_ordered wm f nf dw' (iret_1_7__indices (length (nalphas net))) (iret_1_7__indices_distinct (length (nalphas net))) net
            (iret_1_7__dispatch_start wm (wm ++ [f]) net dm mv cons) ord')

--@derives [IRET.19.2]
--@derives [LDET.5.9]
||| RETRACTING A LIVE FACT keeps the order: the dispatch stamps against
||| the working memory it found, and the survivors, live without the
||| fact, keep their order under the shrunk one.
export
iret_19_2__retract_ordered : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Elem f (ewm eng) ->
                             Ldet_5_9__ordered eng -> Ldet_5_9__ordered (iret_19_2__retract f eng)
iret_19_2__retract_ordered f (MkEngine wm net) ef (v, ord) =
  let (dw, dm, mv, cons) = v
      v' = iret_19_2__retract_view f (MkEngine wm net) ef v
      ordOld = iret_19_2__dispatch_retract_ordered wm dw f ef (iret_1_7__indices (length (nalphas net))) (iret_1_7__indices_distinct (length (nalphas net))) net
                 (iret_1_7__dispatch_start wm (rarc_5_6_4__remove_exact f wm) net dm mv cons) ord
      liveNew = ldet_5_5__view_live_acts (iret_19_2__retract f (MkEngine wm net)) v'
  in (v', lcyc_1_1__all_from_elem _ (\c, ec =>
        let (sa, _) = lcyc_1_1__all_lookup ordOld ec
            lv' = lcyc_1_1__all_lookup liveNew ec
            lvOld : Ldet_5_5__live_acts wm (cacts c)
            lvOld = lcyc_1_1__all_imp (cacts c) (\a, la => lcyc_1_1__all_imp (atuple a) (\g, eg => fst (rarc_5_6_4__remove_exact_elem_inv f wm g eg)) la) lv'
            nfs : All (\a => Not (Elem f (atuple a))) (cacts c)
            nfs = lcyc_1_1__all_imp (cacts c) (\a, la => \e => snd (rarc_5_6_4__remove_exact_elem_inv f wm f (lcyc_1_1__all_lookup la e)) Refl) lv'
        in (ldet_5_9__sorted_remove wm dw f ef (cacts c) lvOld nfs sa, lv')))

--@derives [IRET.19.1]
--@derives [LFAC.2.5.1]
--@derives [LFAC.2.5.3]
||| ASSERT UNDER THE LIFECYCLE keeps the order.
export
iret_19_1__assert_ordered : (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) ->
                            Ldet_5_9__ordered eng -> Ldet_5_9__ordered (iret_19_1__assert life avoid k key pay eng)
iret_19_1__assert_ordered life avoid k key pay eng o with (life k)
  iret_19_1__assert_ordered life avoid k key pay eng o | Explicit =
    iret_19_1__insert_ordered _ eng (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) o
  iret_19_1__assert_ordered life avoid k key pay eng o | Relation with (iret_19_1__find_relation k key pay (ewm eng))
    iret_19_1__assert_ordered life avoid k key pay eng o | Relation | (Just old) = o
    iret_19_1__assert_ordered life avoid k key pay eng o | Relation | Nothing =
      iret_19_1__insert_ordered _ eng (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) o
  iret_19_1__assert_ordered life avoid k key pay eng o | Entity with (iret_19_1__find_entity k key (ewm eng)) proof fe
    iret_19_1__assert_ordered life avoid k key pay eng o | Entity | Nothing =
      iret_19_1__insert_ordered _ eng (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) o
    iret_19_1__assert_ordered life avoid k key pay eng o | Entity | (Just old) with (fpay old == pay)
      iret_19_1__assert_ordered life avoid k key pay eng o | Entity | (Just old) | True = o
      iret_19_1__assert_ordered life avoid k key pay eng o | Entity | (Just old) | False =
        iret_19_1__insert_ordered _ (iret_19_2__retract old eng)
          (\e => lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay (fst (rarc_5_6_4__remove_exact_elem_inv old (ewm eng) _ e)))
          (iret_19_2__retract_ordered old eng (snd (lcyc_1_1__find_just _ (ewm eng) fe)) o)

--@derives [LSCP.2.1.1]
||| WITHDRAW keeps the order.
export
lscp_2_1_1__withdraw_ordered : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Ldet_5_9__ordered eng -> Ldet_5_9__ordered (lscp_2_1_1__withdraw f eng)
lscp_2_1_1__withdraw_ordered f eng o with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng)) proof an
  lscp_2_1_1__withdraw_ordered f eng o | True = iret_19_2__retract_ordered f eng (lscp_2_1_1__any_same_elem f (ewm eng) an) o
  lscp_2_1_1__withdraw_ordered f eng o | False = o

--@derives [IDAT.6.2.2]
--@derives [LDET.5.3]
export
idat_6_2_2__mark_chain_ordered : (wm : Rarc_5_6_4__wm) -> (j : Nat) -> (c : Rlow_4_2_1__chain) ->
                                 Ldet_5_5__ordered_acts wm (cacts c) -> Ldet_5_5__ordered_acts wm (cacts (idat_6_2_2__mark_chain j c))
idat_6_2_2__mark_chain_ordered wm j (MkChain nodes acts actions) (sa, la) = (idat_6_2_2__mark_sorted wm j acts sa, idat_6_2_2__mark_live wm j acts la)

--@derives [IDAT.6.2.2]
--@derives [LDET.5.3]
||| SETTING `fired` keeps the order: refraction is suppression, never a
||| key.
export
idat_6_2_2__mark_net_ordered : (r, j : Nat) -> (eng : Iret_19__engine) -> Ldet_5_9__ordered eng -> Ldet_5_9__ordered (idat_6_2_2__mark_net r j eng)
idat_6_2_2__mark_net_ordered r j (MkEngine wm (MkNetwork alphas chains)) (v, ord) =
  (idat_6_2_2__mark_net_view r j (MkEngine wm (MkNetwork alphas chains)) v,
   lcyc_1_1__all_set_at (idat_6_2_2__mark_chain j) (\c, oc => idat_6_2_2__mark_chain_ordered wm j c oc) r chains ord)

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_action_net_ordered : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                                    Ldet_5_9__ordered eng -> Ldet_5_9__ordered (rarc_5_6_7__do_action_net life bound a eng)
rarc_5_6_7__do_action_net_ordered life bound (Emit k value) eng o =
  iret_19_1__assert_ordered life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) eng o
rarc_5_6_7__do_action_net_ordered life bound (Withdraw i) eng o with (rarc_5_6_5__nth i bound)
  rarc_5_6_7__do_action_net_ordered life bound (Withdraw i) eng o | Nothing = o
  rarc_5_6_7__do_action_net_ordered life bound (Withdraw i) eng o | (Just f) = lscp_2_1_1__withdraw_ordered f eng o

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_actions_net_ordered : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (as : List Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                                     Ldet_5_9__ordered eng -> Ldet_5_9__ordered (rarc_5_6_7__do_actions_net life bound as eng)
rarc_5_6_7__do_actions_net_ordered life bound [] eng o = o
rarc_5_6_7__do_actions_net_ordered life bound (a :: as) eng o =
  rarc_5_6_7__do_actions_net_ordered life bound as (rarc_5_6_7__do_action_net life bound a eng) (rarc_5_6_7__do_action_net_ordered life bound a eng o)

--@derives [IRET.11.4]
export
iret_11_4__step_net_ordered : (life : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) -> Ldet_5_9__ordered eng ->
                              (eng' : Iret_19__engine) -> iret_11_4__step_net life eng = Just eng' -> Ldet_5_9__ordered eng'
iret_11_4__step_net_ordered life eng o eng' eq with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__step_net_ordered life eng o eng' eq | Nothing = void (absurd eq)
  iret_11_4__step_net_ordered life eng o eng' eq | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng)))
    iret_11_4__step_net_ordered life eng o eng' eq | (Just (r, j)) | Nothing = void (absurd eq)
    iret_11_4__step_net_ordered life eng o eng' eq | (Just (r, j)) | (Just c) with (rarc_5_6_5__nth j (cacts c))
      iret_11_4__step_net_ordered life eng o eng' eq | (Just (r, j)) | (Just c) | Nothing = void (absurd eq)
      iret_11_4__step_net_ordered life eng o eng' eq | (Just (r, j)) | (Just c) | (Just a) =
        replace {p = Ldet_5_9__ordered} (iret_11_4__just_inj eq)
          (rarc_5_6_7__do_actions_net_ordered life (atuple a) (cactions c) (idat_6_2_2__mark_net r j eng) (idat_6_2_2__mark_net_ordered r j eng o))

--@derives [IRET.11.4]
--@derives [IRET.11.5]
export
iret_11_4__run_net_ordered : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) -> Ldet_5_9__ordered eng ->
                             Ldet_5_9__ordered (fst (iret_11_4__run_net life fuel eng))
iret_11_4__run_net_ordered life Z eng o = o
iret_11_4__run_net_ordered life (S fuel) eng o with (iret_11_4__step_net life eng) proof st
  iret_11_4__run_net_ordered life (S fuel) eng o | Nothing = o
  iret_11_4__run_net_ordered life (S fuel) eng o | (Just eng') with (iret_11_4__run_net life fuel eng') proof rr
    iret_11_4__run_net_ordered life (S fuel) eng o | (Just eng') | (e, h, n) =
      replace {p = \x => Ldet_5_9__ordered (fst x)} rr (iret_11_4__run_net_ordered life fuel eng' (iret_11_4__step_net_ordered life eng o eng' st))

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_net_ordered : (life : Nat -> Lscp_1_3__lifecycle) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                                Ldet_5_9__ordered eng -> Ldet_5_9__ordered (rarc_5_6_4__apply_net life ev eng)
rarc_5_6_4__apply_net_ordered life (Assert k key pay) eng o = iret_19_1__assert_ordered life [] k key pay eng o
rarc_5_6_4__apply_net_ordered life (Retract i) eng o with (rarc_5_6_4__lookup_fact i (ewm eng)) proof lk
  rarc_5_6_4__apply_net_ordered life (Retract i) eng o | Nothing = o
  rarc_5_6_4__apply_net_ordered life (Retract i) eng o | (Just f) = iret_19_2__retract_ordered f eng (fst (rarc_5_6_4__lookup_elem i (ewm eng) f lk)) o

--@derives [LFST.9.2.1]
export
lfst_9_2_1__boundary_net_ordered : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                                   Ldet_5_9__ordered eng -> Ldet_5_9__ordered (lfst_9_2_1__boundary_net life fuel ev eng)
lfst_9_2_1__boundary_net_ordered life fuel ev eng o = iret_11_4__run_net_ordered life fuel _ (rarc_5_6_4__apply_net_ordered life ev eng o)

--@derives [LFST.9.2.1]
||| EVERY HISTORY keeps the order.
export
lfst_9_2_1__replay_net_ordered : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                               Ldet_5_9__ordered eng -> Ldet_5_9__ordered (lfst_9_2_1__replay_net life fuel evs eng)
lfst_9_2_1__replay_net_ordered life fuel [] eng o = o
lfst_9_2_1__replay_net_ordered life fuel (ev :: evs) eng o =
  lfst_9_2_1__replay_net_ordered life fuel evs _ (lfst_9_2_1__boundary_net_ordered life fuel ev eng o)

--@derives [RDSC.4a.5]
||| SEEDING keeps the order: the nil token's wave over the loaded chain
||| from an empty terminal.
export
rdsc_4a_5__seed_ordered : (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas -> Iret_6_5__mems_live [] alphas ->
                          (r : (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                          Ldet_5_5__ordered_acts [] (cacts (rdsc_4a_5__seed alphas (iret_16_6__terminal r)))
rdsc_4a_5__seed_ordered alphas dm ml (nodes, actions) =
  iret_7_7__wave_ordered [] DNil alphas dm ml [] [[]] (iret_16_5__beta_nodes nodes) []
    (iret_16_5__empty_consistent alphas nodes) (DCons (\e => absurd e) DNil) [[]] (\t, _, e => absurd e) (SNil, [])

--@derives [RDSC.4a.5]
--@derives [IRET.18.2]
||| THE LOADED NETWORK IS ORDERED.
export
rdsc_4a_5__load_ordered : (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                          Ldet_5_9__ordered (rdsc_4a_5__load alphas rules)
rdsc_4a_5__load_ordered alphas rules =
  let dm : Iret_6_5__distinct_mems (iret_16_4__alpha_nodes alphas)
      dm = \i => replace {p = \z => Iret_11_3__distinct z} (sym (iret_16_4__mem_empty alphas i)) DNil
      ml : Iret_6_5__mems_live [] (iret_16_4__alpha_nodes alphas)
      ml = \i, g, e => absurd (replace {p = \z => Elem g z} (iret_16_4__mem_empty alphas i) e)
  in ( rdsc_4a_5__load_view alphas rules
     , lcyc_1_1__all_map (rdsc_4a_5__seed (iret_16_4__alpha_nodes alphas))
         (lcyc_1_1__all_map iret_16_6__terminal
            (lcyc_1_1__all_from_elem rules (\r, _ => rdsc_4a_5__seed_ordered (iret_16_4__alpha_nodes alphas) dm ml r))) )

-- ---------------------------------------------------------------------
-- THE ORDER THEOREM, closed at the top
-- ---------------------------------------------------------------------

--@derives [LDET.5.9]
||| TWO SORTED TERMINALS WITH THE SAME ACTIVATIONS ARE THE SAME LIST: the
||| order is a function of the activation set.
export
ldet_5_9__sorted_unique : (wm : Rarc_5_6_4__wm) -> (acts1, acts2 : List Iret_8_1__act) ->
                          Ldet_5_5__sorted wm acts1 -> Ldet_5_5__sorted wm acts2 ->
                          Iret_11_3__distinct (iret_8_1__tuples acts1) -> Iret_11_3__distinct (iret_8_1__tuples acts2) ->
                          Iret_7_4__same_set (iret_8_1__tuples acts1) (iret_8_1__tuples acts2) -> iret_8_1__tuples acts1 = iret_8_1__tuples acts2
ldet_5_9__sorted_unique wm [] [] _ _ _ _ _ = Refl
ldet_5_9__sorted_unique wm [] (b :: bs) _ _ _ _ ss = absurd (snd (ss (atuple b)) Here)
ldet_5_9__sorted_unique wm (a :: as) [] _ _ _ _ ss = absurd (fst (ss (atuple a)) Here)
ldet_5_9__sorted_unique wm (a :: as) (b :: bs) (SCons aa sa) (SCons bb sb) (DCons na da) (DCons nb db) ss =
  let beforeOf : (acts : List Iret_8_1__act) -> (h, t : Iret_7_1__token) -> All (\x => ldet_5_5__before wm h (atuple x) = True) acts ->
                 Elem t (iret_8_1__tuples acts) -> ldet_5_5__before wm h t = True
      beforeOf acts h t al et = let (x ** (ex, eq)) = lcyc_1_1__elem_map_inv atuple acts et
                                in replace {p = \z => ldet_5_5__before wm h z = True} eq (lcyc_1_1__all_lookup al ex)
      ab : (atuple a = atuple b)
      ab = case iret_11_3__elem_cons (fst (ss (atuple a)) Here) of
             Left e => e
             Right ea => case iret_11_3__elem_cons (snd (ss (atuple b)) Here) of
               Left e => sym e
               Right eb => absurd (trans (sym (ldet_5_5__before_asym wm (atuple a) (atuple b) (beforeOf as (atuple a) (atuple b) aa eb)))
                                         (beforeOf bs (atuple b) (atuple a) bb ea))
      tails : Iret_7_4__same_set (iret_8_1__tuples as) (iret_8_1__tuples bs)
      tails = \t => ( \e => case iret_11_3__elem_cons (fst (ss t) (There e)) of
                              Left eq => absurd (na (replace {p = \z => Elem z (iret_8_1__tuples as)} (trans eq (sym ab)) e))
                              Right r => r
                    , \e => case iret_11_3__elem_cons (snd (ss t) (There e)) of
                              Left eq => absurd (nb (replace {p = \z => Elem z (iret_8_1__tuples bs)} (trans eq ab) e))
                              Right r => r )
  in cong2 (::) ab (ldet_5_9__sorted_unique wm as bs sa sb da db tails)

--@derives [LDET.5.5]
||| THE CANONICAL ORDER of a set of matches: each at its key's place,
||| from nothing. A function of the matches and of working memory alone.
public export
ldet_5_5__canonical : Rarc_5_6_4__wm -> List Iret_7_1__token -> List Iret_7_1__token
ldet_5_5__canonical wm ts = iret_8_1__tuples (iret_8_1__activate wm ts [])

--@derives [RARC.5.6.5]
export
rarc_5_6_5__view_distinct : (alphas : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (nodes : List Iret_7_4__beta) ->
                          (front : List Iret_7_1__token) -> Iret_11_3__distinct front -> Iret_11_3__distinct (iret_7_7__view alphas wm nodes front)
rarc_5_6_5__view_distinct alphas wm dw [] front df = df
rarc_5_6_5__view_distinct alphas wm dw (b :: rest) front df =
  rarc_5_6_5__view_distinct alphas wm dw rest _
    (iret_7_7__next_distinct (bneg b) (bjoin b) (iret_6_5__view (iret_6_6__alpha_at alphas (balpha b)) wm) (iret_11_3__distinct_filter _ wm dw) front df)

--@derives [RARC.5.6.5]
export
rarc_5_6_5__view_live : (alphas : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (nodes : List Iret_7_4__beta) ->
                      (front : List Iret_7_1__token) -> All (Ldet_5_5__live wm) front -> All (Ldet_5_5__live wm) (iret_7_7__view alphas wm nodes front)
rarc_5_6_5__view_live alphas wm [] front lv = lv
rarc_5_6_5__view_live alphas wm (b :: rest) front lv =
  rarc_5_6_5__view_live alphas wm rest _
    (iret_7_7__next_live wm (bneg b) (bjoin b) (iret_6_5__view (iret_6_6__alpha_at alphas (balpha b)) wm)
       (\g, e => fst (lcyc_1_1__elem_filter_inv (iret_6_4__admits (iret_6_6__alpha_at alphas (balpha b))) wm e)) front lv)

--@derives [LDET.5.9]
--@derives [LDET.5.5]
--@derives [IRET.11.3.3]
--@derives [LTES.12.9]
||| UNDER THE ORDERED VIEW, every terminal is the canonical order of its
||| chain's recompute over working memory: the agenda order is a function
||| of the activation set and of working memory, never of how the set was
||| reached — batched equals incremental in order, and a released match
||| fires where it first completed.
export
ldet_5_9__ordered_recompute : (eng : Iret_19__engine) -> Ldet_5_9__ordered eng -> (c : Rlow_4_2_1__chain) -> Elem c (nchains (enet eng)) ->
                              iret_8_1__tuples (cacts c) = ldet_5_5__canonical (ewm eng) (iret_7_7__view (nalphas (enet eng)) (ewm eng) (cnodes c) [[]])
ldet_5_9__ordered_recompute (MkEngine wm (MkNetwork alphas chains)) (v, ord) c ec =
  let (dw, dm, mv, cons) = v
      (sa, la) = lcyc_1_1__all_lookup ord ec
      (ssv, dt) = snd (rarc_5_6_5__view_recomputed (MkEngine wm (MkNetwork alphas chains)) v) c ec
      dv = rarc_5_6_5__view_distinct alphas wm dw (cnodes c) [[]] (DCons (\e => absurd e) DNil)
      lv = rarc_5_6_5__view_live alphas wm (cnodes c) [[]] [[]]
      canon = iret_8_1__activate_sorted wm dw (iret_7_7__view alphas wm (cnodes c) [[]]) dv lv [] SNil [] (\t, _, e => absurd e)
  in ldet_5_9__sorted_unique wm (cacts c) (iret_8_1__activate wm (iret_7_7__view alphas wm (cnodes c) [[]]) []) sa (fst canon) dt
       (iret_8_1__activate_distinct wm _ [] DNil dv (\t, _, e => absurd e))
       (iret_7_4__same_set_trans _ _ _ ssv (iret_7_4__same_set_sym _ _ (iret_8_1__activate_same_set wm _ [] [] (iret_7_4__same_set_refl []))))

--@derives [LDET.5.9]
--@derives [LDET.5.5]
--@derives [IRET.11.3.3]
||| THE ORDER THEOREM. After any history from a loaded network, every
||| terminal's activations are, in order, the canonical order over
||| working memory of the chain's recompute.
export
ldet_5_9__order_after_history : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                (c : Rlow_4_2_1__chain) -> Elem c (nchains (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) ->
                                iret_8_1__tuples (cacts c)
                                  = ldet_5_5__canonical (ewm (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))
                                      (iret_7_7__view (nalphas (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules))))
                                                      (ewm (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules))) (cnodes c) [[]])
ldet_5_9__order_after_history life fuel evs alphas rules c ec =
  ldet_5_9__ordered_recompute _ (lfst_9_2_1__replay_net_ordered life fuel evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_ordered alphas rules)) c ec

--@derives [RARC.5.4.9]
--@derives [IRET.11.1]
||| NO TWO ACTIVATIONS OF ONE RULE SHARE A TIMETAG: distinct live matches
||| have distinct keys.
export
rarc_5_4_9__keys_distinct : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (acts : List Iret_8_1__act) -> Ldet_5_5__live_acts wm acts ->
                            Iret_11_3__distinct (iret_8_1__tuples acts) -> Iret_11_3__distinct (map (ldet_5_5__key wm) (iret_8_1__tuples acts))
rarc_5_4_9__keys_distinct wm dw [] [] DNil = DNil
rarc_5_4_9__keys_distinct wm dw (a :: as) (la :: las) (DCons na da) =
  DCons (\e => let (u ** (eu, eq)) = lcyc_1_1__elem_map_inv (ldet_5_5__key wm) (iret_8_1__tuples as) e
                   (b ** (eb, ub)) = lcyc_1_1__elem_map_inv atuple as eu
                   lu : Ldet_5_5__live wm u
                   lu = replace {p = \z => Ldet_5_5__live wm z} ub (lcyc_1_1__all_lookup las eb)
               in na (replace {p = \z => Elem z (iret_8_1__tuples as)} (ldet_5_5__key_inj wm dw u (atuple a) lu la eq) eu))
        (rarc_5_4_9__keys_distinct wm dw as las da)

--@derives [RARC.5.4.9]
--@derives [IRET.11.1]
||| After any history from a loaded network, no terminal holds two
||| activations with the same timetag: the duplicate RARC.5.4.9 calls a
||| defect in the runtime cannot occur, so the check it permits a runtime to
||| make never finds one, its comparator is total, and the tiebreak it
||| forbids is never needed.
export
rarc_5_4_9__unique_after_history : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                   (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                   (c : Rlow_4_2_1__chain) -> Elem c (nchains (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) ->
                                   Iret_11_3__distinct (map (ldet_5_5__key (ewm (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) (iret_8_1__tuples (cacts c)))
rarc_5_4_9__unique_after_history life fuel evs alphas rules c ec =
  let (v, ord) = lfst_9_2_1__replay_net_ordered life fuel evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_ordered alphas rules)
      (dw, _, _, _) = v
  in rarc_5_4_9__keys_distinct _ dw (cacts c) (lcyc_1_1__all_lookup (ldet_5_5__view_live_acts _ v) ec)
       (snd (snd (rarc_5_6_5__view_recomputed _ v) c ec))

-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The right-activation and right-retraction theorems for Rete/Network.idr
||| [IRET.7.7], [IRET.7.9.2], [IRET.7.9.3]: a fact entering or leaving one
||| alpha memory keeps every chain consistent with the memories as they
||| now stand. Each node the alpha feeds is handled by the wave theorems of
||| Rete/NetworkView.idr; the deepest node first, so a token the shallower
||| activation creates never meets its own fact twice.
|||
||| NORMATIVE COMPANION to Rete/Network.idr.
module Rete.NetworkPaths

import Rete.FireLoop
import Rete.Network
import Rete.NetworkView
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
-- Extension by one new fact
-- ---------------------------------------------------------------------

--@derives [IRET.7.2]
export
iret_7_2__map_snoc_inv : (f : Lfac_1_7_1__fact) -> (ts : List Iret_7_1__token) -> (y : Iret_7_1__token) ->
                         Elem y (map (\t => t ++ [f]) ts) -> (t ** (Elem t ts, y = t ++ [f]))
iret_7_2__map_snoc_inv f ts y e = let (t ** (et, eq)) = lcyc_1_1__elem_map_inv (\t => t ++ [f]) ts e in (t ** (et, sym eq))

--@derives [IRET.7.2]
export
iret_7_2__map_snoc_fwd : (f : Lfac_1_7_1__fact) -> (ts : List Iret_7_1__token) -> (t : Iret_7_1__token) -> Elem t ts -> Elem (t ++ [f]) (map (\t => t ++ [f]) ts)
iret_7_2__map_snoc_fwd f ts t e = lcyc_1_1__elem_map_fwd (\t => t ++ [f]) e

--@derives [IRET.7.7]
||| Joining against a memory grown by one fact: the old extensions, plus
||| the left tokens the new fact joins, extended by it.
export
iret_7_7__extend_new_fact : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) -> (lm, front : List Iret_7_1__token) ->
                            Iret_7_4__same_set lm front ->
                            Iret_7_4__same_set (iret_7_7__extend_front j (mem ++ [f]) front)
                                               (iret_7_7__extend_front j mem front ++ map (\t => t ++ [f]) (filter (\u => j u f) lm))
iret_7_7__extend_new_fact j mem f lm front sl = \y =>
  ( \e => let (t ** (g ** (et, eg, jg, eq))) = iret_7_7__extend_elem_inv j (mem ++ [f]) front y e
          in case lcyc_1_1__elem_append_inv mem eg of
               Left egm => lcyc_1_1__elem_append_left (replace {p = \z => Elem z (iret_7_7__extend_front j mem front)} (sym eq) (iret_7_7__extend_elem_fwd j mem front t g et egm jg))
               Right e1 => let gf = iret_12__elem_singleton e1
                           in lcyc_1_1__elem_append_right (iret_7_7__extend_front j mem front)
                                (replace {p = \z => Elem z (map (\t => t ++ [f]) (filter (\u => j u f) lm))} (sym (trans eq (cong (\z => t ++ [z]) gf)))
                                   (iret_7_2__map_snoc_fwd f _ t (lcyc_1_1__elem_filter_fwd (\u => j u f) lm (snd (sl t) et) (replace {p = \z => j t z = True} gf jg))))
  , \e => case lcyc_1_1__elem_append_inv (iret_7_7__extend_front j mem front) e of
            Left el => let (t ** (g ** (et, eg, jg, eq))) = iret_7_7__extend_elem_inv j mem front y el
                       in replace {p = \z => Elem z (iret_7_7__extend_front j (mem ++ [f]) front)} (sym eq)
                            (iret_7_7__extend_elem_fwd j (mem ++ [f]) front t g et (lcyc_1_1__elem_append_left eg) jg)
            Right er => let (t ** (et, eq)) = iret_7_2__map_snoc_inv f _ y er
                            (etl, jf) = lcyc_1_1__elem_filter_inv (\u => j u f) lm et
                        in replace {p = \z => Elem z (iret_7_7__extend_front j (mem ++ [f]) front)} (sym eq)
                             (iret_7_7__extend_elem_fwd j (mem ++ [f]) front t f (fst (sl t) etl) (lcyc_1_1__elem_append_right mem Here) jf) )

--@derives [IRET.7.7]
||| Extensions by a fact not in the memory are new.
export
iret_7_7__extend_new_disjoint : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) -> Not (Elem f mem) ->
                                (hit, front : List Iret_7_1__token) -> (y : Iret_7_1__token) ->
                                Elem y (map (\t => t ++ [f]) hit) -> Not (Elem y (iret_7_7__extend_front j mem front))
iret_7_7__extend_new_disjoint j mem f nf hit front y ey ex =
  let (t ** (et, eq)) = iret_7_2__map_snoc_inv f hit y ey
      (u ** (g ** (eu, eg, jg, equ))) = iret_7_7__extend_elem_inv j mem front y ex
  in nf (replace {p = \z => Elem z mem} (snd (iret_7_2__snoc_inj u t g f (trans (sym equ) eq))) eg)

-- ---------------------------------------------------------------------
-- Blocking by one new fact [IRET.7.9.2]
-- ---------------------------------------------------------------------

--@derives [IRET.7.9.2]
export
iret_7_9_2__pass_block_fwd : (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) ->
                             (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                             ((t : Iret_7_1__token) -> Elem t lm -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                             (y : Iret_7_1__token) -> Elem y (iret_7_9_1__pass j (mem ++ [f]) front) ->
                             Elem y (filter (\t => not (rarc_5_6_5__elem t (filter (\u => iret_7_9_4__count u cs == 0) (filter (\u => j u f) lm)))) (iret_7_9_1__pass j mem front))
iret_7_9_2__pass_block_fwd j cs mem f lm front sl cnt y e with (j y f) proof jy
  iret_7_9_2__pass_block_fwd j cs mem f lm front sl cnt y e | True =
    let (ey, z) = iret_7_9_1__pass_elem_inv j (mem ++ [f]) front y e
    in absurd (trans (sym (iret_7_9_1__blockers_hit j mem f y jy)) z)
  iret_7_9_2__pass_block_fwd j cs mem f lm front sl cnt y e | False =
    let (ey, z) = iret_7_9_1__pass_elem_inv j (mem ++ [f]) front y e
    in lcyc_1_1__elem_filter_fwd _ (iret_7_9_1__pass j mem front)
         (iret_7_9_1__pass_elem_fwd j mem front y ey (trans (sym (iret_7_9_1__blockers_miss j mem f y jy)) z))
         (iret_12__not_false _ (iret_11_3__not_elem_tok y _ (\en =>
            lcyc_1_1__bool_not_both (j y f)
              (snd (lcyc_1_1__elem_filter_inv (\u => j u f) lm (fst (lcyc_1_1__elem_filter_inv (\u => iret_7_9_4__count u cs == 0) _ en)))) jy)))

--@derives [IRET.7.9.2]
export
iret_7_9_2__pass_block_bwd : (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) ->
                             (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                             ((t : Iret_7_1__token) -> Elem t lm -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                             (y : Iret_7_1__token) ->
                             Elem y (filter (\t => not (rarc_5_6_5__elem t (filter (\u => iret_7_9_4__count u cs == 0) (filter (\u => j u f) lm)))) (iret_7_9_1__pass j mem front)) ->
                             Elem y (iret_7_9_1__pass j (mem ++ [f]) front)
iret_7_9_2__pass_block_bwd j cs mem f lm front sl cnt y e with (j y f) proof jy
  iret_7_9_2__pass_block_bwd j cs mem f lm front sl cnt y e | True =
    let (ep, ng) = lcyc_1_1__elem_filter_inv _ (iret_7_9_1__pass j mem front) e
        (ey, z) = iret_7_9_1__pass_elem_inv j mem front y ep
    in void (iret_11_3__elem_tok_false y _ (lcyc_1_1__not_true_is_false _ ng)
               (lcyc_1_1__elem_filter_fwd (\u => iret_7_9_4__count u cs == 0) (filter (\u => j u f) lm)
                  (lcyc_1_1__elem_filter_fwd (\u => j u f) lm (snd (sl y) ey) jy)
                  (rewrite trans (cnt y (snd (sl y) ey)) z in Refl)))
  iret_7_9_2__pass_block_bwd j cs mem f lm front sl cnt y e | False =
    let (ep, ng) = lcyc_1_1__elem_filter_inv _ (iret_7_9_1__pass j mem front) e
        (ey, z) = iret_7_9_1__pass_elem_inv j mem front y ep
    in iret_7_9_1__pass_elem_fwd j (mem ++ [f]) front y ey (trans (iret_7_9_1__blockers_miss j mem f y jy) z)

--@derives [IRET.7.9.2]
||| A NOT node's output after a new right fact: what it passed, less the
||| tokens the fact newly blocks.
export
iret_7_9_2__pass_block : (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) ->
                         (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                         ((t : Iret_7_1__token) -> Elem t lm -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                         Iret_7_4__same_set (iret_7_9_1__pass j (mem ++ [f]) front)
                                            (filter (\t => not (rarc_5_6_5__elem t (filter (\u => iret_7_9_4__count u cs == 0) (filter (\u => j u f) lm)))) (iret_7_9_1__pass j mem front))
iret_7_9_2__pass_block j cs mem f lm front sl cnt = \y => (iret_7_9_2__pass_block_fwd j cs mem f lm front sl cnt y, iret_7_9_2__pass_block_bwd j cs mem f lm front sl cnt y)

--@derives [IRET.7.9.2]
||| The tokens a new fact newly blocks were passed.
export
iret_7_9_2__newly_sub : (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) ->
                        (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                        ((t : Iret_7_1__token) -> Elem t lm -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                        (t : Iret_7_1__token) -> Elem t (filter (\u => iret_7_9_4__count u cs == 0) (filter (\u => j u f) lm)) -> Elem t (iret_7_9_1__pass j mem front)
iret_7_9_2__newly_sub j cs mem f lm front sl cnt t e =
  let (eh, z) = lcyc_1_1__elem_filter_inv (\u => iret_7_9_4__count u cs == 0) _ e
      (el, _) = lcyc_1_1__elem_filter_inv (\u => j u f) lm eh
  in iret_7_9_1__pass_elem_fwd j mem front t (fst (sl t) el) (trans (sym (cnt t el)) (lcyc_1_1__nat_eq_true _ 0 z))

--@derives [IRET.7.9.2]
||| Counting a new fact against the tokens it joins gives the blockers of
||| the grown memory.
export
iret_7_9_2__block_ok : (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) ->
                       (lm : List Iret_7_1__token) -> Iret_11_3__distinct lm ->
                       ((t : Iret_7_1__token) -> Elem t lm -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                       (t : Iret_7_1__token) -> Elem t lm ->
                       iret_7_9_4__count t (iret_7_9_2__block (filter (\u => j u f) lm) cs) = iret_7_9_1__blockers j (mem ++ [f]) t
iret_7_9_2__block_ok j cs mem f lm dl cnt t e with (j t f) proof jt
  iret_7_9_2__block_ok j cs mem f lm dl cnt t e | True =
    trans (iret_7_9_2__block_hit (filter (\u => j u f) lm) (iret_11_3__distinct_filter _ lm dl) cs t (lcyc_1_1__elem_filter_fwd (\u => j u f) lm e jt))
          (trans (cong S (cnt t e)) (sym (iret_7_9_1__blockers_hit j mem f t jt)))
  iret_7_9_2__block_ok j cs mem f lm dl cnt t e | False =
    trans (iret_7_9_2__block_miss (filter (\u => j u f) lm) cs t (\eh => lcyc_1_1__bool_not_both (j t f) (snd (lcyc_1_1__elem_filter_inv (\u => j u f) lm eh)) jt))
          (trans (cnt t e) (sym (iret_7_9_1__blockers_miss j mem f t jt)))

-- ---------------------------------------------------------------------
-- RIGHT-ACTIVATION keeps the view [IRET.7.7], [IRET.7.9.2]
-- ---------------------------------------------------------------------

--@derives [IRET.7.7]
--@derives [IRET.7.9.2]
||| A FACT ENTERS ONE ALPHA MEMORY. Every chain consistent with the old
||| memories is, after right-activating its nodes fed by that alpha
||| deepest first, consistent with the new ones: a positive node's
||| extensions by the fact reach the terminal through the nodes below,
||| and a NOT node's newly blocked tokens are withdrawn from them.
export
iret_7_7__right_activate_consistent : (wm : Rarc_5_6_4__wm) -> (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas' ->
                                      (a : Nat) -> (f : Lfac_1_7_1__fact) ->
                                      ((i : Nat) -> Not (i = a) -> iret_6_6__mem_at alphas' i = iret_6_6__mem_at alphas i) ->
                                      iret_6_6__mem_at alphas' a = iret_6_6__mem_at alphas a ++ [f] -> Not (Elem f (iret_6_6__mem_at alphas a)) ->
                                      (front : List Iret_7_1__token) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                      Iret_7_7__consistent alphas front nodes acts ->
                                      Iret_7_7__consistent alphas' front (fst (iret_7_7__right_activate wm alphas' a f nodes acts)) (snd (iret_7_7__right_activate wm alphas' a f nodes acts))
iret_7_7__right_activate_consistent wm alphas alphas' dm a f frame delta nf front [] acts c = c
iret_7_7__right_activate_consistent wm alphas alphas' dm a f frame delta nf front (b :: rest) acts (sl, dl, cnt, rec) with (balpha b == a) proof ba
  iret_7_7__right_activate_consistent wm alphas alphas' dm a f frame delta nf front (b :: rest) acts (sl, dl, cnt, rec) | True with (bneg b) proof bn
    iret_7_7__right_activate_consistent wm alphas alphas' dm a f frame delta nf front (b :: rest) acts (sl, dl, cnt, rec) | True | True =
      let memEq : (iret_6_6__mem_at alphas' (balpha b) = iret_6_6__mem_at alphas (balpha b) ++ [f])
          memEq = replace {p = \i => iret_6_6__mem_at alphas' i = iret_6_6__mem_at alphas i ++ [f]} (sym (lcyc_1_1__nat_eq_true (balpha b) a ba)) delta
          ih = iret_7_7__right_activate_consistent wm alphas alphas' dm a f frame delta nf
                 (iret_7_9_1__pass (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front) rest acts rec
          uw = iret_7_8__unwave_consistent alphas' dm (iret_7_9_1__pass (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)
                 (filter (\u => iret_7_9_4__count u (bcounts b) == 0) (filter (\u => bjoin b u f) (blmem b)))
                 (fst (iret_7_7__right_activate wm alphas' a f rest acts)) (snd (iret_7_7__right_activate wm alphas' a f rest acts)) ih
                 (iret_7_9_2__newly_sub (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) f (blmem b) front sl (cnt Refl))
      in ( sl, dl
         , \_, t, e => replace {p = \m => iret_7_9_4__count t (iret_7_9_2__block (filter (\u => bjoin b u f) (blmem b)) (bcounts b)) = iret_7_9_1__blockers (bjoin b) m t} (sym memEq)
                         (iret_7_9_2__block_ok (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) f (blmem b) dl (cnt Refl) t e)
         , replace {p = \flag => Iret_7_7__consistent alphas' (iret_7_7__next_of flag (bjoin b) (iret_6_6__mem_at alphas' (balpha b)) front)
                                   (fst (iret_7_8__unwave alphas' (fst (iret_7_7__right_activate wm alphas' a f rest acts)) (filter (\u => iret_7_9_4__count u (bcounts b) == 0) (filter (\u => bjoin b u f) (blmem b))) (snd (iret_7_7__right_activate wm alphas' a f rest acts))))
                                   (snd (iret_7_8__unwave alphas' (fst (iret_7_7__right_activate wm alphas' a f rest acts)) (filter (\u => iret_7_9_4__count u (bcounts b) == 0) (filter (\u => bjoin b u f) (blmem b))) (snd (iret_7_7__right_activate wm alphas' a f rest acts))))}
             (sym bn)
             (iret_7_7__consistent_same_set alphas' _ (iret_7_9_1__pass (bjoin b) (iret_6_6__mem_at alphas' (balpha b)) front) _ _
               (replace {p = \m => Iret_7_4__same_set (filter (\t => not (rarc_5_6_5__elem t (filter (\u => iret_7_9_4__count u (bcounts b) == 0) (filter (\u => bjoin b u f) (blmem b))))) (iret_7_9_1__pass (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)) (iret_7_9_1__pass (bjoin b) m front)} (sym memEq)
                  (iret_7_4__same_set_sym _ _ (iret_7_9_2__pass_block (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) f (blmem b) front sl (cnt Refl))))
               uw) )
    iret_7_7__right_activate_consistent wm alphas alphas' dm a f frame delta nf front (b :: rest) acts (sl, dl, cnt, rec) | True | False =
      let memEq : (iret_6_6__mem_at alphas' (balpha b) = iret_6_6__mem_at alphas (balpha b) ++ [f])
          memEq = replace {p = \i => iret_6_6__mem_at alphas' i = iret_6_6__mem_at alphas i ++ [f]} (sym (lcyc_1_1__nat_eq_true (balpha b) a ba)) delta
          nf' : Not (Elem f (iret_6_6__mem_at alphas (balpha b)))
          nf' = replace {p = \i => Not (Elem f (iret_6_6__mem_at alphas i))} (sym (lcyc_1_1__nat_eq_true (balpha b) a ba)) nf
          ih = iret_7_7__right_activate_consistent wm alphas alphas' dm a f frame delta nf
                 (iret_7_7__extend_front (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front) rest acts rec
          wv = iret_7_7__wave_consistent wm alphas' dm (iret_7_7__extend_front (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)
                 (map (\t => t ++ [f]) (filter (\u => bjoin b u f) (blmem b)))
                 (fst (iret_7_7__right_activate wm alphas' a f rest acts)) (snd (iret_7_7__right_activate wm alphas' a f rest acts)) ih
                 (iret_11_3__distinct_map_inj (\t => t ++ [f]) (\t, u, eq => fst (iret_7_2__snoc_inj t u f f eq)) _ (iret_11_3__distinct_filter _ (blmem b) dl))
                 (iret_7_7__extend_new_disjoint (bjoin b) (iret_6_6__mem_at alphas (balpha b)) f nf' _ front)
      in ( sl, dl, \bn' => absurd (trans (sym bn) bn')
         , replace {p = \flag => Iret_7_7__consistent alphas' (iret_7_7__next_of flag (bjoin b) (iret_6_6__mem_at alphas' (balpha b)) front)
                                   (fst (iret_7_7__wave wm alphas' (fst (iret_7_7__right_activate wm alphas' a f rest acts)) (map (\t => t ++ [f]) (filter (\u => bjoin b u f) (blmem b))) (snd (iret_7_7__right_activate wm alphas' a f rest acts))))
                                   (snd (iret_7_7__wave wm alphas' (fst (iret_7_7__right_activate wm alphas' a f rest acts)) (map (\t => t ++ [f]) (filter (\u => bjoin b u f) (blmem b))) (snd (iret_7_7__right_activate wm alphas' a f rest acts))))}
             (sym bn)
             (iret_7_7__consistent_same_set alphas' _ (iret_7_7__extend_front (bjoin b) (iret_6_6__mem_at alphas' (balpha b)) front) _ _
               (replace {p = \m => Iret_7_4__same_set (iret_7_7__extend_front (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front ++ map (\t => t ++ [f]) (filter (\u => bjoin b u f) (blmem b))) (iret_7_7__extend_front (bjoin b) m front)} (sym memEq)
                  (iret_7_4__same_set_sym _ _ (iret_7_7__extend_new_fact (bjoin b) (iret_6_6__mem_at alphas (balpha b)) f (blmem b) front sl)))
               wv) )
  iret_7_7__right_activate_consistent wm alphas alphas' dm a f frame delta nf front (b :: rest) acts (sl, dl, cnt, rec) | False =
    let memEq : (iret_6_6__mem_at alphas' (balpha b) = iret_6_6__mem_at alphas (balpha b))
        memEq = frame (balpha b) (lcyc_1_1__nat_neq_false (balpha b) a ba)
        ih = iret_7_7__right_activate_consistent wm alphas alphas' dm a f frame delta nf
               (iret_7_7__next_of (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front) rest acts rec
    in ( sl, dl
       , replace {p = \m => Iret_7_9_4__counts_ok b m (blmem b)} (sym memEq) cnt
       , replace {p = \m => Iret_7_7__consistent alphas' (iret_7_7__next_of (bneg b) (bjoin b) m front)
                                                  (fst (iret_7_7__right_activate wm alphas' a f rest acts)) (snd (iret_7_7__right_activate wm alphas' a f rest acts))} (sym memEq) ih )

-- ---------------------------------------------------------------------
-- Removal of one fact from a memory
-- ---------------------------------------------------------------------

--@derives [LFAC.2.5.4]
export
lfac_2_5_4__same_fact_neq : (g, f : Lfac_1_7_1__fact) -> Not (g = f) -> lfac_2_5_4__same_fact g f = False
lfac_2_5_4__same_fact_neq g f ne = iret_12__bool_false_of _ (\p => ne (lfac_2_5_4__same_fact_eq g f p))

--@derives [RARC.5.6.4]
export
rarc_5_6_4__remove_exact_elem_inv : (f : Lfac_1_7_1__fact) -> (xs : List Lfac_1_7_1__fact) -> (g : Lfac_1_7_1__fact) ->
                                    Elem g (rarc_5_6_4__remove_exact f xs) -> (Elem g xs, Not (g = f))
rarc_5_6_4__remove_exact_elem_inv f xs g e =
  let (e', ns) = lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h f)) xs e
  in (e', \eq => lcyc_1_1__bool_not_both (lfac_2_5_4__same_fact g f) (replace {p = \z => lfac_2_5_4__same_fact z f = True} (sym eq) (lfac_2_5_4__same_fact_refl f)) (lcyc_1_1__not_true_is_false _ ns))

--@derives [RARC.5.6.4]
export
rarc_5_6_4__remove_exact_elem_fwd : (f : Lfac_1_7_1__fact) -> (xs : List Lfac_1_7_1__fact) -> (g : Lfac_1_7_1__fact) ->
                                    Elem g xs -> Not (g = f) -> Elem g (rarc_5_6_4__remove_exact f xs)
rarc_5_6_4__remove_exact_elem_fwd f xs g e ne = lcyc_1_1__elem_filter_fwd _ xs e (iret_12__not_false _ (lfac_2_5_4__same_fact_neq g f ne))

--@derives [RARC.5.6.4]
export
rarc_5_6_4__remove_exact_absent : (f : Lfac_1_7_1__fact) -> (xs : List Lfac_1_7_1__fact) -> Not (Elem f xs) -> rarc_5_6_4__remove_exact f xs = xs
rarc_5_6_4__remove_exact_absent f [] nf = Refl
rarc_5_6_4__remove_exact_absent f (g :: gs) nf with (lfac_2_5_4__same_fact g f) proof sg
  rarc_5_6_4__remove_exact_absent f (g :: gs) nf | True = void (nf (replace {p = \z => Elem z (g :: gs)} (lfac_2_5_4__same_fact_eq g f sg) Here))
  rarc_5_6_4__remove_exact_absent f (g :: gs) nf | False = cong (g ::) (rarc_5_6_4__remove_exact_absent f gs (\e => nf (There e)))

--@derives [IRET.7.9.1]
||| Removing a joining fact from a distinct memory drops one blocker.
export
iret_7_9_1__blockers_remove_hit : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> Iret_11_3__distinct mem -> (f : Lfac_1_7_1__fact) -> Elem f mem ->
                                  (t : Iret_7_1__token) -> j t f = True -> iret_7_9_1__blockers j mem t = S (iret_7_9_1__blockers j (rarc_5_6_4__remove_exact f mem) t)
iret_7_9_1__blockers_remove_hit j (f :: gs) (DCons nf d) f Here t jt =
  rewrite lfac_2_5_4__same_fact_refl f in rewrite rarc_5_6_4__remove_exact_absent f gs nf in rewrite jt in Refl
iret_7_9_1__blockers_remove_hit j (g :: gs) (DCons ng d) f (There e) t jt with (j t g) proof jg
  iret_7_9_1__blockers_remove_hit j (g :: gs) (DCons ng d) f (There e) t jt | True =
    rewrite lfac_2_5_4__same_fact_neq g f (\eq => ng (replace {p = \z => Elem z gs} (sym eq) e)) in
    rewrite jg in cong S (iret_7_9_1__blockers_remove_hit j gs d f e t jt)
  iret_7_9_1__blockers_remove_hit j (g :: gs) (DCons ng d) f (There e) t jt | False =
    rewrite lfac_2_5_4__same_fact_neq g f (\eq => ng (replace {p = \z => Elem z gs} (sym eq) e)) in
    rewrite jg in iret_7_9_1__blockers_remove_hit j gs d f e t jt

--@derives [IRET.7.9.1]
||| Removing a fact the token does not join leaves its blockers.
export
iret_7_9_1__blockers_remove_miss : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) ->
                                   (t : Iret_7_1__token) -> j t f = False -> iret_7_9_1__blockers j (rarc_5_6_4__remove_exact f mem) t = iret_7_9_1__blockers j mem t
iret_7_9_1__blockers_remove_miss j [] f t jt = Refl
iret_7_9_1__blockers_remove_miss j (g :: gs) f t jt with (lfac_2_5_4__same_fact g f) proof sg
  iret_7_9_1__blockers_remove_miss j (g :: gs) f t jt | True =
    rewrite replace {p = \z => j t z = False} (sym (lfac_2_5_4__same_fact_eq g f sg)) jt in iret_7_9_1__blockers_remove_miss j gs f t jt
  iret_7_9_1__blockers_remove_miss j (g :: gs) f t jt | False with (j t g)
    iret_7_9_1__blockers_remove_miss j (g :: gs) f t jt | False | True = cong S (iret_7_9_1__blockers_remove_miss j gs f t jt)
    iret_7_9_1__blockers_remove_miss j (g :: gs) f t jt | False | False = iret_7_9_1__blockers_remove_miss j gs f t jt

-- ---------------------------------------------------------------------
-- Release by one retracted fact [IRET.7.9.3]
-- ---------------------------------------------------------------------

--@derives [IRET.7.9.3]
export
iret_7_9_3__pass_unblock_fwd : (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) -> Iret_11_3__distinct mem ->
                               (f : Lfac_1_7_1__fact) -> Elem f mem -> (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                               ((t : Iret_7_1__token) -> Elem t lm -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                               (y : Iret_7_1__token) -> Elem y (iret_7_9_1__pass j (rarc_5_6_4__remove_exact f mem) front) ->
                               Elem y (iret_7_9_1__pass j mem front ++ filter (\u => iret_7_9_4__count u cs == 1) (filter (\u => j u f) lm))
iret_7_9_3__pass_unblock_fwd j cs mem dm f ef lm front sl cnt y e with (j y f) proof jy
  iret_7_9_3__pass_unblock_fwd j cs mem dm f ef lm front sl cnt y e | True =
    let (ey, z) = iret_7_9_1__pass_elem_inv j (rarc_5_6_4__remove_exact f mem) front y e
        one : (iret_7_9_4__count y cs = 1)
        one = trans (cnt y (snd (sl y) ey)) (trans (iret_7_9_1__blockers_remove_hit j mem dm f ef y jy) (cong S z))
    in lcyc_1_1__elem_append_right (iret_7_9_1__pass j mem front)
         (lcyc_1_1__elem_filter_fwd (\u => iret_7_9_4__count u cs == 1) _ (lcyc_1_1__elem_filter_fwd (\u => j u f) lm (snd (sl y) ey) jy) (rewrite one in Refl))
  iret_7_9_3__pass_unblock_fwd j cs mem dm f ef lm front sl cnt y e | False =
    let (ey, z) = iret_7_9_1__pass_elem_inv j (rarc_5_6_4__remove_exact f mem) front y e
    in lcyc_1_1__elem_append_left (iret_7_9_1__pass_elem_fwd j mem front y ey (trans (sym (iret_7_9_1__blockers_remove_miss j mem f y jy)) z))

--@derives [IRET.7.9.3]
export
iret_7_9_3__pass_unblock_bwd : (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) -> Iret_11_3__distinct mem ->
                               (f : Lfac_1_7_1__fact) -> Elem f mem -> (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                               ((t : Iret_7_1__token) -> Elem t lm -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                               (y : Iret_7_1__token) -> Elem y (iret_7_9_1__pass j mem front ++ filter (\u => iret_7_9_4__count u cs == 1) (filter (\u => j u f) lm)) ->
                               Elem y (iret_7_9_1__pass j (rarc_5_6_4__remove_exact f mem) front)
iret_7_9_3__pass_unblock_bwd j cs mem dm f ef lm front sl cnt y e with (j y f) proof jy
  iret_7_9_3__pass_unblock_bwd j cs mem dm f ef lm front sl cnt y e | True = case lcyc_1_1__elem_append_inv (iret_7_9_1__pass j mem front) e of
    Left ep => let (ey, z) = iret_7_9_1__pass_elem_inv j mem front y ep
               in absurd (trans (sym (iret_7_9_1__blockers_remove_hit j mem dm f ef y jy)) z)
    Right er => let (eh, one) = lcyc_1_1__elem_filter_inv (\u => iret_7_9_4__count u cs == 1) _ er
                    (el, _) = lcyc_1_1__elem_filter_inv (\u => j u f) lm eh
                    bl : (S (iret_7_9_1__blockers j (rarc_5_6_4__remove_exact f mem) y) = 1)
                    bl = trans (sym (iret_7_9_1__blockers_remove_hit j mem dm f ef y jy)) (trans (sym (cnt y el)) (lcyc_1_1__nat_eq_true _ 1 one))
                in iret_7_9_1__pass_elem_fwd j (rarc_5_6_4__remove_exact f mem) front y (fst (sl y) el) (lcyc_1_1__succ_inj bl)
  iret_7_9_3__pass_unblock_bwd j cs mem dm f ef lm front sl cnt y e | False = case lcyc_1_1__elem_append_inv (iret_7_9_1__pass j mem front) e of
    Left ep => let (ey, z) = iret_7_9_1__pass_elem_inv j mem front y ep
               in iret_7_9_1__pass_elem_fwd j (rarc_5_6_4__remove_exact f mem) front y ey (trans (iret_7_9_1__blockers_remove_miss j mem f y jy) z)
    Right er => let (eh, _) = lcyc_1_1__elem_filter_inv (\u => iret_7_9_4__count u cs == 1) _ er
                in void (lcyc_1_1__bool_not_both (j y f) (snd (lcyc_1_1__elem_filter_inv (\u => j u f) lm eh)) jy)

--@derives [IRET.7.9.3]
||| A NOT node's output after a right fact leaves: what it passed, plus
||| the tokens the fact alone was blocking.
export
iret_7_9_3__pass_unblock : (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) -> Iret_11_3__distinct mem ->
                           (f : Lfac_1_7_1__fact) -> Elem f mem -> (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                           ((t : Iret_7_1__token) -> Elem t lm -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                           Iret_7_4__same_set (iret_7_9_1__pass j (rarc_5_6_4__remove_exact f mem) front)
                                              (iret_7_9_1__pass j mem front ++ filter (\u => iret_7_9_4__count u cs == 1) (filter (\u => j u f) lm))
iret_7_9_3__pass_unblock j cs mem dm f ef lm front sl cnt = \y =>
  (iret_7_9_3__pass_unblock_fwd j cs mem dm f ef lm front sl cnt y, iret_7_9_3__pass_unblock_bwd j cs mem dm f ef lm front sl cnt y)

--@derives [IRET.7.9.3]
||| The released tokens were not passed before.
export
iret_7_9_3__released_disjoint : (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) ->
                                (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                                ((t : Iret_7_1__token) -> Elem t lm -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                                (t : Iret_7_1__token) -> Elem t (filter (\u => iret_7_9_4__count u cs == 1) (filter (\u => j u f) lm)) -> Not (Elem t (iret_7_9_1__pass j mem front))
iret_7_9_3__released_disjoint j cs mem f lm front sl cnt t er ep =
  let (eh, one) = lcyc_1_1__elem_filter_inv (\u => iret_7_9_4__count u cs == 1) _ er
      (el, _) = lcyc_1_1__elem_filter_inv (\u => j u f) lm eh
      (_, z) = iret_7_9_1__pass_elem_inv j mem front t ep
  in absurd (trans (sym (trans (sym (cnt t el)) (lcyc_1_1__nat_eq_true _ 1 one))) z)

--@derives [IRET.7.9.3]
||| Uncounting a retracted fact against the tokens it joined gives the
||| blockers of the shrunk memory.
export
iret_7_9_3__unblock_ok : (j : Iret_7_5__join) -> (cs : List (Iret_7_1__token, Nat)) -> (mem : List Lfac_1_7_1__fact) -> Iret_11_3__distinct mem ->
                         (f : Lfac_1_7_1__fact) -> Elem f mem -> (lm : List Iret_7_1__token) -> Iret_11_3__distinct lm ->
                         ((t : Iret_7_1__token) -> Elem t lm -> iret_7_9_4__count t cs = iret_7_9_1__blockers j mem t) ->
                         (t : Iret_7_1__token) -> Elem t lm ->
                         iret_7_9_4__count t (iret_7_9_3__unblock (filter (\u => j u f) lm) cs) = iret_7_9_1__blockers j (rarc_5_6_4__remove_exact f mem) t
iret_7_9_3__unblock_ok j cs mem dm f ef lm dl cnt t e with (j t f) proof jt
  iret_7_9_3__unblock_ok j cs mem dm f ef lm dl cnt t e | True =
    trans (iret_7_9_3__unblock_hit (filter (\u => j u f) lm) (iret_11_3__distinct_filter _ lm dl) cs t (lcyc_1_1__elem_filter_fwd (\u => j u f) lm e jt))
          (trans (cong pred (cnt t e)) (cong pred (iret_7_9_1__blockers_remove_hit j mem dm f ef t jt)))
  iret_7_9_3__unblock_ok j cs mem dm f ef lm dl cnt t e | False =
    trans (iret_7_9_3__unblock_miss (filter (\u => j u f) lm) cs t (\eh => lcyc_1_1__bool_not_both (j t f) (snd (lcyc_1_1__elem_filter_inv (\u => j u f) lm eh)) jt))
          (trans (cnt t e) (sym (iret_7_9_1__blockers_remove_miss j mem f t jt)))

-- ---------------------------------------------------------------------
-- Extensions by one retracted fact
-- ---------------------------------------------------------------------

--@derives [IRET.7.7]
export
iret_7_7__extend_remove_sub : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) -> Elem f mem ->
                              (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                              (y : Iret_7_1__token) -> Elem y (map (\t => t ++ [f]) (filter (\u => j u f) lm)) -> Elem y (iret_7_7__extend_front j mem front)
iret_7_7__extend_remove_sub j mem f ef lm front sl y e =
  let (t ** (et, eq)) = iret_7_2__map_snoc_inv f _ y e
      (el, jt) = lcyc_1_1__elem_filter_inv (\u => j u f) lm et
  in replace {p = \z => Elem z (iret_7_7__extend_front j mem front)} (sym eq) (iret_7_7__extend_elem_fwd j mem front t f (fst (sl t) el) ef jt)

--@derives [IRET.7.7]
export
iret_7_7__extend_remove_fwd : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) ->
                              (lm, front : List Iret_7_1__token) -> (y : Iret_7_1__token) ->
                              Elem y (iret_7_7__extend_front j (rarc_5_6_4__remove_exact f mem) front) ->
                              Elem y (filter (\z => not (rarc_5_6_5__elem z (map (\t => t ++ [f]) (filter (\u => j u f) lm)))) (iret_7_7__extend_front j mem front))
iret_7_7__extend_remove_fwd j mem f lm front y e =
  let (t ** (g ** (et, eg, jg, eq))) = iret_7_7__extend_elem_inv j (rarc_5_6_4__remove_exact f mem) front y e
      (egm, ng) = rarc_5_6_4__remove_exact_elem_inv f mem g eg
  in lcyc_1_1__elem_filter_fwd _ (iret_7_7__extend_front j mem front)
       (replace {p = \z => Elem z (iret_7_7__extend_front j mem front)} (sym eq) (iret_7_7__extend_elem_fwd j mem front t g et egm jg))
       (iret_12__not_false _ (iret_11_3__not_elem_tok y _ (\em =>
          let (u ** (_, equ)) = iret_7_2__map_snoc_inv f _ y em
          in ng (snd (iret_7_2__snoc_inj t u g f (trans (sym eq) equ))))))

--@derives [IRET.7.7]
export
iret_7_7__extend_remove_bwd_at : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) ->
                                 (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                                 (y, t : Iret_7_1__token) -> (g : Lfac_1_7_1__fact) -> Elem t front -> Elem g mem -> j t g = True -> y = t ++ [g] ->
                                 Not (Elem y (map (\t => t ++ [f]) (filter (\u => j u f) lm))) ->
                                 Elem y (iret_7_7__extend_front j (rarc_5_6_4__remove_exact f mem) front)
iret_7_7__extend_remove_bwd_at j mem f lm front sl y t g et eg jg eq nm with (lfac_2_5_4__same_fact g f) proof sg
  iret_7_7__extend_remove_bwd_at j mem f lm front sl y t g et eg jg eq nm | True =
    let gf = lfac_2_5_4__same_fact_eq g f sg
    in void (nm (replace {p = \z => Elem z (map (\t => t ++ [f]) (filter (\u => j u f) lm))} (sym (trans eq (cong (\z => t ++ [z]) gf)))
                   (iret_7_2__map_snoc_fwd f _ t (lcyc_1_1__elem_filter_fwd (\u => j u f) lm (snd (sl t) et) (replace {p = \z => j t z = True} gf jg)))))
  iret_7_7__extend_remove_bwd_at j mem f lm front sl y t g et eg jg eq nm | False =
    replace {p = \z => Elem z (iret_7_7__extend_front j (rarc_5_6_4__remove_exact f mem) front)} (sym eq)
      (iret_7_7__extend_elem_fwd j (rarc_5_6_4__remove_exact f mem) front t g et
         (rarc_5_6_4__remove_exact_elem_fwd f mem g eg (\gf => lcyc_1_1__bool_not_both (lfac_2_5_4__same_fact g f) (replace {p = \z => lfac_2_5_4__same_fact z f = True} (sym gf) (lfac_2_5_4__same_fact_refl f)) sg)) jg)

--@derives [IRET.7.7]
||| A positive node's output after a right fact leaves: what it passed,
||| less the extensions built from the fact.
export
iret_7_7__extend_remove : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (f : Lfac_1_7_1__fact) ->
                          (lm, front : List Iret_7_1__token) -> Iret_7_4__same_set lm front ->
                          Iret_7_4__same_set (iret_7_7__extend_front j (rarc_5_6_4__remove_exact f mem) front)
                                             (filter (\z => not (rarc_5_6_5__elem z (map (\t => t ++ [f]) (filter (\u => j u f) lm)))) (iret_7_7__extend_front j mem front))
iret_7_7__extend_remove j mem f lm front sl = \y =>
  ( iret_7_7__extend_remove_fwd j mem f lm front y
  , \e => let (ep, ng) = lcyc_1_1__elem_filter_inv _ (iret_7_7__extend_front j mem front) e
              (t ** (g ** (et, eg, jg, eq))) = iret_7_7__extend_elem_inv j mem front y ep
          in iret_7_7__extend_remove_bwd_at j mem f lm front sl y t g et eg jg eq (iret_11_3__elem_tok_false y _ (lcyc_1_1__not_true_is_false _ ng)) )

-- ---------------------------------------------------------------------
-- RIGHT-RETRACTION keeps the view [IRET.7.7], [IRET.7.9.3]
-- ---------------------------------------------------------------------

--@derives [IRET.7.7]
--@derives [IRET.7.9.3]
||| A FACT LEAVES ONE ALPHA MEMORY. Every chain consistent with the old
||| memories is, after right-retracting its nodes fed by that alpha
||| deepest first, consistent with the new ones: a positive node's
||| extensions by the fact leave the nodes below, and a NOT node releases
||| the tokens the fact alone was blocking.
export
iret_7_7__right_retract_consistent : (wm : Rarc_5_6_4__wm) -> (alphas, alphas' : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas -> Iret_6_5__distinct_mems alphas' ->
                                     (a : Nat) -> (f : Lfac_1_7_1__fact) ->
                                     ((i : Nat) -> Not (i = a) -> iret_6_6__mem_at alphas' i = iret_6_6__mem_at alphas i) ->
                                     iret_6_6__mem_at alphas' a = rarc_5_6_4__remove_exact f (iret_6_6__mem_at alphas a) -> Elem f (iret_6_6__mem_at alphas a) ->
                                     (front : List Iret_7_1__token) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) ->
                                     Iret_7_7__consistent alphas front nodes acts ->
                                     Iret_7_7__consistent alphas' front (fst (iret_7_7__right_retract wm alphas' a f nodes acts)) (snd (iret_7_7__right_retract wm alphas' a f nodes acts))
iret_7_7__right_retract_consistent wm alphas alphas' dm0 dm a f frame delta ef front [] acts c = c
iret_7_7__right_retract_consistent wm alphas alphas' dm0 dm a f frame delta ef front (b :: rest) acts (sl, dl, cnt, rec) with (balpha b == a) proof ba
  iret_7_7__right_retract_consistent wm alphas alphas' dm0 dm a f frame delta ef front (b :: rest) acts (sl, dl, cnt, rec) | True with (bneg b) proof bn
    iret_7_7__right_retract_consistent wm alphas alphas' dm0 dm a f frame delta ef front (b :: rest) acts (sl, dl, cnt, rec) | True | True =
      let baEq : (balpha b = a)
          baEq = lcyc_1_1__nat_eq_true (balpha b) a ba
          memEq : (iret_6_6__mem_at alphas' (balpha b) = rarc_5_6_4__remove_exact f (iret_6_6__mem_at alphas (balpha b)))
          memEq = replace {p = \i => iret_6_6__mem_at alphas' i = rarc_5_6_4__remove_exact f (iret_6_6__mem_at alphas i)} (sym baEq) delta
          ef' : Elem f (iret_6_6__mem_at alphas (balpha b))
          ef' = replace {p = \i => Elem f (iret_6_6__mem_at alphas i)} (sym baEq) ef
          ih = iret_7_7__right_retract_consistent wm alphas alphas' dm0 dm a f frame delta ef
                 (iret_7_9_1__pass (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front) rest acts rec
          wv = iret_7_7__wave_consistent wm alphas' dm (iret_7_9_1__pass (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)
                 (filter (\u => iret_7_9_4__count u (bcounts b) == 1) (filter (\u => bjoin b u f) (blmem b)))
                 (fst (iret_7_7__right_retract wm alphas' a f rest acts)) (snd (iret_7_7__right_retract wm alphas' a f rest acts)) ih
                 (iret_11_3__distinct_filter _ _ (iret_11_3__distinct_filter _ (blmem b) dl))
                 (iret_7_9_3__released_disjoint (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) f (blmem b) front sl (cnt Refl))
      in ( sl, dl
         , \_, t, e => replace {p = \m => iret_7_9_4__count t (iret_7_9_3__unblock (filter (\u => bjoin b u f) (blmem b)) (bcounts b)) = iret_7_9_1__blockers (bjoin b) m t} (sym memEq)
                         (iret_7_9_3__unblock_ok (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) (dm0 (balpha b)) f ef' (blmem b) dl (cnt Refl) t e)
         , replace {p = \flag => Iret_7_7__consistent alphas' (iret_7_7__next_of flag (bjoin b) (iret_6_6__mem_at alphas' (balpha b)) front)
                                   (fst (iret_7_7__wave wm alphas' (fst (iret_7_7__right_retract wm alphas' a f rest acts)) (filter (\u => iret_7_9_4__count u (bcounts b) == 1) (filter (\u => bjoin b u f) (blmem b))) (snd (iret_7_7__right_retract wm alphas' a f rest acts))))
                                   (snd (iret_7_7__wave wm alphas' (fst (iret_7_7__right_retract wm alphas' a f rest acts)) (filter (\u => iret_7_9_4__count u (bcounts b) == 1) (filter (\u => bjoin b u f) (blmem b))) (snd (iret_7_7__right_retract wm alphas' a f rest acts))))}
             (sym bn)
             (iret_7_7__consistent_same_set alphas' _ (iret_7_9_1__pass (bjoin b) (iret_6_6__mem_at alphas' (balpha b)) front) _ _
               (replace {p = \m => Iret_7_4__same_set (iret_7_9_1__pass (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front ++ filter (\u => iret_7_9_4__count u (bcounts b) == 1) (filter (\u => bjoin b u f) (blmem b))) (iret_7_9_1__pass (bjoin b) m front)} (sym memEq)
                  (iret_7_4__same_set_sym _ _ (iret_7_9_3__pass_unblock (bjoin b) (bcounts b) (iret_6_6__mem_at alphas (balpha b)) (dm0 (balpha b)) f ef' (blmem b) front sl (cnt Refl))))
               wv) )
    iret_7_7__right_retract_consistent wm alphas alphas' dm0 dm a f frame delta ef front (b :: rest) acts (sl, dl, cnt, rec) | True | False =
      let baEq : (balpha b = a)
          baEq = lcyc_1_1__nat_eq_true (balpha b) a ba
          memEq : (iret_6_6__mem_at alphas' (balpha b) = rarc_5_6_4__remove_exact f (iret_6_6__mem_at alphas (balpha b)))
          memEq = replace {p = \i => iret_6_6__mem_at alphas' i = rarc_5_6_4__remove_exact f (iret_6_6__mem_at alphas i)} (sym baEq) delta
          ef' : Elem f (iret_6_6__mem_at alphas (balpha b))
          ef' = replace {p = \i => Elem f (iret_6_6__mem_at alphas i)} (sym baEq) ef
          ih = iret_7_7__right_retract_consistent wm alphas alphas' dm0 dm a f frame delta ef
                 (iret_7_7__extend_front (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front) rest acts rec
          uw = iret_7_8__unwave_consistent alphas' dm (iret_7_7__extend_front (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)
                 (map (\t => t ++ [f]) (filter (\u => bjoin b u f) (blmem b)))
                 (fst (iret_7_7__right_retract wm alphas' a f rest acts)) (snd (iret_7_7__right_retract wm alphas' a f rest acts)) ih
                 (iret_7_7__extend_remove_sub (bjoin b) (iret_6_6__mem_at alphas (balpha b)) f ef' (blmem b) front sl)
      in ( sl, dl, \bn' => absurd (trans (sym bn) bn')
         , replace {p = \flag => Iret_7_7__consistent alphas' (iret_7_7__next_of flag (bjoin b) (iret_6_6__mem_at alphas' (balpha b)) front)
                                   (fst (iret_7_8__unwave alphas' (fst (iret_7_7__right_retract wm alphas' a f rest acts)) (map (\t => t ++ [f]) (filter (\u => bjoin b u f) (blmem b))) (snd (iret_7_7__right_retract wm alphas' a f rest acts))))
                                   (snd (iret_7_8__unwave alphas' (fst (iret_7_7__right_retract wm alphas' a f rest acts)) (map (\t => t ++ [f]) (filter (\u => bjoin b u f) (blmem b))) (snd (iret_7_7__right_retract wm alphas' a f rest acts))))}
             (sym bn)
             (iret_7_7__consistent_same_set alphas' _ (iret_7_7__extend_front (bjoin b) (iret_6_6__mem_at alphas' (balpha b)) front) _ _
               (replace {p = \m => Iret_7_4__same_set (filter (\z => not (rarc_5_6_5__elem z (map (\t => t ++ [f]) (filter (\u => bjoin b u f) (blmem b))))) (iret_7_7__extend_front (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front)) (iret_7_7__extend_front (bjoin b) m front)} (sym memEq)
                  (iret_7_4__same_set_sym _ _ (iret_7_7__extend_remove (bjoin b) (iret_6_6__mem_at alphas (balpha b)) f (blmem b) front sl)))
               uw) )
  iret_7_7__right_retract_consistent wm alphas alphas' dm0 dm a f frame delta ef front (b :: rest) acts (sl, dl, cnt, rec) | False =
    let memEq : (iret_6_6__mem_at alphas' (balpha b) = iret_6_6__mem_at alphas (balpha b))
        memEq = frame (balpha b) (lcyc_1_1__nat_neq_false (balpha b) a ba)
        ih = iret_7_7__right_retract_consistent wm alphas alphas' dm0 dm a f frame delta ef
               (iret_7_7__next_of (bneg b) (bjoin b) (iret_6_6__mem_at alphas (balpha b)) front) rest acts rec
    in ( sl, dl
       , replace {p = \m => Iret_7_9_4__counts_ok b m (blmem b)} (sym memEq) cnt
       , replace {p = \m => Iret_7_7__consistent alphas' (iret_7_7__next_of (bneg b) (bjoin b) m front)
                                                  (fst (iret_7_7__right_retract wm alphas' a f rest acts)) (snd (iret_7_7__right_retract wm alphas' a f rest acts))} (sym memEq) ih )

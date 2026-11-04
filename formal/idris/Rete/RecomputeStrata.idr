-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Recompute-and-diff stratum by stratum, and a hybrid mechanism: recompute the
||| recursive strata, keep the refcount everywhere else.
|||
||| NORMATIVE COMPANION to Rete/Refcount.idr, on its abstract model: facts
||| are naturals, a stratum is a list of justifications. The hybrid itself
||| is `--@gap` -- no clause describes it -- and what it proves
||| about [LLOG.2.5] is tied there.
|||
||| WHAT IS PROVED.
|||
|||   * N STRATA COMPOSE (`llog_2_5__strata_compose`): recomputing each
|||     stratum over the one below it, in the stratification's order, is
|||     the global recompute, for any number of strata in which no stratum
|||     reads what a later one derives. `llog_2_5__stratified_compose` is
|||     the two-strata case; this is the one the per-stratum mechanism runs.
|||   * A SELF-FREE STRATUM IS RANKED (`iret_12_3__self_free_ranked`): when
|||     no justification of a stratum reads a fact the stratum derives --
|||     what [LCYC.3.1.1] makes of every SCC -- its support is
|||     acyclic, so the refcount is exact on it (`iret_12_3__ranked_agree`).
|||   * THE HYBRID IS EXACT (`llog_2_5__hybrid_exact`): processing the strata
|||     in order, recomputing the recursive ones and running the refcount
|||     cascade on the self-free ones, yields exactly the global
|||     well-founded set, whenever the well-founded facts are live -- which
|||     at a boundary they are (`llog_2_5__boundary_unfounded`). So the
|||     recompute can be confined to the strata `+recursive` admits, and
|||     everything else keeps `justif_count` (the recommendation's step 3).
|||   * Executed (`llog_2_5__hybrid_mixed_*`): a recursive stratum seeded
|||     from outside with a self-free stratum on top; the seed withdrawn,
|||     the hybrid retracts all three facts and the refcount keeps them.
|||
||| SCOPE. The abstract model, as Rete/Refcount.idr: the engine-level step
||| is Rete/RecomputeDiff.idr / Rete/RecomputeFire.idr, which recompute
||| every stratum at once; this module is what licenses recomputing fewer.
module Rete.RecomputeStrata

import Rete.Refcount
import Lcyc.Lemmas
import Data.List
import Data.List.Elem
import Data.Nat

%default total

-- ---------------------------------------------------------------------
-- N strata
-- ---------------------------------------------------------------------

--@spec [LLOG.2.5]
||| Recompute stratum by stratum: each stratum's well-founded set over the
||| one below it becomes the next stratum's base.
public export
llog_2_5__strata_wf : List Iret_12__fact -> List (List Iret_12_1__justif) -> List Iret_12__fact -> List Iret_12__fact
llog_2_5__strata_wf base [] univ = llog_2_5__well_founded base [] univ
llog_2_5__strata_wf base (js :: jss) univ = llog_2_5__strata_wf (llog_2_5__well_founded base js univ) jss univ

--@spec [LLOG.2.5]
||| All the strata's justifications, the first stratum's first. By
||| structure, so that the strata after the first are `concat` of the rest.
public export
llog_2_5__all_strata : List (List Iret_12_1__justif) -> List Iret_12_1__justif
llog_2_5__all_strata [] = []
llog_2_5__all_strata (js :: jss) = js ++ llog_2_5__all_strata jss

--@spec [LLOG.2.5]
||| A list of strata in the SCC-DAG's order: no stratum reads what any
||| later one derives.
public export
Llog_2_5__stratified_list : List (List Iret_12_1__justif) -> Type
Llog_2_5__stratified_list [] = ()
Llog_2_5__stratified_list (js :: jss) = (Llog_2_5__stratified js (llog_2_5__all_strata jss), Llog_2_5__stratified_list jss)

--@derives [LLOG.2.5]
||| N STRATA COMPOSE: the stratum-by-stratum recompute is the global one,
||| both inclusions.
export
llog_2_5__strata_compose : (base : List Iret_12__fact) -> (jss : List (List Iret_12_1__justif)) -> (univ : List Iret_12__fact) ->
                           Llog_2_5__stratified_list jss ->
                           ( Iret_12__sub (llog_2_5__strata_wf base jss univ) (llog_2_5__well_founded base (llog_2_5__all_strata jss) univ)
                           , Iret_12__sub (llog_2_5__well_founded base (llog_2_5__all_strata jss) univ) (llog_2_5__strata_wf base jss univ) )
llog_2_5__strata_compose base [] univ () = (\t, e => e, \t, e => e)
llog_2_5__strata_compose base (js :: jss) univ (strat, rest) =
  let (globalToComp, compToGlobal) = llog_2_5__stratified_compose base js (llog_2_5__all_strata jss) univ strat
      (ihTo, ihFrom) = llog_2_5__strata_compose (llog_2_5__well_founded base js univ) jss univ rest
  in (\t, e => compToGlobal t (ihTo t e), \t, e => ihFrom t (globalToComp t e))

--@derives [LLOG.2.5]
||| A base fact of the universe survives every stratum.
export
llog_2_5__strata_base_in : (base : List Iret_12__fact) -> (jss : List (List Iret_12_1__justif)) -> (univ : List Iret_12__fact) ->
                           (t : Iret_12__fact) -> iret_12__elem t univ = True -> iret_12__elem t base = True ->
                           iret_12__elem t (llog_2_5__strata_wf base jss univ) = True
llog_2_5__strata_base_in base [] univ t tu tb = llog_2_5__base_in_wf base [] univ t tu tb
llog_2_5__strata_base_in base (js :: jss) univ t tu tb =
  llog_2_5__strata_base_in (llog_2_5__well_founded base js univ) jss univ t tu (llog_2_5__base_in_wf base js univ t tu tb)

--@derives [LLOG.2.5]
||| The well-founded set depends on the base only through its members in
||| the universe: `llog_2_5__wf_mono_base`, with the premise restricted to
||| the universe.
export
llog_2_5__wf_mono_base_univ : (base', base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ : List Iret_12__fact) ->
                              ((t : Iret_12__fact) -> iret_12__elem t univ = True -> iret_12__elem t base' = True -> iret_12__elem t base = True) ->
                              Iret_12__sub (llog_2_5__well_founded base' js univ) (llog_2_5__well_founded base js univ)
llog_2_5__wf_mono_base_univ base' base js univ sub =
  llog_2_5__wf_least base' js univ (llog_2_5__well_founded base js univ)
    (\t, ta, tb => llog_2_5__base_in_wf base js univ t ta (sub t ta tb))
    (\t, ta, ts => llog_2_5__wf_closed base js univ t ta ts)

-- ---------------------------------------------------------------------
-- A self-free stratum has acyclic support
-- ---------------------------------------------------------------------

--@spec [IRET.12.3]
||| No justification of the stratum reads a fact the stratum derives: the
||| shape [LCYC.3.1.1] gives every SCC it admits ("no schema both emitted
||| and matched by rules of the SCC").
public export
Iret_12_3__self_free : List Iret_12_1__justif -> Type
Iret_12_3__self_free js =
  (j, j' : Iret_12_1__justif) -> Elem j js -> Elem j' js -> (a : Iret_12__fact) -> Elem a (ante j') -> Not (target j = a)

--@spec [IRET.12.3]
||| The stratum's targets.
public export
iret_12_3__targets : List Iret_12_1__justif -> List Iret_12__fact
iret_12_3__targets js = map (\j => target j) js

--@derives [IRET.12.3]
||| Rank one for a fact the stratum derives, zero otherwise.
public export
iret_12_3__self_rank : List Iret_12_1__justif -> Iret_12__fact -> Nat
iret_12_3__self_rank js t = if iret_12__elem t (iret_12_3__targets js) then 1 else 0

--@derives [IRET.12.3]
export
iret_12_3__self_rank_target : (js : List Iret_12_1__justif) -> (j : Iret_12_1__justif) -> Elem j js -> iret_12_3__self_rank js (target j) = 1
iret_12_3__self_rank_target js j ej with (iret_12__elem (target j) (iret_12_3__targets js)) proof q
  iret_12_3__self_rank_target js j ej | True = Refl
  iret_12_3__self_rank_target js j ej | False =
    absurd (trans (sym q) (iret_12__elem_true (target j) (iret_12_3__targets js) (lcyc_1_1__elem_map_fwd (\x => target x) ej)))

--@derives [IRET.12.3]
export
iret_12_3__self_rank_ante : (js : List Iret_12_1__justif) -> Iret_12_3__self_free js ->
                            (j' : Iret_12_1__justif) -> Elem j' js -> (a : Iret_12__fact) -> Elem a (ante j') -> iret_12_3__self_rank js a = 0
iret_12_3__self_rank_ante js sf j' ej' a ea with (iret_12__elem a (iret_12_3__targets js)) proof q
  iret_12_3__self_rank_ante js sf j' ej' a ea | False = Refl
  iret_12_3__self_rank_ante js sf j' ej' a ea | True =
    let (j ** (ej, tj)) = lcyc_1_1__elem_map_inv (\x => target x) js (iret_12__elem_elem a (iret_12_3__targets js) q)
    in void (sf j j' ej ej' a ea tj)

--@derives [IRET.12.3]
||| A SELF-FREE STRATUM IS RANKED, so the refcount is exact on it.
export
iret_12_3__self_free_ranked : (js : List Iret_12_1__justif) -> Iret_12_3__self_free js -> Iret_12_3__ranked (\t => iret_12_3__self_rank js t) js
iret_12_3__self_free_ranked js sf j ej a ea =
  rewrite iret_12_3__self_rank_ante js sf j ej a ea in
  rewrite iret_12_3__self_rank_target js j ej in
  LTESucc LTEZero

-- ---------------------------------------------------------------------
-- The hybrid
-- ---------------------------------------------------------------------

--@gap
||| The strata in order, each marked recursive (`True`) or not, from the
||| facts live before: a recursive stratum is recomputed over its input; a
||| non-recursive one keeps the refcount cascade over the live facts with
||| its input as base.
public export
gap__hybrid : List Iret_12__fact -> List (Bool, List Iret_12_1__justif) -> List Iret_12__fact -> List Iret_12__fact -> List Iret_12__fact
gap__hybrid b [] univ live = llog_2_5__well_founded b [] univ
gap__hybrid b ((True, js) :: rest) univ live = gap__hybrid (llog_2_5__well_founded b js univ) rest univ live
gap__hybrid b ((False, js) :: rest) univ live = gap__hybrid (iret_12_2__cascade b js live) rest univ live

--@gap
||| What the hybrid needs of the strata it keeps the refcount on: each is
||| self-free.
public export
Gap__hybrid_ok : List (Bool, List Iret_12_1__justif) -> Type
Gap__hybrid_ok [] = ()
Gap__hybrid_ok ((True, js) :: rest) = Gap__hybrid_ok rest
Gap__hybrid_ok ((False, js) :: rest) = (Iret_12_3__self_free js, Gap__hybrid_ok rest)

--@gap
||| The strata without their marks.
public export
gap__hybrid_strata : List (Bool, List Iret_12_1__justif) -> List (List Iret_12_1__justif)
gap__hybrid_strata sjs = map snd sjs

--@derives [LLOG.2.5]
||| Stratum by stratum, the hybrid from a base agrees with the recompute
||| from any base with the same members in the universe, provided the
||| recompute's facts are live and the live facts lie in the universe. A
||| recursive stratum is a recompute on both sides; a self-free one is the
||| cascade, exact there because it is ranked.
export
llog_2_5__hybrid_agrees : (sjs : List (Bool, List Iret_12_1__justif)) -> Gap__hybrid_ok sjs ->
                          (b, b' : List Iret_12__fact) -> (univ, live : List Iret_12__fact) ->
                          ((t : Iret_12__fact) -> iret_12__elem t univ = True -> iret_12__elem t b = True -> iret_12__elem t b' = True) ->
                          ((t : Iret_12__fact) -> iret_12__elem t univ = True -> iret_12__elem t b' = True -> iret_12__elem t b = True) ->
                          Iret_12__sub live univ ->
                          Iret_12__sub (llog_2_5__strata_wf b' (gap__hybrid_strata sjs) univ) live ->
                          ( Iret_12__sub (gap__hybrid b sjs univ live) (llog_2_5__strata_wf b' (gap__hybrid_strata sjs) univ)
                          , Iret_12__sub (llog_2_5__strata_wf b' (gap__hybrid_strata sjs) univ) (gap__hybrid b sjs univ live) )
llog_2_5__hybrid_agrees [] ok b b' univ live bb' b'b liveU wLive =
  (llog_2_5__wf_mono_base_univ b b' [] univ bb', llog_2_5__wf_mono_base_univ b' b [] univ b'b)
llog_2_5__hybrid_agrees ((True, js) :: rest) ok b b' univ live bb' b'b liveU wLive =
  llog_2_5__hybrid_agrees rest ok (llog_2_5__well_founded b js univ) (llog_2_5__well_founded b' js univ) univ live
    (\t, tu, tw => llog_2_5__wf_mono_base_univ b b' js univ bb' t tw)
    (\t, tu, tw => llog_2_5__wf_mono_base_univ b' b js univ b'b t tw)
    liveU wLive
llog_2_5__hybrid_agrees ((False, js) :: rest) (sf, ok) b b' univ live bb' b'b liveU wLive =
  let wbIn : Iret_12__sub (llog_2_5__well_founded b js univ) live
      wbIn t tw = wLive t (llog_2_5__strata_base_in (llog_2_5__well_founded b' js univ) (gap__hybrid_strata rest) univ t
                            (llog_2_5__wf_sub_all b js univ t tw)
                            (llog_2_5__wf_mono_base_univ b b' js univ bb' t tw))
  in let (cw, wc) = iret_12_3__ranked_agree (\t => iret_12_3__self_rank js t) b js univ live (iret_12_3__self_free_ranked js sf) liveU wbIn
  in llog_2_5__hybrid_agrees rest ok (iret_12_2__cascade b js live) (llog_2_5__well_founded b' js univ) univ live
       (\t, tu, tc => llog_2_5__wf_mono_base_univ b b' js univ bb' t (cw t tc))
       (\t, tu, tw => wc t (llog_2_5__wf_mono_base_univ b' b js univ b'b t tw))
       liveU wLive

--@derives [LLOG.2.5]
||| THE HYBRID IS EXACT. Strata in the SCC-DAG's order, the recursive ones
||| recomputed and the self-free ones kept by the refcount cascade: the
||| result is exactly the global well-founded set, whenever the
||| well-founded facts are live and the live facts lie in the universe --
||| as at every boundary (`llog_2_5__boundary_unfounded`). The recompute
||| can be confined to the recursive strata.
export
llog_2_5__hybrid_exact : (sjs : List (Bool, List Iret_12_1__justif)) -> Gap__hybrid_ok sjs -> Llog_2_5__stratified_list (gap__hybrid_strata sjs) ->
                         (base, univ, live : List Iret_12__fact) -> Iret_12__sub live univ ->
                         Iret_12__sub (llog_2_5__well_founded base (llog_2_5__all_strata (gap__hybrid_strata sjs)) univ) live ->
                         ( Iret_12__sub (gap__hybrid base sjs univ live) (llog_2_5__well_founded base (llog_2_5__all_strata (gap__hybrid_strata sjs)) univ)
                         , Iret_12__sub (llog_2_5__well_founded base (llog_2_5__all_strata (gap__hybrid_strata sjs)) univ) (gap__hybrid base sjs univ live) )
llog_2_5__hybrid_exact sjs ok strat base univ live liveU wfLive =
  let (sToG, gToS) = llog_2_5__strata_compose base (gap__hybrid_strata sjs) univ strat
      (hToS, sToH) = llog_2_5__hybrid_agrees sjs ok base base univ live (\t, _, e => e) (\t, _, e => e) liveU (\t, e => wfLive t (sToG t e))
  in (\t, e => sToG t (hToS t e), \t, e => sToH t (gToS t e))

-- ---------------------------------------------------------------------
-- Executed: a recursive stratum under a self-free one
-- ---------------------------------------------------------------------

--@spec [LLOG.2.5]
||| The strata: below, Rete/Refcount.idr's recursive pair seeded by 10
||| (10 -> 1; 1 -> 2; 2 -> 1), written out so it unfolds here; above,
||| 1 -> 5, reading the lower stratum's fact and deriving nothing it
||| reads -- self-free.
public export
llog_2_5__hybrid_strata : List (Bool, List Iret_12_1__justif)
llog_2_5__hybrid_strata = [(True, [MkJustif [10] 1, MkJustif [1] 2, MkJustif [2] 1]), (False, [MkJustif [1] 5])]

--@derives [LLOG.2.5]
||| With the seed 10: all four live under the hybrid.
export
llog_2_5__hybrid_mixed_before : gap__hybrid [10] Rete.RecomputeStrata.llog_2_5__hybrid_strata [10, 1, 2, 5] [10, 1, 2, 5] = [10, 1, 2, 5]
llog_2_5__hybrid_mixed_before = Refl

--@derives [LLOG.2.5]
||| The seed withdrawn: the hybrid recomputes the recursive stratum to
||| nothing, and the refcount cascade on the self-free stratum then
||| retracts 5 -- all three facts gone, as [LLOG.2.5] requires.
export
llog_2_5__hybrid_mixed_after : gap__hybrid [] Rete.RecomputeStrata.llog_2_5__hybrid_strata [1, 2, 5] [1, 2, 5] = []
llog_2_5__hybrid_mixed_after = Refl

--@derives [IRET.12.2]
||| While the refcount over both strata keeps all three: 1 and 2 hold each
||| other up, and 1 holds 5.
export
iret_12_2__hybrid_mixed_refcount :
  iret_12_2__cascade [] (llog_2_5__all_strata (gap__hybrid_strata Rete.RecomputeStrata.llog_2_5__hybrid_strata)) [1, 2, 5] = [1, 2, 5]
iret_12_2__hybrid_mixed_refcount = Refl

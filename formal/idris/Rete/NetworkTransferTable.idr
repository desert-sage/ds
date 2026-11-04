-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE TRANSFER, PART TWO (ii): FIRELOOP'S TABLES ARE IN THE KEY'S ORDER.
||| Rete/FireLoop.idr re-propagates a rule after a change of working
||| memory by keeping the tokens whose tuple still matches, in place, and
||| appending the new matches in enumeration order ([IRET.8.1]). This
||| module proves that every table so built is sorted by the canonical
||| key of [LDET.5.5] under the working memory it was built for, holds
||| live facts only, and stays so through marking; and that the
||| FireLoop state reached by any history -- inputs applied without the
||| TMS phase, each pumped -- is well-formed: working memory distinct,
||| ids unique ([IRET.4.4]), every table sorted and settled. With
||| Rete/NetworkTransferOrder.idr's uniqueness of sorted lists and
||| Rete/NetworkAgree.idr's agreement of the two recomputes, the
||| network's terminals and FireLoop's unblocked tokens are then the same
||| lists.
module Rete.NetworkTransferTable

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
import Rete.NetworkTransferOrder
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
-- Tuples of a table
-- ---------------------------------------------------------------------

--@spec [IRET.11.3]
||| The tuples of a table, in table order; named so that no statement
||| mentions a projection unapplied.
public export
iret_11_3__tuples_of : List Iret_11__tok -> List Iret_7_1__token
iret_11_3__tuples_of ts = map tfacts ts

--@derives [IRET.11.3]
export
iret_11_3__tuples_of_append : (xs, ys : List Iret_11__tok) -> iret_11_3__tuples_of (xs ++ ys) = iret_11_3__tuples_of xs ++ iret_11_3__tuples_of ys
iret_11_3__tuples_of_append [] ys = Refl
iret_11_3__tuples_of_append (x :: xs) ys = cong (tfacts x ::) (iret_11_3__tuples_of_append xs ys)

--@derives [LDET.5.9]
||| Refreshing a token's flags leaves its tuple.
export
ldet_5_9__refresh_tuples : (r : Lgra_6_1__rule) -> (nf : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) ->
                           iret_11_3__tuples_of (map (ldet_5_9__refresh_tok r nf) ts) = iret_11_3__tuples_of ts
ldet_5_9__refresh_tuples r nf [] = Refl
ldet_5_9__refresh_tuples r nf (t :: ts) = cong (tfacts t ::) (ldet_5_9__refresh_tuples r nf ts)

--@derives [IRET.8.1]
||| Fresh tokens for a list of tuples; named so that no statement
||| mentions the token builder unapplied.
public export
iret_8_1__fresh_toks : List Iret_7_1__token -> List Iret_11__tok
iret_8_1__fresh_toks fss = map iret_8_1__fresh_tok fss

--@derives [IRET.8.1]
export
iret_8_1__fresh_tuples : (fss : List Iret_7_1__token) -> iret_11_3__tuples_of (iret_8_1__fresh_toks fss) = fss
iret_8_1__fresh_tuples [] = Refl
iret_8_1__fresh_tuples (fs :: fss) = cong (fs ::) (iret_8_1__fresh_tuples fss)

--@derives [IRET.8.1]
||| The added tokens' tuples: the current matches not yet held, in
||| enumeration order.
export
iret_8_1__added_tuples : (now : List Iret_7_1__token) -> (old : List Iret_11__tok) ->
                         iret_11_3__tuples_of (iret_8_1__added_of now old)
                           = filter (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) now
iret_8_1__added_tuples now old = iret_8_1__fresh_tuples _

--@derives [LDET.5.5]
||| The tuples of a sublist of tokens, taken by a test, stay sorted.
export
ldet_5_5__sorted_tuples_of_filter : (wm : Rarc_5_6_4__wm) -> (p : Iret_11__tok -> Bool) -> (ts : List Iret_11__tok) ->
                                    Ldet_5_5__sorted_tuples wm (iret_11_3__tuples_of ts) -> Ldet_5_5__sorted_tuples wm (iret_11_3__tuples_of (filter p ts))
ldet_5_5__sorted_tuples_of_filter wm p [] s = s
ldet_5_5__sorted_tuples_of_filter wm p (t :: ts) (STCons al s) with (p t)
  ldet_5_5__sorted_tuples_of_filter wm p (t :: ts) (STCons al s) | True =
    STCons (lcyc_1_1__all_from_elem (iret_11_3__tuples_of (filter p ts)) (\t', e =>
              let (x ** (ex, xeq)) = lcyc_1_1__elem_map_inv tfacts (filter p ts) e
              in lcyc_1_1__all_lookup al (replace {p = \z => Elem z (map tfacts ts)} xeq (lcyc_1_1__elem_map_fwd tfacts (fst (lcyc_1_1__elem_filter_inv p ts ex))))))
           (ldet_5_5__sorted_tuples_of_filter wm p ts s)
  ldet_5_5__sorted_tuples_of_filter wm p (t :: ts) (STCons al s) | False = ldet_5_5__sorted_tuples_of_filter wm p ts s

-- ---------------------------------------------------------------------
-- Ids identify facts within one change
-- ---------------------------------------------------------------------

--@derives [IRET.4.4]
--@derives [LFAC.2.5.3]
||| Within one change of working memory a fact's id identifies it: two
||| lists of facts, one live before the change and one live after, with
||| the same ids, are the same list -- every fact after is a fact before
||| or carries an id that was not live.
export
iret_4_4__ids_identify : (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (wm' : Rarc_5_6_4__wm) ->
                         ((g : Lfac_1_7_1__fact) -> Elem g wm' -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)) ->
                         (xs, ys : List Lfac_1_7_1__fact) -> All (\g => Elem g wm) xs -> All (\g => Elem g wm') ys ->
                         iret_11_3__fact_ids xs = iret_11_3__fact_ids ys -> xs = ys
iret_4_4__ids_identify wm uq wm' mixed [] [] _ _ _ = Refl
iret_4_4__ids_identify wm uq wm' mixed [] (y :: ys) _ _ eq = absurd eq
iret_4_4__ids_identify wm uq wm' mixed (x :: xs) [] _ _ eq = absurd eq
iret_4_4__ids_identify wm uq wm' mixed (x :: xs) (y :: ys) (lx :: lxs) (ly :: lys) eq =
  let (hd, tl) = consInjective eq
      xy : (x = y)
      xy = case mixed y ly of
             Left ey => uq x y lx ey hd
             Right nl => absurd (trans (sym (replace {p = \i => rarc_5_6_4__is_live i wm = True} hd (rarc_5_6_4__is_live_of x wm lx))) nl)
  in cong2 (::) xy (iret_4_4__ids_identify wm uq wm' mixed xs ys lxs lys tl)

--@derives [IRET.8.1]
--@derives [IRET.4.4]
||| A kept token's facts are live afterwards: its ids are a current
||| match's, and ids identify facts.
export
iret_8_1__kept_live : (r : Lgra_6_1__rule) -> (wm, wm' : Rarc_5_6_4__wm) -> Iret_4_4__unique wm ->
                      ((g : Lfac_1_7_1__fact) -> Elem g wm' -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)) ->
                      (old : List Iret_11__tok) -> All (\t => Ldet_5_5__live wm (tfacts t)) old ->
                      (t : Iret_11__tok) -> Elem t (iret_8_1__kept_of (iret_7_4__match_tuples r wm') old) -> Ldet_5_5__live wm' (tfacts t)
iret_8_1__kept_live r wm wm' uq mixed old lv t e =
  let (eo, inNow) = lcyc_1_1__elem_filter_inv (\u => rarc_5_6_5__elem (iret_11_3__ids u) (iret_11_3__now_ids (iret_7_4__match_tuples r wm'))) old e
      (fs ** (efs, idsEq)) = lcyc_1_1__elem_map_inv iret_11_3__fact_ids (iret_7_4__match_tuples r wm') (lcyc_1_1__elem_ll_elem _ _ inNow)
      lfs : All (\g => Elem g wm') fs
      lfs = lcyc_1_1__all_lookup (iret_7_4__tuples_live (posKinds r) wm') (fst (lcyc_1_1__elem_filter_inv (guard r) (iret_7_4__tuples (posKinds r) wm') efs))
      same : (tfacts t = fs)
      same = iret_4_4__ids_identify wm uq wm' mixed (tfacts t) fs (lcyc_1_1__all_lookup lv eo) lfs (sym idsEq)
  in replace {p = \z => Ldet_5_5__live wm' z} (sym same) lfs

--@derives [IRET.8.1]
||| After a change that adds no fact nothing is added: every current
||| match was a match before, and held.
export
iret_8_1__added_none : (r : Lgra_6_1__rule) -> (wm, wm' : Rarc_5_6_4__wm) -> ((g : Lfac_1_7_1__fact) -> Elem g wm' -> Elem g wm) ->
                       (old : List Iret_11__tok) -> Iret_8_1__settled r (iret_7_4__match_tuples r wm) (iret_7_9__neg_facts r wm) old ->
                       iret_8_1__added_of (iret_7_4__match_tuples r wm') old = []
iret_8_1__added_none r wm wm' sub old (_, allNow) =
  cong (map iret_8_1__fresh_tok)
    (lcyc_1_1__filter_all_false (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) (iret_7_4__match_tuples r wm')
      (lcyc_1_1__all_from_elem _ (\fs, efs =>
         let lfs = lcyc_1_1__all_lookup (iret_7_4__tuples_live (posKinds r) wm') (fst (lcyc_1_1__elem_filter_inv (guard r) (iret_7_4__tuples (posKinds r) wm') efs))
             inOld = lcyc_1_1__all_lookup allNow (iret_7_4__match_sub r wm wm' fs efs (lcyc_1_1__all_imp fs (\g, eg => sub g eg) lfs))
         in cong not inOld)))

--@derives [IRET.8.1]
||| After a change that adds one fact, every added token holds it.
export
iret_8_1__added_holds_new : (r : Lgra_6_1__rule) -> (wm, base : Rarc_5_6_4__wm) -> ((g : Lfac_1_7_1__fact) -> Elem g base -> Elem g wm) ->
                            (new : Lfac_1_7_1__fact) -> (old : List Iret_11__tok) ->
                            Iret_8_1__settled r (iret_7_4__match_tuples r wm) (iret_7_9__neg_facts r wm) old ->
                            (fs : Iret_7_1__token) -> Elem fs (iret_7_4__match_tuples r (base ++ [new])) ->
                            rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old) = False -> Elem new fs
iret_8_1__added_holds_new r wm base sub new old (_, allNow) fs efs notOld with (rarc_5_6_5__elem new fs) proof en
  iret_8_1__added_holds_new r wm base sub new old (_, allNow) fs efs notOld | True = lcyc_1_1__elem_l_elem_by lfac_2_5_4__same_fact_eq new fs en
  iret_8_1__added_holds_new r wm base sub new old (_, allNow) fs efs notOld | False =
    let lfs = lcyc_1_1__all_lookup (iret_7_4__tuples_live (posKinds r) (base ++ [new])) (fst (lcyc_1_1__elem_filter_inv (guard r) (iret_7_4__tuples (posKinds r) (base ++ [new])) efs))
        lbase : All (\g => Elem g wm) fs
        lbase = lcyc_1_1__all_from_elem fs (\g, eg => case lcyc_1_1__elem_append_inv base (lcyc_1_1__all_lookup lfs eg) of
                  Left eb => sub g eb
                  Right e1 => absurd (trans (sym (lcyc_1_1__elem_l_true_by lfac_2_5_4__same_fact_refl new fs (replace {p = \z => Elem z fs} (iret_12__elem_singleton e1) eg))) en))
    in absurd (trans (sym (lcyc_1_1__all_lookup allNow (iret_7_4__match_sub r wm (base ++ [new]) fs efs lbase))) notOld)

-- ---------------------------------------------------------------------
-- Where a new match sits
-- ---------------------------------------------------------------------

--@derives [LDET.5.5]
--@derives [IRET.8.1]
||| A tuple holding the new fact, live in the grown memory, completed at
||| the new fact's position: the last.
export
iret_8_1__new_latest : (base : Rarc_5_6_4__wm) -> (new : Lfac_1_7_1__fact) -> Not (Elem new base) ->
                       (fs : Iret_7_1__token) -> All (\g => Elem g (base ++ [new])) fs -> Elem new fs ->
                       ldet_5_5__latest (ldet_5_5__key (base ++ [new]) fs) = length base
iret_8_1__new_latest base new nn fs lfs en =
  let pk : (ldet_5_5__pos (base ++ [new]) new = length base)
      pk = ldet_5_5__pos_last base new nn
      inKey : Elem (length base) (ldet_5_5__key (base ++ [new]) fs)
      inKey = replace {p = \z => Elem z (ldet_5_5__key (base ++ [new]) fs)} pk (lcyc_1_1__elem_map_fwd (ldet_5_5__pos (base ++ [new])) en)
      bound : All (\x => ldet_5_5__lt (length base) x = False) (ldet_5_5__key (base ++ [new]) fs)
      bound = lcyc_1_1__all_map (ldet_5_5__pos (base ++ [new])) (lcyc_1_1__all_imp fs (\g, eg =>
                ldet_5_5__lt_succ_not (ldet_5_5__pos (base ++ [new]) g) (length base)
                  (replace {p = \n => ldet_5_5__lt (ldet_5_5__pos (base ++ [new]) g) n = True} (iret_7_9_1__length_snoc base new)
                     (ldet_5_5__pos_lt_length (base ++ [new]) g eg))) lfs)
  in ldet_5_5__latest_of_bound (length base) (ldet_5_5__key (base ++ [new]) fs) inKey bound

--@derives [IRET.8.1]
--@derives [LDET.5.5]
||| The nil match comes before every match of a fact.
export
iret_8_1__nil_before : (wm : Rarc_5_6_4__wm) -> (k, a : Iret_7_1__token) -> ldet_5_5__key wm k = [] -> (new : Lfac_1_7_1__fact) -> Elem new a ->
                       ldet_5_5__before wm k a = True
iret_8_1__nil_before wm k [] nil new en = absurd en
iret_8_1__nil_before wm k (h :: t) nil new en = rewrite nil in ldet_5_5__before_nil (ldet_5_5__pos wm h) (ldet_5_5__key wm t)

--@derives [LDET.5.5]
--@derives [IRET.8.1]
||| A match live in the old memory comes before a match the new fact
||| completes.
export
iret_8_1__old_before_new : (base : Rarc_5_6_4__wm) -> (new : Lfac_1_7_1__fact) -> Not (Elem new base) ->
                           (k : Iret_7_1__token) -> Ldet_5_5__live base k -> (a : Iret_7_1__token) -> All (\g => Elem g (base ++ [new])) a -> Elem new a ->
                           ldet_5_5__before (base ++ [new]) k a = True
iret_8_1__old_before_new base new nn k lk a la en =
  let below : All (\x => ldet_5_5__lt x (length base) = True) (ldet_5_5__key (base ++ [new]) k)
      below = lcyc_1_1__all_map (ldet_5_5__pos (base ++ [new])) (lcyc_1_1__all_imp k (\g, eg =>
                replace {p = \n => ldet_5_5__lt n (length base) = True} (sym (ldet_5_5__pos_append base new g eg)) (ldet_5_5__pos_lt_length base g eg)) lk)
      latA : (ldet_5_5__latest (ldet_5_5__key (base ++ [new]) a) = length base)
      latA = iret_8_1__new_latest base new nn a la en
  in case ldet_5_5__latest_below (length base) (ldet_5_5__key (base ++ [new]) k) below of
       Left nil => iret_8_1__nil_before (base ++ [new]) k a nil new en
       Right lt => ldet_5_5__before_keys_lt (ldet_5_5__key (base ++ [new]) k) (ldet_5_5__key (base ++ [new]) a)
                     (replace {p = \z => ldet_5_5__lt (ldet_5_5__latest (ldet_5_5__key (base ++ [new]) k)) z = True} (sym latA) lt)

-- ---------------------------------------------------------------------
-- The well-formed table
-- ---------------------------------------------------------------------

--@spec [IRET.8.1]
--@spec [LDET.5.5]
||| A WELL-FORMED TABLE of Rete/FireLoop.idr: every token's facts live,
||| and the tuples in the key's order.
public export
Iret_8_1__well : Rarc_5_6_4__wm -> List Iret_11__tok -> Type
Iret_8_1__well wm ts = (All (\t => Ldet_5_5__live wm (tfacts t)) ts, Ldet_5_5__sorted_tuples wm (iret_11_3__tuples_of ts))

--@derives [IRET.8.1]
--@derives [LDET.5.9]
||| Refreshing flags keeps a table well-formed.
export
iret_8_1__refresh_well : (wm : Rarc_5_6_4__wm) -> (r : Lgra_6_1__rule) -> (nf : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) ->
                         Iret_8_1__well wm ts -> Iret_8_1__well wm (map (ldet_5_9__refresh_tok r nf) ts)
iret_8_1__refresh_well wm r nf ts (lv, so) =
  ( lcyc_1_1__all_map (ldet_5_9__refresh_tok r nf) (lcyc_1_1__all_imp ts (\t, h => h) lv)
  , replace {p = \z => Ldet_5_5__sorted_tuples wm z} (sym (ldet_5_9__refresh_tuples r nf ts)) so )

--@derives [IDAT.6.2.2]
||| Marking a token fired keeps a table well-formed.
export
idat_6_2_2__mark_well : (wm : Rarc_5_6_4__wm) -> (j : Nat) -> (ts : List Iret_11__tok) -> Iret_8_1__well wm ts -> Iret_8_1__well wm (idat_6_2_2__mark_at j ts)
idat_6_2_2__mark_well wm j ts (lv, so) =
  ( lcyc_1_1__all_set_at idat_6_2_2__mark_t (\t, h => h) j ts lv
  , replace {p = \z => Ldet_5_5__sorted_tuples wm z} (sym (lcyc_1_1__map_set_at idat_6_2_2__mark_t tfacts (\t => Refl) j ts)) so )

--@derives [IRET.8.1]
||| The kept tokens stay well-formed under any memory in which they are
||| live and ordered as before.
export
iret_8_1__kept_well : (wm, wm' : Rarc_5_6_4__wm) -> (now : List Iret_7_1__token) -> (old : List Iret_11__tok) -> Iret_8_1__well wm old ->
                      ((t : Iret_11__tok) -> Elem t (iret_8_1__kept_of now old) -> Ldet_5_5__live wm' (tfacts t)) ->
                      ((s, t : Iret_7_1__token) -> Ldet_5_5__live wm s -> Ldet_5_5__live wm t -> Ldet_5_5__live wm' s -> Ldet_5_5__live wm' t ->
                       ldet_5_5__before wm' s t = ldet_5_5__before wm s t) ->
                      Iret_8_1__well wm' (iret_8_1__kept_of now old)
iret_8_1__kept_well wm wm' now old (lv, so) keptLive same =
  ( lcyc_1_1__all_from_elem _ keptLive
  , ldet_5_5__sorted_tuples_transport wm wm' _ (\s, t, es, et =>
      let (x ** (ex, xeq)) = lcyc_1_1__elem_map_inv tfacts (iret_8_1__kept_of now old) es
          (y ** (ey, yeq)) = lcyc_1_1__elem_map_inv tfacts (iret_8_1__kept_of now old) et
          ox : Elem x old
          ox = fst (lcyc_1_1__elem_filter_inv (\u => rarc_5_6_5__elem (iret_11_3__ids u) (iret_11_3__now_ids now)) old ex)
          oy : Elem y old
          oy = fst (lcyc_1_1__elem_filter_inv (\u => rarc_5_6_5__elem (iret_11_3__ids u) (iret_11_3__now_ids now)) old ey)
      in same s t (replace {p = \z => Ldet_5_5__live wm z} xeq (lcyc_1_1__all_lookup lv ox))
                  (replace {p = \z => Ldet_5_5__live wm z} yeq (lcyc_1_1__all_lookup lv oy))
                  (replace {p = \z => Ldet_5_5__live wm' z} xeq (keptLive x ex))
                  (replace {p = \z => Ldet_5_5__live wm' z} yeq (keptLive y ey)))
      (ldet_5_5__sorted_tuples_of_filter wm _ old so) )

--@derives [IRET.8.1]
--@derives [LDET.5.5]
--@derives [IRET.4.4]
||| PROPAGATION AFTER A FACT ENTERS keeps the table well-formed: the kept
||| tokens keep their order under the grown memory; the added tokens,
||| all completed at the new fact's position, follow them in pattern
||| order. `base` is the memory the fact is appended to -- working memory
||| itself, or working memory less the entity the fact replaces.
export
iret_8_1__prop_well_grow : (r : Lgra_6_1__rule) -> (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm ->
                           (base : Rarc_5_6_4__wm) -> Iret_11_3__distinct base -> ((g : Lfac_1_7_1__fact) -> Elem g base -> Elem g wm) ->
                           ((s, t : Iret_7_1__token) -> Ldet_5_5__live wm s -> Ldet_5_5__live wm t -> Ldet_5_5__live base s -> Ldet_5_5__live base t ->
                            ldet_5_5__before base s t = ldet_5_5__before wm s t) ->
                           (new : Lfac_1_7_1__fact) -> rarc_5_6_4__is_live (fid new) wm = False ->
                           (old : List Iret_11__tok) -> Iret_8_1__well wm old -> Iret_8_1__settled r (iret_7_4__match_tuples r wm) (iret_7_9__neg_facts r wm) old ->
                           Iret_8_1__well (base ++ [new]) (rarc_5_6_5__prop_rule r (base ++ [new]) old)
iret_8_1__prop_well_grow r wm uq base dbase sub same new fresh old (lv, so) stl =
  let nnw : Not (Elem new wm)
      nnw = \e => lcyc_1_1__bool_not_both _ (rarc_5_6_4__is_live_of new wm e) fresh
      nn : Not (Elem new base)
      nn = \e => nnw (sub new e)
      dw' : Iret_11_3__distinct (base ++ [new])
      dw' = iret_11_3__distinct_append base [new] dbase (DCons (\e => absurd e) DNil)
              (\x, ex, e => nn (replace {p = \z => Elem z base} (iret_12__elem_singleton e) ex))
      mixed : (g : Lfac_1_7_1__fact) -> Elem g (base ++ [new]) -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False)
      mixed = \g, e => case lcyc_1_1__elem_append_inv base e of
                Left eb => Left (sub g eb)
                Right e1 => Right (replace {p = \z => rarc_5_6_4__is_live (fid z) wm = False} (sym (iret_12__elem_singleton e1)) fresh)
      toBase : (g : Lfac_1_7_1__fact) -> Elem g wm -> Elem g (base ++ [new]) -> Elem g base
      toBase = \g, ew, e => case lcyc_1_1__elem_append_inv base e of
                 Left eb => eb
                 Right e1 => void (nnw (replace {p = \z => Elem z wm} (iret_12__elem_singleton e1) ew))
      keptLive : (t : Iret_11__tok) -> Elem t (iret_8_1__kept_of (iret_7_4__match_tuples r (base ++ [new])) old) -> Ldet_5_5__live (base ++ [new]) (tfacts t)
      keptLive = iret_8_1__kept_live r wm (base ++ [new]) uq mixed old lv
      liveBase : (s : Iret_7_1__token) -> Ldet_5_5__live wm s -> Ldet_5_5__live (base ++ [new]) s -> Ldet_5_5__live base s
      liveBase = \s, lw, lw' => lcyc_1_1__all_from_elem s (\g, eg => toBase g (lcyc_1_1__all_lookup lw eg) (lcyc_1_1__all_lookup lw' eg))
      sameOrder : (s, t : Iret_7_1__token) -> Ldet_5_5__live wm s -> Ldet_5_5__live wm t -> Ldet_5_5__live (base ++ [new]) s -> Ldet_5_5__live (base ++ [new]) t ->
                  ldet_5_5__before (base ++ [new]) s t = ldet_5_5__before wm s t
      sameOrder = \s, t, ls, lt, ls', lt' =>
                    trans (ldet_5_5__before_append base new s t (liveBase s ls ls') (liveBase t lt lt'))
                          (same s t ls lt (liveBase s ls ls') (liveBase t lt lt'))
      keptWell : Iret_8_1__well (base ++ [new]) (iret_8_1__kept_of (iret_7_4__match_tuples r (base ++ [new])) old)
      keptWell = iret_8_1__kept_well wm (base ++ [new]) (iret_7_4__match_tuples r (base ++ [new])) old (lv, so) keptLive sameOrder
      addedLiveT : (fs : Iret_7_1__token) -> Elem fs (iret_7_4__match_tuples r (base ++ [new])) -> All (\g => Elem g (base ++ [new])) fs
      addedLiveT = \fs, efs => lcyc_1_1__all_lookup (iret_7_4__tuples_live (posKinds r) (base ++ [new]))
                                 (fst (lcyc_1_1__elem_filter_inv (guard r) (iret_7_4__tuples (posKinds r) (base ++ [new])) efs))
      lexS : Ldet_5_5__lex_sorted (base ++ [new])
               (filter (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) (iret_7_4__match_tuples r (base ++ [new])))
      lexS = ldet_5_5__lex_sorted_filter (base ++ [new]) _ _
               (ldet_5_5__lex_sorted_filter (base ++ [new]) (guard r) _ (iret_7_4__tuples_lex_sorted (base ++ [new]) dw' (posKinds r)))
      allLatest : All (\t => ldet_5_5__latest (ldet_5_5__key (base ++ [new]) t) = length base)
                      (filter (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) (iret_7_4__match_tuples r (base ++ [new])))
      allLatest = lcyc_1_1__all_from_elem _ (\fs, e =>
                    let (efs, qfs) = lcyc_1_1__elem_filter_inv (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) (iret_7_4__match_tuples r (base ++ [new])) e
                    in iret_8_1__new_latest base new nn fs (addedLiveT fs efs)
                         (iret_8_1__added_holds_new r wm base sub new old stl fs efs (lcyc_1_1__not_true_is_false _ qfs)))
      addedSorted : Ldet_5_5__sorted_tuples (base ++ [new]) (iret_11_3__tuples_of (iret_8_1__added_of (iret_7_4__match_tuples r (base ++ [new])) old))
      addedSorted = replace {p = \z => Ldet_5_5__sorted_tuples (base ++ [new]) z} (sym (iret_8_1__added_tuples _ old))
                      (ldet_5_5__lex_to_sorted (base ++ [new]) (length base) _ allLatest lexS)
      addedLive : All (\t => Ldet_5_5__live (base ++ [new]) (tfacts t)) (iret_8_1__added_of (iret_7_4__match_tuples r (base ++ [new])) old)
      addedLive = lcyc_1_1__all_from_elem _ (\t, e =>
                    let (fs ** (efs', teq)) = lcyc_1_1__elem_map_inv iret_8_1__fresh_tok _ e
                        (efs, _) = lcyc_1_1__elem_filter_inv (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) (iret_7_4__match_tuples r (base ++ [new])) efs'
                    in replace {p = \z => Ldet_5_5__live (base ++ [new]) (tfacts z)} teq (addedLiveT fs efs))
      cross : (x : Iret_7_1__token) -> Elem x (iret_11_3__tuples_of (iret_8_1__kept_of (iret_7_4__match_tuples r (base ++ [new])) old)) ->
              (y : Iret_7_1__token) -> Elem y (iret_11_3__tuples_of (iret_8_1__added_of (iret_7_4__match_tuples r (base ++ [new])) old)) ->
              ldet_5_5__before (base ++ [new]) x y = True
      cross = \x, ex, y, ey =>
                let (tk ** (etk, xeq)) = lcyc_1_1__elem_map_inv tfacts _ ex
                    ok : Elem tk old
                    ok = fst (lcyc_1_1__elem_filter_inv (\u => rarc_5_6_5__elem (iret_11_3__ids u) (iret_11_3__now_ids (iret_7_4__match_tuples r (base ++ [new])))) old etk)
                    lbx : Ldet_5_5__live base x
                    lbx = liveBase x (replace {p = \z => Ldet_5_5__live wm z} xeq (lcyc_1_1__all_lookup lv ok))
                                     (replace {p = \z => Ldet_5_5__live (base ++ [new]) z} xeq (keptLive tk etk))
                    ey' : Elem y (filter (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) (iret_7_4__match_tuples r (base ++ [new])))
                    ey' = replace {p = \z => Elem y z} (iret_8_1__added_tuples _ old) ey
                in let (efy, qy) = lcyc_1_1__elem_filter_inv (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) (iret_7_4__match_tuples r (base ++ [new])) ey'
                   in iret_8_1__old_before_new base new nn x lbx y (addedLiveT y efy)
                        (iret_8_1__added_holds_new r wm base sub new old stl y efy (lcyc_1_1__not_true_is_false _ qy))
      bothWell : Iret_8_1__well (base ++ [new])
                   (iret_8_1__kept_of (iret_7_4__match_tuples r (base ++ [new])) old ++ iret_8_1__added_of (iret_7_4__match_tuples r (base ++ [new])) old)
      bothWell = ( lcyc_1_1__all_append (fst keptWell) addedLive
                 , replace {p = \z => Ldet_5_5__sorted_tuples (base ++ [new]) z} (sym (iret_11_3__tuples_of_append _ _))
                     (ldet_5_5__sorted_tuples_append (base ++ [new]) _ _ (snd keptWell) addedSorted cross) )
  in iret_8_1__refresh_well (base ++ [new]) r (iret_7_9__neg_facts r (base ++ [new])) _ bothWell

--@derives [IRET.8.1]
--@derives [LDET.5.9]
--@derives [IRET.4.4]
||| PROPAGATION AFTER A FACT LEAVES keeps the table well-formed: nothing
||| is added, and the survivors keep their order under the shrunk memory.
export
iret_8_1__prop_well_shrink : (r : Lgra_6_1__rule) -> (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> Iret_4_4__unique wm ->
                             (f : Lfac_1_7_1__fact) -> Elem f wm ->
                             (old : List Iret_11__tok) -> Iret_8_1__well wm old -> Iret_8_1__settled r (iret_7_4__match_tuples r wm) (iret_7_9__neg_facts r wm) old ->
                             Iret_8_1__well (rarc_5_6_4__remove_exact f wm) (rarc_5_6_5__prop_rule r (rarc_5_6_4__remove_exact f wm) old)
iret_8_1__prop_well_shrink r wm dw uq f ef old (lv, so) stl =
  let sub : (g : Lfac_1_7_1__fact) -> Elem g (rarc_5_6_4__remove_exact f wm) -> Elem g wm
      sub = \g, e => fst (rarc_5_6_4__remove_exact_elem_inv f wm g e)
      notF : (s : Iret_7_1__token) -> Ldet_5_5__live (rarc_5_6_4__remove_exact f wm) s -> Not (Elem f s)
      notF = \s, ls, e => snd (rarc_5_6_4__remove_exact_elem_inv f wm f (lcyc_1_1__all_lookup ls e)) Refl
      keptLive = iret_8_1__kept_live r wm (rarc_5_6_4__remove_exact f wm) uq (\g, e => Left (sub g e)) old lv
      sameOrder : (s, t : Iret_7_1__token) -> Ldet_5_5__live wm s -> Ldet_5_5__live wm t ->
                  Ldet_5_5__live (rarc_5_6_4__remove_exact f wm) s -> Ldet_5_5__live (rarc_5_6_4__remove_exact f wm) t ->
                  ldet_5_5__before (rarc_5_6_4__remove_exact f wm) s t = ldet_5_5__before wm s t
      sameOrder = \s, t, ls, lt, ls', lt' => ldet_5_9__before_remove wm dw f ef s t ls lt (notF s ls') (notF t lt')
      keptWell = iret_8_1__kept_well wm (rarc_5_6_4__remove_exact f wm) (iret_7_4__match_tuples r (rarc_5_6_4__remove_exact f wm)) old (lv, so) keptLive sameOrder
      noAdd : (iret_8_1__added_of (iret_7_4__match_tuples r (rarc_5_6_4__remove_exact f wm)) old = [])
      noAdd = iret_8_1__added_none r wm (rarc_5_6_4__remove_exact f wm) sub old stl
      onlyKept : (iret_8_1__kept_of (iret_7_4__match_tuples r (rarc_5_6_4__remove_exact f wm)) old ++ iret_8_1__added_of (iret_7_4__match_tuples r (rarc_5_6_4__remove_exact f wm)) old
                  = iret_8_1__kept_of (iret_7_4__match_tuples r (rarc_5_6_4__remove_exact f wm)) old)
      onlyKept = trans (cong (iret_8_1__kept_of (iret_7_4__match_tuples r (rarc_5_6_4__remove_exact f wm)) old ++) noAdd) (appendNilRightNeutral _)
  in iret_8_1__refresh_well (rarc_5_6_4__remove_exact f wm) r (iret_7_9__neg_facts r (rarc_5_6_4__remove_exact f wm)) _
       (replace {p = \z => Iret_8_1__well (rarc_5_6_4__remove_exact f wm) z} (sym onlyKept) keptWell)

-- ---------------------------------------------------------------------
-- The well-formed FireLoop state
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.5]
--@spec [IRET.8.1]
||| Every table of a FireLoop state well-formed and settled against its
||| rule.
public export
data Rarc_5_6_5__tables_well : Rarc_5_6_4__wm -> List Lgra_6_1__rule -> List (List Iret_11__tok) -> Type where
  TWNil  : Rarc_5_6_5__tables_well w [] []
  TWCons : Iret_8_1__well w ts -> Iret_8_1__settled r (iret_7_4__match_tuples r w) (iret_7_9__neg_facts r w) ts ->
           Rarc_5_6_5__tables_well w rs tss -> Rarc_5_6_5__tables_well w (r :: rs) (ts :: tss)

--@derives [RARC.5.6.5]
export
rarc_5_6_5__propagate_well_grow : (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm ->
                                  (base : Rarc_5_6_4__wm) -> Iret_11_3__distinct base -> ((g : Lfac_1_7_1__fact) -> Elem g base -> Elem g wm) ->
                                  ((s, t : Iret_7_1__token) -> Ldet_5_5__live wm s -> Ldet_5_5__live wm t -> Ldet_5_5__live base s -> Ldet_5_5__live base t ->
                                   ldet_5_5__before base s t = ldet_5_5__before wm s t) ->
                                  (new : Lfac_1_7_1__fact) -> rarc_5_6_4__is_live (fid new) wm = False ->
                                  (rs : List Lgra_6_1__rule) -> (tss : List (List Iret_11__tok)) -> Rarc_5_6_5__tables_well wm rs tss ->
                                  Rarc_5_6_5__tables_well (base ++ [new]) rs (zipWith (\r, ts => rarc_5_6_5__prop_rule r (base ++ [new]) ts) rs tss)
rarc_5_6_5__propagate_well_grow wm uq base dbase sub same new fresh [] [] TWNil = TWNil
rarc_5_6_5__propagate_well_grow wm uq base dbase sub same new fresh (r :: rs) (ts :: tss) (TWCons w s rest) =
  TWCons (iret_8_1__prop_well_grow r wm uq base dbase sub same new fresh ts w s)
         (iret_8_1__prop_with_settled r (iret_7_4__match_tuples r (base ++ [new])) (iret_7_9__neg_facts r (base ++ [new])) ts)
         (rarc_5_6_5__propagate_well_grow wm uq base dbase sub same new fresh rs tss rest)

--@derives [RARC.5.6.5]
export
rarc_5_6_5__propagate_well_shrink : (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> Iret_4_4__unique wm -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                                    (rs : List Lgra_6_1__rule) -> (tss : List (List Iret_11__tok)) -> Rarc_5_6_5__tables_well wm rs tss ->
                                    Rarc_5_6_5__tables_well (rarc_5_6_4__remove_exact f wm) rs (zipWith (\r, ts => rarc_5_6_5__prop_rule r (rarc_5_6_4__remove_exact f wm) ts) rs tss)
rarc_5_6_5__propagate_well_shrink wm dw uq f ef [] [] TWNil = TWNil
rarc_5_6_5__propagate_well_shrink wm dw uq f ef (r :: rs) (ts :: tss) (TWCons w s rest) =
  TWCons (iret_8_1__prop_well_shrink r wm dw uq f ef ts w s)
         (iret_8_1__prop_with_settled r (iret_7_4__match_tuples r (rarc_5_6_4__remove_exact f wm)) (iret_7_9__neg_facts r (rarc_5_6_4__remove_exact f wm)) ts)
         (rarc_5_6_5__propagate_well_shrink wm dw uq f ef rs tss rest)

--@derives [IDAT.6.2.2]
export
idat_6_2_2__mark_tables_well : (wm : Rarc_5_6_4__wm) -> (r, j : Nat) -> (rs : List Lgra_6_1__rule) -> (tss : List (List Iret_11__tok)) ->
                               Rarc_5_6_5__tables_well wm rs tss -> Rarc_5_6_5__tables_well wm rs (idat_6_2_2__mark_fired r j tss)
idat_6_2_2__mark_tables_well wm r j [] [] TWNil = TWNil
idat_6_2_2__mark_tables_well wm Z j (rl :: rs) (ts :: tss) (TWCons w s rest) =
  TWCons (idat_6_2_2__mark_well wm j ts w) (idat_6_2_2__mark_settled rl _ _ ts j s) rest
idat_6_2_2__mark_tables_well wm (S r) j (rl :: rs) (ts :: tss) (TWCons w s rest) =
  TWCons w s (idat_6_2_2__mark_tables_well wm r j rs tss rest)

--@spec [RARC.5.6.5]
--@spec [IRET.4.4]
||| A WELL-FORMED FIRELOOP STATE: working memory distinct, ids unique,
||| every table well-formed and settled.
public export
Rarc_5_6_5__well : Lcyc_3_2_1__program -> Rarc_5_6_5__state -> Type
Rarc_5_6_5__well p st = (Iret_11_3__distinct (wm st), Iret_4_4__unique (wm st), Rarc_5_6_5__tables_well (wm st) (rules p) (toks st))

--@derives [IRET.19.1]
||| What an assert that changes working memory produces: the fresh
||| wrapper appended to working memory, or to working memory less the
||| entity it replaces.
export
iret_19_1__assert_fact_shape : (lc : Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (wm, wm' : Rarc_5_6_4__wm) ->
                               iret_19_1__assert_fact lc avoid k key pay wm = Just wm' ->
                               Either (wm' = wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay])
                                      (old ** (Elem old wm, wm' = rarc_5_6_4__remove_exact old wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay]))
iret_19_1__assert_fact_shape Explicit avoid k key pay wm wm' eq = Left (sym (iret_11_4__just_inj eq))
iret_19_1__assert_fact_shape Relation avoid k key pay wm wm' eq with (iret_19_1__find_relation k key pay wm)
  iret_19_1__assert_fact_shape Relation avoid k key pay wm wm' eq | (Just _) = absurd eq
  iret_19_1__assert_fact_shape Relation avoid k key pay wm wm' eq | Nothing = Left (sym (iret_11_4__just_inj eq))
iret_19_1__assert_fact_shape Entity avoid k key pay wm wm' eq with (iret_19_1__find_entity k key wm) proof fe
  iret_19_1__assert_fact_shape Entity avoid k key pay wm wm' eq | Nothing = Left (sym (iret_11_4__just_inj eq))
  iret_19_1__assert_fact_shape Entity avoid k key pay wm wm' eq | (Just old) with (fpay old == pay)
    iret_19_1__assert_fact_shape Entity avoid k key pay wm wm' eq | (Just old) | True = absurd eq
    iret_19_1__assert_fact_shape Entity avoid k key pay wm wm' eq | (Just old) | False =
      Right (old ** (snd (lcyc_1_1__find_just _ wm fe), sym (iret_11_4__just_inj eq)))

--@derives [LSCP.2.1.1]
export
lscp_2_1_1__withdraw_fact_shape : (f : Lfac_1_7_1__fact) -> (wm, wm' : Rarc_5_6_4__wm) -> lscp_2_1_1__withdraw_fact f wm = Just wm' ->
                                  (Elem f wm, wm' = rarc_5_6_4__remove_exact f wm)
lscp_2_1_1__withdraw_fact_shape f wm wm' eq with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) wm) proof an
  lscp_2_1_1__withdraw_fact_shape f wm wm' eq | True = (lscp_2_1_1__any_same_elem f wm an, sym (iret_11_4__just_inj eq))
  lscp_2_1_1__withdraw_fact_shape f wm wm' eq | False = absurd eq

--@derives [RARC.5.6.5]
--@derives [IRET.19.1]
||| A FRESH FACT APPENDED to a base contained in working memory keeps the
||| state well-formed: the two working-memory invariants, and every table.
export
rarc_5_6_5__well_grow : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> Iret_4_4__unique wm ->
                        (base : Rarc_5_6_4__wm) -> Iret_11_3__distinct base -> Iret_4_4__unique base -> ((g : Lfac_1_7_1__fact) -> Elem g base -> Elem g wm) ->
                        ((s, t : Iret_7_1__token) -> Ldet_5_5__live wm s -> Ldet_5_5__live wm t -> Ldet_5_5__live base s -> Ldet_5_5__live base t ->
                         ldet_5_5__before base s t = ldet_5_5__before wm s t) ->
                        (new : Lfac_1_7_1__fact) -> rarc_5_6_4__is_live (fid new) wm = False ->
                        (tables : List (List Iret_11__tok)) -> Rarc_5_6_5__tables_well wm (rules p) tables ->
                        Rarc_5_6_5__well p (MkState (base ++ [new]) (rarc_5_6_5__propagate p (base ++ [new]) tables))
rarc_5_6_5__well_grow p wm dw uq base dbase ubase sub same new fresh tables tw =
  let nn : Not (Elem new base)
      nn = \e => lcyc_1_1__bool_not_both _ (rarc_5_6_4__is_live_of new wm (sub new e)) fresh
  in ( iret_11_3__distinct_append base [new] dbase (DCons (\e => absurd e) DNil) (\x, ex, e => nn (replace {p = \z => Elem z base} (iret_12__elem_singleton e) ex))
     , iret_4_4__unique_append base ubase new (rarc_5_6_4__is_live_sub (fid new) wm base sub fresh)
     , rarc_5_6_5__propagate_well_grow wm uq base dbase sub same new fresh (rules p) tables tw )

--@derives [RARC.5.6.5]
--@derives [IRET.19.2]
||| A FACT REMOVED keeps the state well-formed.
export
rarc_5_6_5__well_shrink : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> Iret_4_4__unique wm ->
                          (f : Lfac_1_7_1__fact) -> Elem f wm ->
                          (tables : List (List Iret_11__tok)) -> Rarc_5_6_5__tables_well wm (rules p) tables ->
                          Rarc_5_6_5__well p (MkState (rarc_5_6_4__remove_exact f wm) (rarc_5_6_5__propagate p (rarc_5_6_4__remove_exact f wm) tables))
rarc_5_6_5__well_shrink p wm dw uq f ef tables tw =
  ( iret_11_3__distinct_filter _ wm dw
  , iret_4_4__unique_filter wm uq _
  , rarc_5_6_5__propagate_well_shrink wm dw uq f ef (rules p) tables tw )

--@derives [RARC.5.6.5]
--@derives [IRET.19.1]
||| An assert that changes working memory keeps the state well-formed,
||| whichever shape it takes.
export
rarc_5_6_5__well_assert : (p : Lcyc_3_2_1__program) -> (lc : Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) ->
                          (st : Rarc_5_6_5__state) -> Rarc_5_6_5__well p st -> (wm' : Rarc_5_6_4__wm) ->
                          iret_19_1__assert_fact lc avoid k key pay (wm st) = Just wm' ->
                          Rarc_5_6_5__well p (MkState wm' (rarc_5_6_5__propagate p wm' (toks st)))
rarc_5_6_5__well_assert p lc avoid k key pay (MkState wm tables) (dw, uq, tw) wm' eq =
  case iret_19_1__assert_fact_shape lc avoid k key pay wm wm' eq of
    Left sh => replace {p = \z => Rarc_5_6_5__well p (MkState z (rarc_5_6_5__propagate p z tables))} (sym sh)
                 (rarc_5_6_5__well_grow p wm dw uq wm dw uq (\g, e => e) (\s, t, _, _, _, _ => Refl) _ (fst (lfac_2_5_3__fresh_id_free avoid wm)) tables tw)
    Right (old ** (eo, sh)) => replace {p = \z => Rarc_5_6_5__well p (MkState z (rarc_5_6_5__propagate p z tables))} (sym sh)
                 (rarc_5_6_5__well_grow p wm dw uq (rarc_5_6_4__remove_exact old wm) (iret_11_3__distinct_filter _ wm dw) (iret_4_4__unique_filter wm uq _)
                    (\g, e => fst (rarc_5_6_4__remove_exact_elem_inv old wm g e))
                    (\s, t, ls, lt, ls', lt' => ldet_5_9__before_remove wm dw old eo s t ls lt
                        (\e => snd (rarc_5_6_4__remove_exact_elem_inv old wm old (lcyc_1_1__all_lookup ls' e)) Refl)
                        (\e => snd (rarc_5_6_4__remove_exact_elem_inv old wm old (lcyc_1_1__all_lookup lt' e)) Refl))
                    _ (fst (lfac_2_5_3__fresh_id_free avoid wm)) tables tw)

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_action_well : (p : Lcyc_3_2_1__program) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) -> (st : Rarc_5_6_5__state) ->
                             Rarc_5_6_5__well p st -> Rarc_5_6_5__well p (rarc_5_6_7__do_action p bound a st)
rarc_5_6_7__do_action_well p bound (Emit k value) st w with (iret_19_1__assert_fact (life p k) (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) (wm st)) proof af
  rarc_5_6_7__do_action_well p bound (Emit k value) st w | Nothing = w
  rarc_5_6_7__do_action_well p bound (Emit k value) st w | (Just wm') = rarc_5_6_5__well_assert p (life p k) (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) st w wm' af
rarc_5_6_7__do_action_well p bound (Withdraw i) st w with (rarc_5_6_5__nth i bound)
  rarc_5_6_7__do_action_well p bound (Withdraw i) st w | Nothing = w
  rarc_5_6_7__do_action_well p bound (Withdraw i) st w | (Just f) with (lscp_2_1_1__withdraw_fact f (wm st)) proof wf
    rarc_5_6_7__do_action_well p bound (Withdraw i) st w | (Just f) | Nothing = w
    rarc_5_6_7__do_action_well p bound (Withdraw i) (MkState wm tables) (dw, uq, tw) | (Just f) | (Just wm') =
      let (ef, sh) = lscp_2_1_1__withdraw_fact_shape f wm wm' wf
      in replace {p = \z => Rarc_5_6_5__well p (MkState z (rarc_5_6_5__propagate p z tables))} (sym sh) (rarc_5_6_5__well_shrink p wm dw uq f ef tables tw)

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_actions_well : (p : Lcyc_3_2_1__program) -> (bound : List Lfac_1_7_1__fact) -> (as : List Lgra_10_1__action) -> (st : Rarc_5_6_5__state) ->
                              Rarc_5_6_5__well p st -> Rarc_5_6_5__well p (rarc_5_6_7__do_actions p bound as st)
rarc_5_6_7__do_actions_well p bound [] st w = w
rarc_5_6_7__do_actions_well p bound (a :: as) st w = rarc_5_6_7__do_actions_well p bound as (rarc_5_6_7__do_action p bound a st) (rarc_5_6_7__do_action_well p bound a st w)

--@derives [IRET.11.4]
export
iret_11_4__step_well : (p : Lcyc_3_2_1__program) -> (st : Rarc_5_6_5__state) -> Rarc_5_6_5__well p st ->
                       (st' : Rarc_5_6_5__state) -> iret_11_4__step p st = Just st' -> Rarc_5_6_5__well p st'
iret_11_4__step_well p st w st' eq with (ldet_5_1__select_next (toks st))
  iret_11_4__step_well p st w st' eq | Nothing = void (absurd eq)
  iret_11_4__step_well p st w st' eq | (Just (r, j)) with (rarc_5_6_5__nth r (rules p))
    iret_11_4__step_well p st w st' eq | (Just (r, j)) | Nothing = void (absurd eq)
    iret_11_4__step_well p st w st' eq | (Just (r, j)) | (Just rule) with (rarc_5_6_5__nth j (iret_11__table_at r (toks st)))
      iret_11_4__step_well p st w st' eq | (Just (r, j)) | (Just rule) | Nothing = void (absurd eq)
      iret_11_4__step_well p (MkState wm tables) (dw, uq, tw) st' eq | (Just (r, j)) | (Just rule) | (Just tok) =
        replace {p = Rarc_5_6_5__well p} (iret_11_4__just_inj eq)
          (rarc_5_6_7__do_actions_well p (tfacts tok) (actions rule) (MkState wm (idat_6_2_2__mark_fired r j tables))
             (dw, uq, idat_6_2_2__mark_tables_well wm r j (rules p) tables tw))

--@derives [IRET.11.4]
--@derives [IRET.11.5]
export
iret_11_4__run_well : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (st : Rarc_5_6_5__state) -> Rarc_5_6_5__well p st ->
                      Rarc_5_6_5__well p (fst (iret_11_4__run p fuel st))
iret_11_4__run_well p Z st w = w
iret_11_4__run_well p (S fuel) st w with (iret_11_4__step p st) proof sp
  iret_11_4__run_well p (S fuel) st w | Nothing = w
  iret_11_4__run_well p (S fuel) st w | (Just st') with (iret_11_4__run p fuel st') proof rr
    iret_11_4__run_well p (S fuel) st w | (Just st') | (s, h, n) =
      replace {p = \x => Rarc_5_6_5__well p (fst x)} rr (iret_11_4__run_well p fuel st' (iret_11_4__step_well p st w st' sp))

-- ---------------------------------------------------------------------
-- The plain pipeline: inputs without the TMS phase, as the network
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.4]
||| An input applied to a FireLoop state without the TMS phase: the
||| assert under the kind's lifecycle, or the retraction by id, then one
||| propagation. What Rete/PumpBoundary.idr's `rarc_5_6_4__apply` does
||| before its phase, and what Rete/Network.idr does.
public export
rarc_5_6_4__apply_plain : Lcyc_3_2_1__program -> Rarc_5_6_1__event -> Rarc_5_6_5__state -> Rarc_5_6_5__state
rarc_5_6_4__apply_plain p (Assert k key pay) st = case iret_19_1__assert_fact (life p k) [] k key pay (wm st) of
  Nothing  => st
  Just wm' => MkState wm' (rarc_5_6_5__propagate p wm' (toks st))
rarc_5_6_4__apply_plain p (Retract i) st = case rarc_5_6_4__lookup_fact i (wm st) of
  Nothing => st
  Just f  => MkState (rarc_5_6_4__remove_exact f (wm st)) (rarc_5_6_5__propagate p (rarc_5_6_4__remove_exact f (wm st)) (toks st))

--@spec [LFST.9.2.1]
public export
lfst_9_2_1__boundary_plain : Lcyc_3_2_1__program -> Nat -> Rarc_5_6_1__event -> Rarc_5_6_5__state -> Rarc_5_6_5__state
lfst_9_2_1__boundary_plain p fuel ev st = fst (iret_11_4__run p fuel (rarc_5_6_4__apply_plain p ev st))

--@spec [LFST.9.2.1]
public export
lfst_9_2_1__replay_plain : Lcyc_3_2_1__program -> Nat -> List Rarc_5_6_1__event -> Rarc_5_6_5__state -> Rarc_5_6_5__state
lfst_9_2_1__replay_plain p fuel [] st = st
lfst_9_2_1__replay_plain p fuel (ev :: evs) st = lfst_9_2_1__replay_plain p fuel evs (lfst_9_2_1__boundary_plain p fuel ev st)

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_plain_well : (p : Lcyc_3_2_1__program) -> (ev : Rarc_5_6_1__event) -> (st : Rarc_5_6_5__state) ->
                               Rarc_5_6_5__well p st -> Rarc_5_6_5__well p (rarc_5_6_4__apply_plain p ev st)
rarc_5_6_4__apply_plain_well p (Assert k key pay) st w with (iret_19_1__assert_fact (life p k) [] k key pay (wm st)) proof af
  rarc_5_6_4__apply_plain_well p (Assert k key pay) st w | Nothing = w
  rarc_5_6_4__apply_plain_well p (Assert k key pay) st w | (Just wm') = rarc_5_6_5__well_assert p (life p k) [] k key pay st w wm' af
rarc_5_6_4__apply_plain_well p (Retract i) st w with (rarc_5_6_4__lookup_fact i (wm st)) proof lk
  rarc_5_6_4__apply_plain_well p (Retract i) st w | Nothing = w
  rarc_5_6_4__apply_plain_well p (Retract i) (MkState wm tables) (dw, uq, tw) | (Just f) =
    rarc_5_6_5__well_shrink p wm dw uq f (fst (rarc_5_6_4__lookup_elem i wm f lk)) tables tw

--@derives [LFST.9.2.1]
export
lfst_9_2_1__boundary_plain_well : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (ev : Rarc_5_6_1__event) -> (st : Rarc_5_6_5__state) ->
                                  Rarc_5_6_5__well p st -> Rarc_5_6_5__well p (lfst_9_2_1__boundary_plain p fuel ev st)
lfst_9_2_1__boundary_plain_well p fuel ev st w = iret_11_4__run_well p fuel _ (rarc_5_6_4__apply_plain_well p ev st w)

--@derives [LFST.9.2.1]
||| EVERY HISTORY keeps a FireLoop state well-formed.
export
lfst_9_2_1__replay_plain_well : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) -> (st : Rarc_5_6_5__state) ->
                              Rarc_5_6_5__well p st -> Rarc_5_6_5__well p (lfst_9_2_1__replay_plain p fuel evs st)
lfst_9_2_1__replay_plain_well p fuel [] st w = w
lfst_9_2_1__replay_plain_well p fuel (ev :: evs) st w = lfst_9_2_1__replay_plain_well p fuel evs _ (lfst_9_2_1__boundary_plain_well p fuel ev st w)

-- ---------------------------------------------------------------------
-- The initial state
-- ---------------------------------------------------------------------

--@derives [IRET.7.4]
||| Over empty working memory a rule has the nil tuple, if it has no
||| positive pattern, or nothing.
export
iret_7_4__tuples_empty : (ks : List Nat) -> Either (iret_7_4__tuples ks [] = [[]]) (iret_7_4__tuples ks [] = [])
iret_7_4__tuples_empty [] = Left Refl
iret_7_4__tuples_empty (k :: ks) = Right Refl

--@derives [LDET.5.5]
||| A sublist of a list of at most one tuple is sorted.
export
ldet_5_5__sorted_tuples_sub_one : (wm : Rarc_5_6_4__wm) -> (q : Iret_7_1__token -> Bool) -> (t : Iret_7_1__token) -> Ldet_5_5__sorted_tuples wm (filter q [t])
ldet_5_5__sorted_tuples_sub_one wm q t with (q t)
  ldet_5_5__sorted_tuples_sub_one wm q t | True = STCons [] STNil
  ldet_5_5__sorted_tuples_sub_one wm q t | False = STNil

--@derives [RARC.5.6.5]
--@derives [IRET.8.1]
||| A rule's first table, propagated from nothing over empty working
||| memory, is well-formed: at most the nil tuple.
export
rarc_5_6_5__init_table_well : (r : Lgra_6_1__rule) -> Iret_8_1__well [] (rarc_5_6_5__prop_rule r [] [])
rarc_5_6_5__init_table_well r =
  let lv : All (\t => Ldet_5_5__live [] (tfacts t)) (rarc_5_6_5__prop_rule r [] [])
      lv = lcyc_1_1__all_map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r [])) (lcyc_1_1__all_from_elem _ (\t, e =>
             let (fs ** (efs', teq)) = lcyc_1_1__elem_map_inv iret_8_1__fresh_tok _ e
                 (efs, _) = lcyc_1_1__elem_filter_inv (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids []))) (iret_7_4__match_tuples r []) efs'
             in replace {p = \z => Ldet_5_5__live [] (tfacts z)} teq
                  (lcyc_1_1__all_lookup (iret_7_4__tuples_live (posKinds r) []) (fst (lcyc_1_1__elem_filter_inv (guard r) (iret_7_4__tuples (posKinds r) []) efs)))))
      so : Ldet_5_5__sorted_tuples [] (iret_11_3__tuples_of (rarc_5_6_5__prop_rule r [] []))
      so = replace {p = \z => Ldet_5_5__sorted_tuples [] z} (sym (ldet_5_9__refresh_tuples r (iret_7_9__neg_facts r []) _))
             (replace {p = \z => Ldet_5_5__sorted_tuples [] z} (sym (iret_8_1__added_tuples (iret_7_4__match_tuples r []) []))
                (case iret_7_4__tuples_empty (posKinds r) of
                   Left one => replace {p = \z => Ldet_5_5__sorted_tuples [] (filter (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids []))) (filter (guard r) z))} (sym one)
                                 (rarc_5_6_5__init_sorted_one r)
                   Right none => replace {p = \z => Ldet_5_5__sorted_tuples [] (filter (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids []))) (filter (guard r) z))} (sym none) STNil))
  in (lv, so)
  where
    rarc_5_6_5__init_sorted_one : (r : Lgra_6_1__rule) ->
                                  Ldet_5_5__sorted_tuples [] (filter (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids []))) (filter (guard r) [[]]))
    rarc_5_6_5__init_sorted_one r with (guard r [])
      rarc_5_6_5__init_sorted_one r | True = ldet_5_5__sorted_tuples_sub_one [] (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids []))) []
      rarc_5_6_5__init_sorted_one r | False = STNil

--@derives [RARC.5.6.5]
export
rarc_5_6_5__init_tables_well : (rs : List Lgra_6_1__rule) -> Rarc_5_6_5__tables_well [] rs (zipWith (\r, ts => rarc_5_6_5__prop_rule r [] ts) rs (map (const []) rs))
rarc_5_6_5__init_tables_well [] = TWNil
rarc_5_6_5__init_tables_well (r :: rs) =
  TWCons (rarc_5_6_5__init_table_well r) (iret_8_1__prop_with_settled r (iret_7_4__match_tuples r []) (iret_7_9__neg_facts r []) []) (rarc_5_6_5__init_tables_well rs)

--@derives [RARC.5.6.5]
||| THE INITIAL STATE over empty working memory is well-formed.
export
rarc_5_6_5__init_well : (p : Lcyc_3_2_1__program) -> Rarc_5_6_5__well p (rarc_5_6_5__init_state p [])
rarc_5_6_5__init_well p = (DNil, \f, g, ef, eg, eq => absurd ef, rarc_5_6_5__init_tables_well (rules p))

--@derives [RARC.5.6.5]
--@derives [LFST.9.2.1]
||| FIRELOOP'S STATE AFTER ANY HISTORY is well-formed: every table in the
||| key's order.
export
rarc_5_6_5__well_after_history : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                 Rarc_5_6_5__well p (lfst_9_2_1__replay_plain p fuel evs (rarc_5_6_5__init_state p []))
rarc_5_6_5__well_after_history p fuel evs = lfst_9_2_1__replay_plain_well p fuel evs (rarc_5_6_5__init_state p []) (rarc_5_6_5__init_well p)

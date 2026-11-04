-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE CASCADE, ONE FACT AT A TIME. Rete/FireLoopTms.idr's phase retracts
||| the facts an ending left unsupported as a batch and propagates once
||| ([IRET.12.2] step 3, "for each"); the network of Rete/Network.idr can
||| only retract one fact at a time, each through alpha dispatch
||| ([IRET.19.2]), which is also how the reference engine cascades
||| ("depth first, one fact at a time; the fixpoint is the same", that
||| module's header). This module proves the two reach one state:
||| propagation after successive retractions composes into one
||| propagation over the shrunk memory -- a retraction adds no match,
||| keeps the survivors in place, and can only release a `no` pattern,
||| never block one ([LDET.5.9]) -- and propagation over a settled table
||| changes nothing. With them, retracting the batch's ids one by one on
||| the network and once on FireLoop keeps the agreement of
||| Rete/NetworkTransfer.idr, which is what Rete/NetworkTms.idr needs.
module Rete.NetworkTmsCascade

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.Network
import Rete.NetworkView
import Rete.Refcount
import Rete.TmsBridge
import Rete.PumpBoundary
import Rete.NetworkAgree
import Rete.NetworkTransferOrder
import Rete.NetworkTransferTable
import Rete.NetworkTransferAgree
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.List.Elem
import Data.List.Quantifiers

%default total

-- ---------------------------------------------------------------------
-- Blocking is monotone in working memory
-- ---------------------------------------------------------------------

--@derives [IRET.7.9]
||| A blocker satisfied by a fact of a memory is satisfied under any
||| memory holding that fact.
export
iret_7_9__any_kind_sub : (wm, wm' : Rarc_5_6_4__wm) -> ((g : Lfac_1_7_1__fact) -> Elem g wm' -> Elem g wm) ->
                         (k : Nat) -> (q : Lfac_1_7_1__fact -> Bool) ->
                         rarc_5_6_5__any q (rarc_5_6_4__facts_of_kind k wm') = True -> rarc_5_6_5__any q (rarc_5_6_4__facts_of_kind k wm) = True
iret_7_9__any_kind_sub wm wm' sub k q h =
  let (g ** (eg, qg)) = iret_12_2__any_true q (rarc_5_6_4__facts_of_kind k wm') h
  in let (eg', kg) = lcyc_1_1__elem_filter_inv (\f => fkind f == k) wm' eg
     in lcyc_1_1__any_elem q (rarc_5_6_4__facts_of_kind k wm) (lcyc_1_1__elem_filter_fwd (\f => fkind f == k) wm (sub g eg') kg) qg

--@derives [IRET.7.9]
||| A satisfied first blocker blocks.
export
iret_7_9__blocked_negs_cons_true : (wm : Rarc_5_6_4__wm) -> (nb : (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) -> (rest : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) ->
                                   (fs : Iret_7_1__token) -> rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm) = True ->
                                   iret_7_9__blocked_negs wm (nb :: rest) fs = True
iret_7_9__blocked_negs_cons_true wm nb rest fs h with (rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm))
  iret_7_9__blocked_negs_cons_true wm nb rest fs h | True = Refl
  iret_7_9__blocked_negs_cons_true wm nb rest fs h | False = absurd h

--@derives [IRET.7.9]
||| Blocked by the rest is blocked.
export
iret_7_9__blocked_negs_cons_rest : (wm : Rarc_5_6_4__wm) -> (nb : (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) -> (rest : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) ->
                                   (fs : Iret_7_1__token) -> iret_7_9__blocked_negs wm rest fs = True ->
                                   iret_7_9__blocked_negs wm (nb :: rest) fs = True
iret_7_9__blocked_negs_cons_rest wm nb rest fs h with (rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm))
  iret_7_9__blocked_negs_cons_rest wm nb rest fs h | True = Refl
  iret_7_9__blocked_negs_cons_rest wm nb rest fs h | False = h

--@derives [IRET.7.9]
||| Blocked with the first blocker unsatisfied: blocked by the rest.
export
iret_7_9__blocked_negs_cons_inv_true : (wm : Rarc_5_6_4__wm) -> (nb : (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) -> (rest : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) ->
                                       (fs : Iret_7_1__token) -> iret_7_9__blocked_negs wm (nb :: rest) fs = True ->
                                       rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm) = False ->
                                       iret_7_9__blocked_negs wm rest fs = True
iret_7_9__blocked_negs_cons_inv_true wm nb rest fs h n with (rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm))
  iret_7_9__blocked_negs_cons_inv_true wm nb rest fs h n | True = absurd n
  iret_7_9__blocked_negs_cons_inv_true wm nb rest fs h n | False = h

--@derives [IRET.7.9]
||| Blocked, blocker by blocker, under a memory: blocked under any larger
||| one.
export
iret_7_9__blocked_negs_sub : (wm, wm' : Rarc_5_6_4__wm) -> ((g : Lfac_1_7_1__fact) -> Elem g wm' -> Elem g wm) ->
                             (negs : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) -> (fs : Iret_7_1__token) ->
                             iret_7_9__blocked_negs wm' negs fs = True -> iret_7_9__blocked_negs wm negs fs = True
iret_7_9__blocked_negs_sub wm wm' sub [] fs h = absurd h
iret_7_9__blocked_negs_sub wm wm' sub (nb :: rest) fs h =
  case iret_12__bool_split (rarc_5_6_5__any (snd nb fs) (rarc_5_6_4__facts_of_kind (fst nb) wm')) of
    Left a' => iret_7_9__blocked_negs_cons_true wm nb rest fs (iret_7_9__any_kind_sub wm wm' sub (fst nb) (snd nb fs) a')
    Right n' => iret_7_9__blocked_negs_cons_rest wm nb rest fs
                  (iret_7_9__blocked_negs_sub wm wm' sub rest fs (iret_7_9__blocked_negs_cons_inv_true wm' nb rest fs h n'))

--@derives [IRET.7.9]
--@derives [LDET.5.9]
||| A `no` pattern blocked under a memory is blocked under any larger
||| one: a retraction only ever releases.
export
iret_7_9__is_blocked_sub : (r : Lgra_6_1__rule) -> (wm, wm' : Rarc_5_6_4__wm) -> ((g : Lfac_1_7_1__fact) -> Elem g wm' -> Elem g wm) ->
                           (fs : Iret_7_1__token) -> iret_7_9__is_blocked r wm' fs = True -> iret_7_9__is_blocked r wm fs = True
iret_7_9__is_blocked_sub r wm wm' sub fs h =
  trans (iret_7_9__is_blocked_negs wm (negs r) fs)
        (iret_7_9__blocked_negs_sub wm wm' sub (negs r) fs (trans (sym (iret_7_9__is_blocked_negs wm' (negs r) fs)) h))

-- ---------------------------------------------------------------------
-- Refreshing twice along a shrink is refreshing once
-- ---------------------------------------------------------------------

--@derives [LDET.5.9]
||| A token refreshed under a blocking that only ever releases, then
||| refreshed again: the second refresh alone. A release clears `fired`
||| either way; a token that stays blocked or stays clear keeps it.
export
ldet_5_9__refresh_with_compose : (t : Iret_11__tok) -> (b1, b2 : Bool) -> (b2 = True -> b1 = True) -> (b1 = True -> blocked t = True) ->
                                 ldet_5_9__refresh_with b2 (ldet_5_9__refresh_with b1 t) = ldet_5_9__refresh_with b2 t
ldet_5_9__refresh_with_compose (MkTok fs fd True)  True  True  m21 m10 = Refl
ldet_5_9__refresh_with_compose (MkTok fs fd False) True  True  m21 m10 = Refl
ldet_5_9__refresh_with_compose (MkTok fs fd True)  True  False m21 m10 = Refl
ldet_5_9__refresh_with_compose (MkTok fs fd False) True  False m21 m10 = absurd (m10 Refl)
ldet_5_9__refresh_with_compose (MkTok fs fd bl)    False True  m21 m10 = absurd (m21 Refl)
ldet_5_9__refresh_with_compose (MkTok fs fd True)  False False m21 m10 = Refl
ldet_5_9__refresh_with_compose (MkTok fs fd False) False False m21 m10 = Refl

--@derives [LDET.5.9]
||| A token settled under a memory, refreshed under a sub-memory and then
||| under a sub-memory of that, is the token refreshed under the last.
export
ldet_5_9__refresh_tok_compose : (r : Lgra_6_1__rule) -> (wm0, wm1, wm2 : Rarc_5_6_4__wm) ->
                                ((g : Lfac_1_7_1__fact) -> Elem g wm1 -> Elem g wm0) -> ((g : Lfac_1_7_1__fact) -> Elem g wm2 -> Elem g wm1) ->
                                (t : Iret_11__tok) -> blocked t = iret_7_9__is_blocked r wm0 (tfacts t) ->
                                ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2) (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm1) t)
                                  = ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2) t
ldet_5_9__refresh_tok_compose r wm0 wm1 wm2 sub10 sub21 t stl =
  ldet_5_9__refresh_with_compose t (iret_7_9__is_blocked r wm1 (tfacts t)) (iret_7_9__is_blocked r wm2 (tfacts t))
    (iret_7_9__is_blocked_sub r wm1 wm2 sub21 (tfacts t))
    (\h => trans stl (iret_7_9__is_blocked_sub r wm0 wm1 sub10 (tfacts t) h))

-- ---------------------------------------------------------------------
-- Kept twice is kept once
-- ---------------------------------------------------------------------

--@derives [IRET.8.1]
||| The kept tokens of a refreshed table are the refreshed kept tokens:
||| keeping reads identities, which a refresh leaves.
export
iret_8_1__kept_of_map_refresh : (r : Lgra_6_1__rule) -> (nf : List (List Lfac_1_7_1__fact)) -> (now : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) ->
                                iret_8_1__kept_of now (map (ldet_5_9__refresh_tok r nf) ts) = map (ldet_5_9__refresh_tok r nf) (iret_8_1__kept_of now ts)
iret_8_1__kept_of_map_refresh r nf now [] = Refl
iret_8_1__kept_of_map_refresh r nf now (t :: ts) =
  case iret_12__bool_split (rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids now)) of
    Left h  => rewrite h in cong (ldet_5_9__refresh_tok r nf t ::) (iret_8_1__kept_of_map_refresh r nf now ts)
    Right h => rewrite h in iret_8_1__kept_of_map_refresh r nf now ts

--@derives [IRET.8.1]
||| A token kept by the matches over a sub-memory was kept by the matches
||| over the memory: a match over fewer facts is a match over more.
export
iret_8_1__kept_sub : (r : Lgra_6_1__rule) -> (wm1, wm2 : Rarc_5_6_4__wm) -> ((g : Lfac_1_7_1__fact) -> Elem g wm2 -> Elem g wm1) ->
                     (t : Iret_11__tok) ->
                     rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids (iret_7_4__match_tuples r wm2)) = True ->
                     rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids (iret_7_4__match_tuples r wm1)) = True
iret_8_1__kept_sub r wm1 wm2 sub t h =
  let (fs ** (efs, idsEq)) = lcyc_1_1__elem_map_inv iret_11_3__fact_ids (iret_7_4__match_tuples r wm2)
                               (lcyc_1_1__elem_ll_elem (iret_11_3__ids t) (iret_11_3__now_ids (iret_7_4__match_tuples r wm2)) h)
  in let (etup, _) = lcyc_1_1__elem_filter_inv (guard r) (iret_7_4__tuples (posKinds r) wm2) efs
     in let live1 : All (\f => Elem f wm1) fs
            live1 = lcyc_1_1__all_imp fs (\f, e => sub f e) (lcyc_1_1__all_lookup (iret_7_4__tuples_live (posKinds r) wm2) etup)
        in lcyc_1_1__elem_ll_true (iret_11_3__ids t) (iret_11_3__now_ids (iret_7_4__match_tuples r wm1))
             (replace {p = \z => Elem z (iret_11_3__now_ids (iret_7_4__match_tuples r wm1))} idsEq
                (lcyc_1_1__elem_map_fwd iret_11_3__fact_ids (iret_7_4__match_sub r wm1 wm2 fs efs live1)))

--@derives [LCYC.1.1]
||| Filtering by a test that implies an earlier one is filtering by it
||| alone.
export
lcyc_1_1__filter_filter_imp : (q, p : a -> Bool) -> ((x : a) -> q x = True -> p x = True) -> (xs : List a) ->
                              filter q (filter p xs) = filter q xs
lcyc_1_1__filter_filter_imp q p imp [] = Refl
lcyc_1_1__filter_filter_imp q p imp (x :: xs) =
  case iret_12__bool_split (q x) of
    Left qt => rewrite imp x qt in rewrite qt in cong (x ::) (lcyc_1_1__filter_filter_imp q p imp xs)
    Right qf => case iret_12__bool_split (p x) of
      Left pt  => rewrite pt in rewrite qf in lcyc_1_1__filter_filter_imp q p imp xs
      Right pf => rewrite pf in rewrite qf in lcyc_1_1__filter_filter_imp q p imp xs

--@derives [IRET.8.1]
||| Kept by the smaller memory's matches after kept by the larger's is
||| kept by the smaller's.
export
iret_8_1__kept_of_kept_of : (r : Lgra_6_1__rule) -> (wm1, wm2 : Rarc_5_6_4__wm) -> ((g : Lfac_1_7_1__fact) -> Elem g wm2 -> Elem g wm1) ->
                            (ts : List Iret_11__tok) ->
                            iret_8_1__kept_of (iret_7_4__match_tuples r wm2) (iret_8_1__kept_of (iret_7_4__match_tuples r wm1) ts)
                              = iret_8_1__kept_of (iret_7_4__match_tuples r wm2) ts
iret_8_1__kept_of_kept_of r wm1 wm2 sub ts =
  lcyc_1_1__filter_filter_imp (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids (iret_7_4__match_tuples r wm2)))
                              (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids (iret_7_4__match_tuples r wm1)))
                              (\t, h => iret_8_1__kept_sub r wm1 wm2 sub t h) ts

--@derives [LCYC.1.1]
||| Mapping twice is mapping the composite, given pointwise.
export
lcyc_1_1__map_map_all : (f, g, h : a -> a) -> (xs : List a) -> All (\x => f (g x) = h x) xs -> map f (map g xs) = map h xs
lcyc_1_1__map_map_all f g h [] [] = Refl
lcyc_1_1__map_map_all f g h (x :: xs) (px :: pxs) = cong2 (::) px (lcyc_1_1__map_map_all f g h xs pxs)

-- ---------------------------------------------------------------------
-- Propagation composes along a shrink
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.5]
--@derives [LDET.5.9]
--@derives [IRET.12.2]
||| PROPAGATION AFTER SUCCESSIVE RETRACTIONS COMPOSES. A table settled
||| under a memory, propagated over a sub-memory and then over a
||| sub-memory of that, is the table propagated over the last once:
||| neither propagation adds a match, both keep the same survivors in
||| place, and refreshing along a shrink composes. So a cascade that
||| retracts its facts one at a time ends where the batch does.
export
rarc_5_6_5__prop_rule_shrink_compose : (r : Lgra_6_1__rule) -> (wm0, wm1, wm2 : Rarc_5_6_4__wm) ->
                                       ((g : Lfac_1_7_1__fact) -> Elem g wm1 -> Elem g wm0) -> ((g : Lfac_1_7_1__fact) -> Elem g wm2 -> Elem g wm1) ->
                                       (old : List Iret_11__tok) -> Iret_8_1__settled r (iret_7_4__match_tuples r wm0) (iret_7_9__neg_facts r wm0) old ->
                                       rarc_5_6_5__prop_rule r wm2 (rarc_5_6_5__prop_rule r wm1 old) = rarc_5_6_5__prop_rule r wm2 old
rarc_5_6_5__prop_rule_shrink_compose r wm0 wm1 wm2 sub10 sub21 old stl =
  let (tokS, _) = stl
  in let noAdd1 : (iret_8_1__added_of (iret_7_4__match_tuples r wm1) old = [])
         noAdd1 = iret_8_1__added_none r wm0 wm1 sub10 old stl
         x1 : (rarc_5_6_5__prop_rule r wm1 old = map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm1)) (iret_8_1__kept_of (iret_7_4__match_tuples r wm1) old))
         x1 = cong (map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm1)))
                   (trans (cong (iret_8_1__kept_of (iret_7_4__match_tuples r wm1) old ++) noAdd1) (appendNilRightNeutral _))
         noAdd2 : (iret_8_1__added_of (iret_7_4__match_tuples r wm2) (rarc_5_6_5__prop_rule r wm1 old) = [])
         noAdd2 = iret_8_1__added_none r wm1 wm2 sub21 (rarc_5_6_5__prop_rule r wm1 old)
                    (iret_8_1__prop_with_settled r (iret_7_4__match_tuples r wm1) (iret_7_9__neg_facts r wm1) old)
         noAdd0 : (iret_8_1__added_of (iret_7_4__match_tuples r wm2) old = [])
         noAdd0 = iret_8_1__added_none r wm0 wm2 (\g, e => sub10 g (sub21 g e)) old stl
         lhs1 : (rarc_5_6_5__prop_rule r wm2 (rarc_5_6_5__prop_rule r wm1 old)
                 = map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2)) (iret_8_1__kept_of (iret_7_4__match_tuples r wm2) (rarc_5_6_5__prop_rule r wm1 old)))
         lhs1 = cong (map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2)))
                     (trans (cong (iret_8_1__kept_of (iret_7_4__match_tuples r wm2) (rarc_5_6_5__prop_rule r wm1 old) ++) noAdd2) (appendNilRightNeutral _))
         lhs2 : (iret_8_1__kept_of (iret_7_4__match_tuples r wm2) (rarc_5_6_5__prop_rule r wm1 old)
                 = map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm1)) (iret_8_1__kept_of (iret_7_4__match_tuples r wm2) old))
         lhs2 = trans (cong (iret_8_1__kept_of (iret_7_4__match_tuples r wm2)) x1)
                      (trans (iret_8_1__kept_of_map_refresh r (iret_7_9__neg_facts r wm1) (iret_7_4__match_tuples r wm2) (iret_8_1__kept_of (iret_7_4__match_tuples r wm1) old))
                             (cong (map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm1))) (iret_8_1__kept_of_kept_of r wm1 wm2 sub21 old)))
         settledK : All (Iret_8_1__tok_settled r (iret_7_4__match_tuples r wm0) (iret_7_9__neg_facts r wm0)) (iret_8_1__kept_of (iret_7_4__match_tuples r wm2) old)
         settledK = lcyc_1_1__all_filter (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids (iret_7_4__match_tuples r wm2))) old tokS
         fuse : (map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2)) (map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm1)) (iret_8_1__kept_of (iret_7_4__match_tuples r wm2) old))
                 = map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2)) (iret_8_1__kept_of (iret_7_4__match_tuples r wm2) old))
         fuse = lcyc_1_1__map_map_all (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2)) (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm1)) (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2)) _
                  (lcyc_1_1__all_imp _ (\t, s => ldet_5_9__refresh_tok_compose r wm0 wm1 wm2 sub10 sub21 t (fst s)) settledK)
         rhs : (rarc_5_6_5__prop_rule r wm2 old = map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2)) (iret_8_1__kept_of (iret_7_4__match_tuples r wm2) old))
         rhs = cong (map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2)))
                    (trans (cong (iret_8_1__kept_of (iret_7_4__match_tuples r wm2) old ++) noAdd0) (appendNilRightNeutral _))
     in trans lhs1 (trans (cong (map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm2))) lhs2) (trans fuse (sym rhs)))

--@derives [RARC.5.6.5]
||| Rule by rule.
export
rarc_5_6_5__zip_prop_shrink_compose : (wm0, wm1, wm2 : Rarc_5_6_4__wm) ->
                                      ((g : Lfac_1_7_1__fact) -> Elem g wm1 -> Elem g wm0) -> ((g : Lfac_1_7_1__fact) -> Elem g wm2 -> Elem g wm1) ->
                                      (rs : List Lgra_6_1__rule) -> (tss : List (List Iret_11__tok)) -> Rarc_5_6_5__tables_well wm0 rs tss ->
                                      zipWith (\r, ts => rarc_5_6_5__prop_rule r wm2 ts) rs (zipWith (\r, ts => rarc_5_6_5__prop_rule r wm1 ts) rs tss)
                                        = zipWith (\r, ts => rarc_5_6_5__prop_rule r wm2 ts) rs tss
rarc_5_6_5__zip_prop_shrink_compose wm0 wm1 wm2 sub10 sub21 [] [] TWNil = Refl
rarc_5_6_5__zip_prop_shrink_compose wm0 wm1 wm2 sub10 sub21 (r :: rs) (ts :: tss) (TWCons w s rest) =
  cong2 (::) (rarc_5_6_5__prop_rule_shrink_compose r wm0 wm1 wm2 sub10 sub21 ts s)
             (rarc_5_6_5__zip_prop_shrink_compose wm0 wm1 wm2 sub10 sub21 rs tss rest)

--@derives [RARC.5.6.5]
--@derives [IRET.12.2]
||| The tables of a well-formed state, propagated over a sub-memory and
||| then over a sub-memory of that, are the tables propagated over the
||| last once.
export
rarc_5_6_5__propagate_shrink_compose : (p : Lcyc_3_2_1__program) -> (wm0, wm1, wm2 : Rarc_5_6_4__wm) ->
                                       ((g : Lfac_1_7_1__fact) -> Elem g wm1 -> Elem g wm0) -> ((g : Lfac_1_7_1__fact) -> Elem g wm2 -> Elem g wm1) ->
                                       (tss : List (List Iret_11__tok)) -> Rarc_5_6_5__tables_well wm0 (rules p) tss ->
                                       rarc_5_6_5__propagate p wm2 (rarc_5_6_5__propagate p wm1 tss) = rarc_5_6_5__propagate p wm2 tss
rarc_5_6_5__propagate_shrink_compose p wm0 wm1 wm2 sub10 sub21 tss tw =
  rarc_5_6_5__zip_prop_shrink_compose wm0 wm1 wm2 sub10 sub21 (rules p) tss tw

-- ---------------------------------------------------------------------
-- Propagation over a settled table changes nothing
-- ---------------------------------------------------------------------

--@derives [LDET.5.9]
||| Refreshing a settled token leaves it: its blocking is current, and
||| `fired` is cleared only on a release.
export
ldet_5_9__refresh_settled_id : (r : Lgra_6_1__rule) -> (nf : List (List Lfac_1_7_1__fact)) -> (t : Iret_11__tok) ->
                               blocked t = iret_7_9__is_blocked_with (iret_7_9__blockers r) nf (tfacts t) ->
                               ldet_5_9__refresh_tok r nf t = t
ldet_5_9__refresh_settled_id r nf (MkTok fs fd True)  h = rewrite sym h in Refl
ldet_5_9__refresh_settled_id r nf (MkTok fs fd False) h = rewrite sym h in Refl

--@derives [RARC.5.6.5]
||| A SETTLED TABLE RE-PROPAGATED over the same memory is itself: every
||| token is kept, nothing is added, and no refresh changes a token.
export
rarc_5_6_5__prop_rule_settled_id : (r : Lgra_6_1__rule) -> (wm : Rarc_5_6_4__wm) -> (ts : List Iret_11__tok) ->
                                   Iret_8_1__settled r (iret_7_4__match_tuples r wm) (iret_7_9__neg_facts r wm) ts ->
                                   rarc_5_6_5__prop_rule r wm ts = ts
rarc_5_6_5__prop_rule_settled_id r wm ts (tokS, nowS) =
  let kept : (iret_8_1__kept_of (iret_7_4__match_tuples r wm) ts = ts)
      kept = lcyc_1_1__filter_all_true _ ts (lcyc_1_1__all_imp ts (\t, s => snd s) tokS)
      added : (iret_8_1__added_of (iret_7_4__match_tuples r wm) ts = [])
      added = cong (map iret_8_1__fresh_tok)
                (lcyc_1_1__filter_all_false _ (iret_7_4__match_tuples r wm) (lcyc_1_1__all_imp (iret_7_4__match_tuples r wm) (\fs, e => cong not e) nowS))
  in trans (cong (map (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm))) (trans (cong2 (++) kept added) (appendNilRightNeutral ts)))
           (lcyc_1_1__map_id_all (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm)) ts
              (lcyc_1_1__all_imp ts (\t, s => ldet_5_9__refresh_settled_id r (iret_7_9__neg_facts r wm) t (fst s)) tokS))

--@derives [RARC.5.6.5]
||| Rule by rule.
export
rarc_5_6_5__zip_prop_settled_id : (wm : Rarc_5_6_4__wm) -> (rs : List Lgra_6_1__rule) -> (tss : List (List Iret_11__tok)) -> Rarc_5_6_5__tables_well wm rs tss ->
                                  zipWith (\r, ts => rarc_5_6_5__prop_rule r wm ts) rs tss = tss
rarc_5_6_5__zip_prop_settled_id wm [] [] TWNil = Refl
rarc_5_6_5__zip_prop_settled_id wm (r :: rs) (ts :: tss) (TWCons w s rest) =
  cong2 (::) (rarc_5_6_5__prop_rule_settled_id r wm ts s) (rarc_5_6_5__zip_prop_settled_id wm rs tss rest)

--@derives [RARC.5.6.5]
||| The tables of a well-formed state re-propagated over its memory are
||| themselves.
export
rarc_5_6_5__propagate_settled_id : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tss : List (List Iret_11__tok)) ->
                                   Rarc_5_6_5__tables_well wm (rules p) tss -> rarc_5_6_5__propagate p wm tss = tss
rarc_5_6_5__propagate_settled_id p wm tss tw = rarc_5_6_5__zip_prop_settled_id wm (rules p) tss tw

-- ---------------------------------------------------------------------
-- Retracting ids one at a time is the batch retraction
-- ---------------------------------------------------------------------

-- `lcyc_1_1__filter_ext_on` and `lcyc_1_1__filter_filter`, used below, are
-- Rete/NetworkView.idr's, shared with Rete/NetworkAnswer.idr.

--@derives [IRET.12.2]
||| No ids: nothing retracted.
export
iret_12_2__retract_ids_nil : (wm : Rarc_5_6_4__wm) -> iret_12_2__retract_ids [] wm = wm
iret_12_2__retract_ids_nil wm = lcyc_1_1__filter_all_true _ wm (lcyc_1_1__all_from_elem wm (\f, _ => Refl))

--@derives [IRET.12.2]
||| Dropping a live id then the rest, member by member, is dropping the
||| fact then the rest: ids are unique.
export
iret_12_2__drop_pointwise_live : (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (i : Nat) -> (is : List Nat) -> (f : Lfac_1_7_1__fact) ->
                                 rarc_5_6_4__lookup_fact i wm = Just f -> (g : Lfac_1_7_1__fact) -> Elem g wm ->
                                 not (rarc_5_6_5__elem (fid g) (i :: is)) = (not (lfac_2_5_4__same_fact g f) && not (rarc_5_6_5__elem (fid g) is))
iret_12_2__drop_pointwise_live wm uq i is f lk g eg =
  let (ef, fi) = rarc_5_6_4__lookup_elem i wm f lk
  in case iret_12__bool_split (i == fid g) of
       Left h =>
         let gf : (g = f)
             gf = sym (uq f g ef eg (trans fi (lcyc_1_1__nat_eq_true i (fid g) h)))
         in rewrite h in rewrite gf in rewrite lfac_2_5_4__same_fact_refl f in Refl
       Right h =>
         let neq : Not (fid g = fid f)
             neq = \e => lcyc_1_1__nat_neq_false i (fid g) h (trans (sym fi) (sym e))
         in rewrite h in rewrite lcyc_1_1__nat_eq_false (fid g) (fid f) neq in Refl

--@derives [IRET.12.2]
||| Retracting a live id and then the rest is retracting the rest from
||| the memory less that fact.
export
iret_12_2__retract_ids_cons_live : (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (i : Nat) -> (is : List Nat) -> (f : Lfac_1_7_1__fact) ->
                                   rarc_5_6_4__lookup_fact i wm = Just f ->
                                   iret_12_2__retract_ids (i :: is) wm = iret_12_2__retract_ids is (rarc_5_6_4__remove_exact f wm)
iret_12_2__retract_ids_cons_live wm uq i is f lk =
  trans (lcyc_1_1__filter_ext_on (\g => not (rarc_5_6_5__elem (fid g) (i :: is)))
                                 (\g => not (lfac_2_5_4__same_fact g f) && not (rarc_5_6_5__elem (fid g) is)) wm
                                 (iret_12_2__drop_pointwise_live wm uq i is f lk))
        (sym (lcyc_1_1__filter_filter (\g => not (lfac_2_5_4__same_fact g f)) (\g => not (rarc_5_6_5__elem (fid g) is)) wm))

--@derives [IRET.12.2]
||| Retracting an id no live fact carries changes nothing.
export
iret_12_2__retract_ids_cons_dead : (wm : Rarc_5_6_4__wm) -> (i : Nat) -> (is : List Nat) -> rarc_5_6_4__lookup_fact i wm = Nothing ->
                                   iret_12_2__retract_ids (i :: is) wm = iret_12_2__retract_ids is wm
iret_12_2__retract_ids_cons_dead wm i is lk =
  lcyc_1_1__filter_ext_on (\g => not (rarc_5_6_5__elem (fid g) (i :: is))) (\g => not (rarc_5_6_5__elem (fid g) is)) wm
    (\g, eg => let (h ** lkg) = rarc_5_6_4__lookup_some g wm eg
                   neq : Not (i = fid g)
                   neq = \e => absurd (trans (sym lkg) (replace {p = \z => rarc_5_6_4__lookup_fact z wm = Nothing} e lk))
               in rewrite lcyc_1_1__nat_eq_false i (fid g) neq in Refl)

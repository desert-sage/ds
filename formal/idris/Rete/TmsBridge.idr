-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The bridge: the engine's cascade (Rete/FireLoopTms.idr) is
||| Rete/Refcount.idr's cascade of the engine's own dependency table.
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr.
||| The theorem and its invariant are named under [IRET.12.2], the clause
||| whose mechanism they characterise; the positive-program premise under
||| [IRET.7.9]; id uniqueness under [IRET.4.4]; the token-level lemmas
||| under the [IRET.7.4] / [IRET.8.1] structure they are about.
|||
||| WHAT IS PROVED. Start a cascade in a state that is settled, has
||| unique fact ids, and whose rows stand for matches of their rules
||| (`Iret_12_4__row_facts`). Read the state into Refcount's terms: the
||| live set is the ids of working memory, the justifications are the
||| table's rows, the base facts are the live facts no row justifies.
||| Then the cascade reaches its fixpoint within its fuel, and the facts
||| live at the fixpoint are exactly `iret_12_2__cascade` of that reading
||| (`iret_12_2__bridge`). With Rete/Refcount.idr's theorems that makes
||| the engine's retraction the GREATEST self-supported subset of the live
||| set, and what it keeps beyond the well-founded answer an unfounded set.
|||
||| SCOPE, stated plainly. Positive programs only: a `no` pattern is an
||| absence antecedent [LLOG.11.5], which Refcount's justifications do not
||| carry and which makes support non-monotone. The stratified reading the
||| TMS change needs (`no` only over lower strata) is not modelled anywhere
||| in the lane. The premises are what a state satisfies between actions of
||| a run; that every run's states satisfy them is Rete/TmsRun.idr's run
||| invariant (`iret_12__run_inv_holds`), which also carries the fresh-id
||| property (`lfac_2_5_3__fresh_id_free`) this file takes as `Iret_4_4__unique`.
module Rete.TmsBridge

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.Refcount
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Certificate
import Lcyc.Termination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- Premises
-- ---------------------------------------------------------------------

--@spec [IRET.7.9]
||| A positive program: no rule has a `no` pattern.
public export
Iret_7_9__positive : Lcyc_3_2_1__program -> Type
Iret_7_9__positive p = (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just r -> negs r = []

--@spec [IRET.4.4]
||| Fact ids are unique in working memory: two live facts with one id are
||| the same fact. What the monotonic counter guarantees.
public export
Iret_4_4__unique : Rarc_5_6_4__wm -> Type
Iret_4_4__unique wm = (f, g : Lfac_1_7_1__fact) -> Elem f wm -> Elem g wm -> fid f = fid g -> f = g

--@spec [IRET.12.4]
||| The targets of a table.
public export
iret_12_4__targets : Iret_12_4__table -> List Nat
iret_12_4__targets rows = map rtarget rows

--@spec [IRET.12.2]
||| The facts no row justifies, among a live set: never retracted by the
||| cascade. Refcount's base.
public export
iret_12_2__base : Iret_12_4__table -> List Nat -> List Nat
iret_12_2__base rows live = filter (\i => not (iret_12__elem i (iret_12_4__targets rows))) live

--@spec [IRET.12.4]
||| What a row's identity stands for: facts whose ids are the row's, a
||| match of the row's rule (kinds in pattern order, guard passed), and
||| such that a live id of theirs is theirs -- the reading of the identity
||| that survives a cascade, which only ever removes facts.
public export
Iret_12_4__row_facts : Lcyc_3_2_1__program -> Rarc_5_6_4__wm -> Iret_12_4__row -> Type
Iret_12_4__row_facts p wm row =
  (r ** (fs ** ( rarc_5_6_5__nth (rrule row) (rules p) = Just r
              , iret_11_3__fact_ids fs = rids row
              , lcyc_3_2_2__kinds_of fs = posKinds r
              , guard r fs = True
              , All (\f => rarc_5_6_4__is_live (fid f) wm = True -> Elem f wm) fs )))

-- ---------------------------------------------------------------------
-- List lemmas
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
export
iret_12_2__any_true : (q : a -> Bool) -> (xs : List a) -> rarc_5_6_5__any q xs = True -> (x ** (Elem x xs, q x = True))
iret_12_2__any_true q [] prf = absurd prf
iret_12_2__any_true q (x :: xs) prf with (q x) proof qx
  iret_12_2__any_true q (x :: xs) prf | True = (x ** (Here, qx))
  iret_12_2__any_true q (x :: xs) prf | False = case iret_12_2__any_true q xs prf of
    (y ** (e, qy)) => (y ** (There e, qy))

--@derives [IRET.12.2]
export
iret_12_2__elem_concat_map : (g : a -> List b) -> (ys : List a) -> Elem y ys -> Elem x (g y) -> Elem x (rarc_5_6_5__concat_map g ys)
iret_12_2__elem_concat_map g (y :: ys) Here e = lcyc_1_1__elem_append_left e
iret_12_2__elem_concat_map g (y' :: ys) (There e') e = lcyc_1_1__elem_append_right (g y') (iret_12_2__elem_concat_map g ys e' e)

--@derives [IRET.12.2]
export
iret_12_2__filter_lte : (q : a -> Bool) -> (xs : List a) -> LTE (length (filter q xs)) (length xs)
iret_12_2__filter_lte q [] = LTEZero
iret_12_2__filter_lte q (y :: ys) with (q y)
  iret_12_2__filter_lte q (y :: ys) | True = LTESucc (iret_12_2__filter_lte q ys)
  iret_12_2__filter_lte q (y :: ys) | False = lteSuccRight (iret_12_2__filter_lte q ys)

--@derives [IRET.12.2]
||| A filter that drops a member is strictly shorter.
export
iret_12_2__filter_drops : (q : a -> Bool) -> (xs : List a) -> (x0 : a) -> Elem x0 xs -> q x0 = False -> LT (length (filter q xs)) (length xs)
iret_12_2__filter_drops q (x :: xs) x Here qx with (q x)
  iret_12_2__filter_drops q (x :: xs) x Here qx | True = absurd qx
  iret_12_2__filter_drops q (x :: xs) x Here qx | False = LTESucc (iret_12_2__filter_lte q xs)
iret_12_2__filter_drops q (x :: xs) x0 (There e) qx with (q x)
  iret_12_2__filter_drops q (x :: xs) x0 (There e) qx | True = LTESucc (iret_12_2__filter_drops q xs x0 e qx)
  iret_12_2__filter_drops q (x :: xs) x0 (There e) qx | False = lteSuccRight (iret_12_2__filter_drops q xs x0 e qx)

--@derives [IRET.12.4]
||| An id live in working memory belongs to some live fact, and conversely.
export
iret_12_4__live_id : (i : Nat) -> (wm : Rarc_5_6_4__wm) -> iret_12__elem i (iret_11_3__fact_ids wm) = True -> (g ** (Elem g wm, fid g = i))
iret_12_4__live_id i wm prf = case lcyc_1_1__elem_map_inv fid wm (iret_12__elem_elem i (iret_11_3__fact_ids wm) prf) of
  (g ** (e, eq)) => (g ** (e, eq))

--@derives [IRET.12.4]
export
iret_12_4__id_live : (g : Lfac_1_7_1__fact) -> (wm : Rarc_5_6_4__wm) -> Elem g wm -> iret_12__elem (fid g) (iret_11_3__fact_ids wm) = True
iret_12_4__id_live g wm e = iret_12__elem_true (fid g) (iret_11_3__fact_ids wm) (lcyc_1_1__elem_map_fwd fid e)

--@derives [RARC.5.6.4]
||| A live fact's id looks up to some live fact.
export
rarc_5_6_4__lookup_some : (g : Lfac_1_7_1__fact) -> (wm : Rarc_5_6_4__wm) -> Elem g wm -> (h ** rarc_5_6_4__lookup_fact (fid g) wm = Just h)
rarc_5_6_4__lookup_some g (h :: ws) e with (fid h == fid g) proof he
  rarc_5_6_4__lookup_some g (h :: ws) e | True = (h ** Refl)
  rarc_5_6_4__lookup_some g (g :: ws) Here | False = absurd (trans (sym he) (lcyc_1_1__nat_eq_refl (fid g)))
  rarc_5_6_4__lookup_some g (h :: ws) (There e') | False = rarc_5_6_4__lookup_some g ws e'

--@derives [RARC.5.6.4]
||| What a lookup returns is live and carries the id.
export
rarc_5_6_4__lookup_elem : (i : Nat) -> (wm : Rarc_5_6_4__wm) -> (h : Lfac_1_7_1__fact) -> rarc_5_6_4__lookup_fact i wm = Just h -> (Elem h wm, fid h = i)
rarc_5_6_4__lookup_elem i [] h prf = absurd prf
rarc_5_6_4__lookup_elem i (f :: ws) h prf with (fid f == i) proof e
  rarc_5_6_4__lookup_elem i (f :: ws) h prf | True =
    (replace {p = \x => Elem x (f :: ws)} (iret_11_4__just_inj prf) Here,
     replace {p = \x => fid x = i} (iret_11_4__just_inj prf) (lcyc_1_1__nat_eq_true (fid f) i e))
  rarc_5_6_4__lookup_elem i (f :: ws) h prf | False = case rarc_5_6_4__lookup_elem i ws h prf of
    (eh, eq) => (There eh, eq)

--@derives [RARC.5.6.4]
||| `is_live` agrees with membership of the id list.
export
rarc_5_6_4__is_live_of : (g : Lfac_1_7_1__fact) -> (wm : Rarc_5_6_4__wm) -> Elem g wm -> rarc_5_6_4__is_live (fid g) wm = True
rarc_5_6_4__is_live_of g wm e with (rarc_5_6_4__lookup_fact (fid g) wm) proof lk
  rarc_5_6_4__is_live_of g wm e | Just _ = Refl
  rarc_5_6_4__is_live_of g wm e | Nothing = case rarc_5_6_4__lookup_some g wm e of
    (h ** eq) => absurd (trans (sym lk) eq)

--@derives [RARC.5.6.4]
export
rarc_5_6_4__is_live_inv : (i : Nat) -> (wm : Rarc_5_6_4__wm) -> rarc_5_6_4__is_live i wm = True -> (g ** (Elem g wm, fid g = i))
rarc_5_6_4__is_live_inv i wm prf with (rarc_5_6_4__lookup_fact i wm) proof lk
  rarc_5_6_4__is_live_inv i wm prf | Just h = (h ** rarc_5_6_4__lookup_elem i wm h lk)
  rarc_5_6_4__is_live_inv i wm prf | Nothing = absurd prf

-- ---------------------------------------------------------------------
-- Tokens: a match of live facts is enumerated, has a token, and keeps it
-- ---------------------------------------------------------------------

--@derives [IRET.7.4]
||| Facts of the pattern kinds, all live, are an enumerated tuple.
export
iret_7_4__tuple_of_live : (ks : List Nat) -> (wm : Rarc_5_6_4__wm) -> (fs : List Lfac_1_7_1__fact) ->
                          lcyc_3_2_2__kinds_of fs = ks -> All (\f => Elem f wm) fs -> Elem fs (iret_7_4__tuples ks wm)
iret_7_4__tuple_of_live ks wm [] eq [] = rewrite sym eq in Here
iret_7_4__tuple_of_live ks wm (f :: fs) eq (lf :: lfs) =
  rewrite sym eq in
  iret_12_2__elem_concat_map (\g => map (g ::) (iret_7_4__tuples (lcyc_3_2_2__kinds_of fs) wm)) (rarc_5_6_4__facts_of_kind (fkind f) wm)
    (lcyc_1_1__elem_filter_fwd (\g => fkind g == fkind f) wm lf (lcyc_1_1__nat_eq_refl (fkind f)))
    (lcyc_1_1__elem_map_fwd (f ::) (iret_7_4__tuple_of_live (lcyc_3_2_2__kinds_of fs) wm fs Refl lfs))

--@derives [IRET.7.4]
||| And if they pass the guard, a current match.
export
iret_7_4__match_of_live : (r : Lgra_6_1__rule) -> (wm : Rarc_5_6_4__wm) -> (fs : List Lfac_1_7_1__fact) ->
                          lcyc_3_2_2__kinds_of fs = posKinds r -> guard r fs = True -> All (\f => Elem f wm) fs ->
                          Elem fs (iret_7_4__match_tuples r wm)
iret_7_4__match_of_live r wm fs eq g lf = lcyc_1_1__elem_filter_fwd (guard r) (iret_7_4__tuples (posKinds r) wm) (iret_7_4__tuple_of_live (posKinds r) wm fs eq lf) g

--@derives [IRET.7.9]
||| A rule without `no` patterns blocks nothing.
export
iret_7_9__unblocked : (r : Lgra_6_1__rule) -> negs r = [] -> (nf : List (List Lfac_1_7_1__fact)) -> (fs : List Lfac_1_7_1__fact) ->
                      iret_7_9__is_blocked_with (iret_7_9__blockers r) nf fs = False
iret_7_9__unblocked r eq nf fs = replace {p = \ns => iret_7_9__is_blocked_with (map snd ns) nf fs = False} (sym eq) Refl

--@derives [IRET.8.1]
||| In a settled table of a rule without `no` patterns no token is blocked.
export
iret_8_1__settled_unblocked : (r : Lgra_6_1__rule) -> negs r = [] -> (now, nf : List (List Lfac_1_7_1__fact)) -> (ts : List Iret_11__tok) ->
                              Iret_8_1__settled r now nf ts -> (t : Iret_11__tok) -> Elem t ts -> blocked t = False
iret_8_1__settled_unblocked r eq now nf ts (allT, _) t e = trans (fst (lcyc_1_1__all_lookup allT e)) (iret_7_9__unblocked r eq nf (tfacts t))

--@derives [LDET.5.9]
||| Refreshing an unblocked token keeps its facts and its `fired`.
export
ldet_5_9__refresh_unblocked : (r : Lgra_6_1__rule) -> (nf : List (List Lfac_1_7_1__fact)) -> (t : Iret_11__tok) -> blocked t = False ->
                              ( tfacts (ldet_5_9__refresh_tok r nf t) = tfacts t
                              , fired (ldet_5_9__refresh_tok r nf t) = fired t
                              , blocked (ldet_5_9__refresh_tok r nf t) = iret_7_9__is_blocked_with (iret_7_9__blockers r) nf (tfacts t) )
ldet_5_9__refresh_unblocked r nf (MkTok fs fr False) eq = (Refl, Refl, Refl)
ldet_5_9__refresh_unblocked r nf (MkTok fs fr True) eq = absurd eq

--@derives [IRET.11]
||| The r-th table, when the rule and table lists line up.
export
iret_11__table_at_nth : (ri : Nat) -> (tables : List (List Iret_11__tok)) -> (ts : List Iret_11__tok) ->
                        rarc_5_6_5__nth ri tables = Just ts -> iret_11__table_at ri tables = ts
iret_11__table_at_nth ri tables ts eq = replace {p = \m => iret_11__from_maybe m = ts} (sym eq) Refl

--@derives [IRET.7.8]
||| A token whose identity is the row's, fired and unblocked, passes the
||| liveness test.
export
iret_7_8__live_token_ok : (row : Iret_12_4__row) -> (u : Iret_11__tok) -> iret_11_3__ids u = rids row -> fired u = True -> blocked u = False ->
                          ((iret_11_3__ids u == rids row) && (fired u && not (blocked u))) = True
iret_7_8__live_token_ok row (MkTok fs fr bl) idsEq fr' bl' =
  rewrite idsEq in rewrite fr' in rewrite bl' in rewrite lcyc_1_1__list_nat_eq_refl (rids row) in Refl

--@derives [IRET.12.4]
||| A live id of a row's facts makes the fact live, by the row's reading.
export
iret_12_4__facts_live : (wm : Rarc_5_6_4__wm) -> (row : Iret_12_4__row) -> (fs : List Lfac_1_7_1__fact) ->
                        iret_11_3__fact_ids fs = rids row ->
                        All (\f => rarc_5_6_4__is_live (fid f) wm = True -> Elem f wm) fs ->
                        iret_12__all_in (rids row) (iret_11_3__fact_ids wm) = True ->
                        All (\f => Elem f wm) fs
iret_12_4__facts_live wm row fs ids liv allLive =
  lcyc_1_1__all_from_elem fs (\f, ef =>
    lcyc_1_1__all_lookup liv ef
      (case iret_12_4__live_id (fid f) wm
              (iret_12__all_in_elem (rids row) (iret_11_3__fact_ids wm) allLive (fid f)
                 (replace {p = \is => Elem (fid f) is} ids (lcyc_1_1__elem_map_fwd fid ef))) of
         (g ** (eg, eq)) => replace {p = \j => rarc_5_6_4__is_live j wm = True} eq (rarc_5_6_4__is_live_of g wm eg)))

--@derives [IRET.7.8]
||| THE TOKEN LEMMA. A live activation whose antecedent ids are all live
||| in the new working memory is live after propagation: its token is
||| kept (the facts are a current match) with its `fired`, and nothing
||| blocks it (positive program).
export
iret_7_8__live_after_propagate : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                                 (st : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom st -> (wm' : Rarc_5_6_4__wm) ->
                                 (row : Iret_12_4__row) -> Iret_12_4__row_facts p wm' row ->
                                 iret_12__all_in (rids row) (iret_11_3__fact_ids wm') = True ->
                                 iret_7_8__activation_live (toks st) row = True ->
                                 iret_7_8__activation_live (rarc_5_6_5__propagate p wm' (toks st)) row = True
iret_7_8__live_after_propagate p pos dom st inv wm' row (r ** (fs ** (nr, ids, kinds, gd, liv))) allLive act
  with (rarc_5_6_5__nth (rrule row) (toks st)) proof nt
  iret_7_8__live_after_propagate p pos dom st inv wm' row (r ** (fs ** (nr, ids, kinds, gd, liv))) allLive act | Nothing =
    absurd act
  iret_7_8__live_after_propagate p pos dom st inv wm' row (r ** (fs ** (nr, ids, kinds, gd, liv))) allLive act | Just ts =
    case iret_12_2__any_true (\t => (iret_11_3__ids t == rids row) && (fired t && not (blocked t))) ts
           act of
      (t ** (te, ok)) =>
        let isMatch : Elem fs (iret_7_4__match_tuples r wm')
            isMatch = iret_7_4__match_of_live r wm' fs kinds gd (iret_12_4__facts_live wm' row fs ids liv allLive)
            idsEq : (iret_11_3__ids t = rids row)
            idsEq = lcyc_1_1__list_nat_eq_true (iret_11_3__ids t) (rids row) (lcyc_1_1__and_true_l _ _ ok)
            firedT : (fired t = True)
            firedT = lcyc_1_1__and_true_l _ _ (lcyc_1_1__and_true_r _ _ ok)
            unblocked : (blocked t = False)
            unblocked = iret_8_1__settled_unblocked r (pos (rrule row) r nr) (iret_7_4__match_tuples r (wm st)) (iret_7_9__neg_facts r (wm st)) ts
                          (settled inv (rrule row) r ts nr nt) t te
            inNow : (rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids (iret_7_4__match_tuples r wm')) = True)
            inNow = replace {p = \is => rarc_5_6_5__elem is (iret_11_3__now_ids (iret_7_4__match_tuples r wm')) = True} (trans ids (sym idsEq))
                      (lcyc_1_1__elem_ll_true (iret_11_3__fact_ids fs) (iret_11_3__now_ids (iret_7_4__match_tuples r wm'))
                         (lcyc_1_1__elem_map_fwd iret_11_3__fact_ids isMatch))
            inKept : Elem t (iret_8_1__kept_of (iret_7_4__match_tuples r wm') ts)
            inKept = lcyc_1_1__elem_filter_fwd (\u => rarc_5_6_5__elem (iret_11_3__ids u) (iret_11_3__now_ids (iret_7_4__match_tuples r wm'))) ts te inNow
            inNew : Elem (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm') t) (rarc_5_6_5__prop_rule r wm' ts)
            inNew = lcyc_1_1__elem_map_fwd (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm')) (lcyc_1_1__elem_append_left inKept)
            refr = ldet_5_9__refresh_unblocked r (iret_7_9__neg_facts r wm') t unblocked
            okNew : (((iret_11_3__ids (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm') t) == rids row)
                       && (fired (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm') t) && not (blocked (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm') t)))) = True)
            okNew = iret_7_8__live_token_ok row (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm') t)
                      (trans (cong iret_11_3__fact_ids (fst refr)) idsEq)
                      (trans (fst (snd refr)) firedT)
                      (trans (snd (snd refr)) (iret_7_9__unblocked r (pos (rrule row) r nr) (iret_7_9__neg_facts r wm') (tfacts t)))
            newTable : (rarc_5_6_5__nth (rrule row) (rarc_5_6_5__propagate p wm' (toks st)) = Just (rarc_5_6_5__prop_rule r wm' ts))
            newTable = lcyc_1_1__nth_zip_with_just (\q, tq => rarc_5_6_5__prop_rule q wm' tq) (rrule row) (rules p) (toks st) nr nt
        in replace {p = \tbl => rarc_5_6_5__any (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) tbl = True}
                   (sym (iret_11__table_at_nth (rrule row) (rarc_5_6_5__propagate p wm' (toks st)) (rarc_5_6_5__prop_rule r wm' ts) newTable))
                   (lcyc_1_1__any_elem (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) (rarc_5_6_5__prop_rule r wm' ts) inNew okNew)

-- ---------------------------------------------------------------------
-- Small lemmas: lists, bools, the order on Nat
-- ---------------------------------------------------------------------

--@derives [IRET.12]
export
iret_12__cons_not_nil : {x : a} -> {xs : List a} -> (x :: xs) = [] -> Void
iret_12__cons_not_nil Refl impossible

--@derives [IRET.12]
export
iret_12__elem_nonempty : (xs : List a) -> Elem x xs -> length xs = 0 -> Void
iret_12__elem_nonempty [] e _ = absurd e
iret_12__elem_nonempty (y :: ys) _ Refl impossible

--@derives [IRET.12]
export
iret_12__head_of_length : (xs : List a) -> length xs = S k -> (x ** Elem x xs)
iret_12__head_of_length [] Refl impossible
iret_12__head_of_length (y :: ys) _ = (y ** Here)

--@derives [IRET.12]
||| An empty filter rejected every member.
export
iret_12__filter_nil_all : (q : a -> Bool) -> (xs : List a) -> filter q xs = [] -> (x : a) -> Elem x xs -> q x = False
iret_12__filter_nil_all q xs prf x e =
  iret_12__bool_false_of (q x) (\qt => absurd (replace {p = \l => Elem x l} prf (lcyc_1_1__elem_filter_fwd q xs e qt)))

--@derives [IRET.12]
||| A member the filter lost failed the test.
export
iret_12__elem_filter_false : (i : Nat) -> (q : Nat -> Bool) -> (xs : List Nat) -> iret_12__elem i (filter q xs) = False -> iret_12__elem i xs = True -> q i = False
iret_12__elem_filter_false i q xs nf ei = iret_12__bool_false_of (q i) (\qt => lcyc_1_1__bool_not_both _ (iret_12__elem_filter q xs i ei qt) nf)

--@derives [IRET.12]
export
iret_12__and_both : (a, b : Bool) -> a = True -> b = True -> (a && b) = True
iret_12__and_both True True _ _ = Refl
iret_12__and_both False _ pa _ = absurd pa
iret_12__and_both True False _ pb = absurd pb

--@derives [IRET.12]
export
iret_12__lte_succ_self : (n : Nat) -> LTE n (S n)
iret_12__lte_succ_self Z = LTEZero
iret_12__lte_succ_self (S k) = LTESucc (iret_12__lte_succ_self k)

-- ---------------------------------------------------------------------
-- Phase equations
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| Whatever a phase retracts, its rows are the kept ones.
export
iret_12_2__phase_after_eta : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (kept : Iret_12_4__table) -> (gone : List Nat) ->
                             iret_12_2__phase_after p wm tables kept gone = MkTms (core (iret_12_2__phase_after p wm tables kept gone)) kept
iret_12_2__phase_after_eta p wm tables kept [] = Refl
iret_12_2__phase_after_eta p wm tables kept (g :: gs) = Refl

--@derives [IRET.12.2]
||| A phase that ends nothing is the identity.
export
iret_12_2__phase_step_nil : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            iret_12_2__ended (MkState wm tables) rows = [] ->
                            iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms (MkState wm tables) rows
iret_12_2__phase_step_nil p wm tables rows en with (iret_12_2__ended (MkState wm tables) rows)
  iret_12_2__phase_step_nil p wm tables rows en | [] = Refl
  iret_12_2__phase_step_nil p wm tables rows en | (x :: xs) = void (iret_12__cons_not_nil en)

--@derives [IRET.12.2]
||| A phase either ends nothing and is the identity, or keeps strictly
||| fewer rows.
export
iret_12_2__phase_step_shape : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
  Either ( iret_12_2__ended (MkState wm tables) rows = []
         , iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms (MkState wm tables) rows )
         (st ** ( iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms st (iret_12_2__kept (MkState wm tables) rows)
                , LT (length (iret_12_2__kept (MkState wm tables) rows)) (length rows) ))
iret_12_2__phase_step_shape p wm tables rows with (iret_12_2__ended (MkState wm tables) rows) proof en
  iret_12_2__phase_step_shape p wm tables rows | [] = Left (Refl, Refl)
  iret_12_2__phase_step_shape p wm tables rows | (x :: xs) =
    let (ex, nq) = lcyc_1_1__elem_filter_inv (\row => not (iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm)) rows
                     (replace {p = \l => Elem x l} (sym en) Here)
    in Right (core (iret_12_2__phase_after p wm tables (iret_12_2__kept (MkState wm tables) rows) (iret_12_2__zeroed (x :: xs) (iret_12_2__kept (MkState wm tables) rows)))
              ** ( iret_12_2__phase_after_eta p wm tables (iret_12_2__kept (MkState wm tables) rows) (iret_12_2__zeroed (x :: xs) (iret_12_2__kept (MkState wm tables) rows))
                 , iret_12_2__filter_drops (\row => iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm) rows x ex (iret_12__not_true _ nq) ))

--@derives [IRET.12.2]
||| One more phase, when the first is known.
export
iret_12_2__phase_n_succ : (n : Nat) -> (p : Lcyc_3_2_1__program) -> (s : Iret_12__state) -> (st : Rarc_5_6_5__state) -> (r : Iret_12_4__table) ->
                          iret_12_2__phase_step p s = MkTms st r -> iret_12_2__phase_n (S n) p s = iret_12_2__phase_n n p (MkTms st r)
iret_12_2__phase_n_succ n p s st r eq with (iret_12_2__phase_step p s)
  iret_12_2__phase_n_succ n p s st r eq | (MkTms st' r') = cong (iret_12_2__phase_n n p) eq

--@derives [IRET.12.2]
||| Nothing ending, nothing changes however many phases run.
export
iret_12_2__phase_n_stable : (n : Nat) -> (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            iret_12_2__ended (MkState wm tables) rows = [] ->
                            iret_12_2__phase_n n p (MkTms (MkState wm tables) rows) = MkTms (MkState wm tables) rows
iret_12_2__phase_n_stable Z p wm tables rows en = Refl
iret_12_2__phase_n_stable (S n) p wm tables rows en =
  trans (iret_12_2__phase_n_succ n p (MkTms (MkState wm tables) rows) (MkState wm tables) rows (iret_12_2__phase_step_nil p wm tables rows en))
        (iret_12_2__phase_n_stable n p wm tables rows en)

--@derives [IRET.12.2]
||| THE FUEL. With at least as many phases as rows, the cascade reaches a
||| phase that ends nothing: every other phase drops a row.
export
iret_12_2__phase_n_fixed : (n : Nat) -> (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                           LTE (length rows) n ->
                           iret_12_2__ended (core (iret_12_2__phase_n n p (MkTms (MkState wm tables) rows))) (deps (iret_12_2__phase_n n p (MkTms (MkState wm tables) rows))) = []
iret_12_2__phase_n_fixed Z p wm tables [] lte = Refl
iret_12_2__phase_n_fixed Z p wm tables (r :: rs) LTEZero impossible
iret_12_2__phase_n_fixed (S m) p wm tables rows lte = case iret_12_2__phase_step_shape p wm tables rows of
  Left (en, eq) => replace {p = \x => iret_12_2__ended (core x) (deps x) = []} (sym (iret_12_2__phase_n_stable (S m) p wm tables rows en)) en
  Right (MkState wm' tables' ** (eq, lt)) =>
    replace {p = \x => iret_12_2__ended (core x) (deps x) = []}
            (sym (iret_12_2__phase_n_succ m p (MkTms (MkState wm tables) rows) (MkState wm' tables') (iret_12_2__kept (MkState wm tables) rows) eq))
            (iret_12_2__phase_n_fixed m p wm' tables' (iret_12_2__kept (MkState wm tables) rows) (fromLteSucc (transitive lt lte)))

-- ---------------------------------------------------------------------
-- The cascade invariant
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| What holds of every state a cascade passes through, relative to the
||| table it started with (`rows0`) and the ids live then (`live0`): the
||| core invariant and unique ids; the rows are some of the starting rows
||| and the live ids some of the starting ones; every starting row whose
||| activation is live reads as a match; a starting row whose antecedents
||| and target are all live is present and live; Refcount's cascade of
||| the starting reading is still live; and a live fact outside the base
||| has a row.
public export
record Iret_12_2__cascade_inv (p : Lcyc_3_2_1__program) (dom : List (Nat, Nat)) (rows0 : Iret_12_4__table) (live0 : List Nat)
                              (wm : Rarc_5_6_4__wm) (tables : List (List Iret_11__tok)) (rows : Iret_12_4__table) where
  constructor MkCascadeInv
  coreInv  : Lcyc_1_1__inv p dom (MkState wm tables)
  uniq     : Iret_4_4__unique wm
  rowsSub  : (row : Iret_12_4__row) -> Elem row rows -> Elem row rows0
  liveSub  : Iret_12__sub (iret_11_3__fact_ids wm) live0
  rowFacts : (row : Iret_12_4__row) -> Elem row rows0 -> iret_7_8__activation_live tables row = True -> Iret_12_4__row_facts p wm row
  rowLive  : (row : Iret_12_4__row) -> Elem row rows0 -> iret_12__all_in (rids row) (iret_11_3__fact_ids wm) = True ->
             rarc_5_6_4__is_live (rtarget row) wm = True -> (Elem row rows, iret_7_8__activation_live tables row = True)
  gfpSub   : Iret_12__sub (iret_12_2__cascade (iret_12_2__base rows0 live0) (iret_12_4__justifs rows0) live0) (iret_11_3__fact_ids wm)
  hasRow   : (i : Nat) -> iret_12__elem i (iret_11_3__fact_ids wm) = True -> iret_12__elem i (iret_12_2__base rows0 live0) = False ->
             (row ** (Elem row rows, rtarget row = i))

--@derives [IRET.12.2]
||| A live fact outside the base has a row targeting it, at the start.
export
iret_12_2__base_row : (rows : Iret_12_4__table) -> (live0 : List Nat) -> (i : Nat) -> iret_12__elem i live0 = True ->
                      iret_12__elem i (iret_12_2__base rows live0) = False -> (row ** (Elem row rows, rtarget row = i))
iret_12_2__base_row rows live0 i li nb =
  let nt : (not (iret_12__elem i (iret_12_4__targets rows)) = False)
      nt = iret_12__elem_filter_false i (\j => not (iret_12__elem j (iret_12_4__targets rows))) live0 nb li
      inT : Elem i (iret_12_4__targets rows)
      inT = iret_12__elem_elem i (map rtarget rows) (lcyc_1_1__not_false_is_true _ nt)
  in case lcyc_1_1__elem_map_inv rtarget rows inT of
       (row ** (e, eq)) => (row ** (e, eq))

-- ---------------------------------------------------------------------
-- Counting rows
-- ---------------------------------------------------------------------

--@derives [IRET.12.1]
||| A nonzero count exhibits a row with the target.
export
iret_12_1__count_row : (rows : Iret_12_4__table) -> (i : Nat) -> Not (iret_12_1__count rows i = 0) -> (row ** (Elem row rows, rtarget row = i))
iret_12_1__count_row rows i nz with (iret_12_1__count rows i) proof c
  iret_12_1__count_row rows i nz | Z = void (nz Refl)
  iret_12_1__count_row rows i nz | (S k) = case iret_12__head_of_length (filter (\r => rtarget r == i) rows) c of
    (row ** e) => let (er, eq) = lcyc_1_1__elem_filter_inv (\r => rtarget r == i) rows e
                  in (row ** (er, lcyc_1_1__nat_eq_true (rtarget row) i eq))

--@derives [IRET.12.2]
||| A row targeting i, after the endings: it is kept, or it ended and
||| then, unless i was zeroed, some kept row targets i.
export
iret_12_2__target_kept : (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows, es : Iret_12_4__table) ->
                         iret_12_2__ended (MkState wm tables) rows = es -> (i : Nat) ->
                         (row ** (Elem row rows, rtarget row = i)) ->
                         Not (Elem i (iret_12_2__zeroed es (iret_12_2__kept (MkState wm tables) rows))) ->
                         (row' ** (Elem row' (iret_12_2__kept (MkState wm tables) rows), rtarget row' = i))
iret_12_2__target_kept wm tables rows es en i (row ** (e, ti)) nz =
  case iret_12__bool_split (iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm) of
    Left q => (row ** (lcyc_1_1__elem_filter_fwd (\row => iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm) rows e q, ti))
    Right nq =>
      let inEnded : Elem row (iret_12_2__ended (MkState wm tables) rows)
          inEnded = lcyc_1_1__elem_filter_fwd (\row => not (iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm)) rows e (iret_12__not_false _ nq)
          inTargets : Elem i (iret_12_4__targets es)
          inTargets = replace {p = \j => Elem j (map rtarget es)} ti (lcyc_1_1__elem_map_fwd rtarget (replace {p = \l => Elem row l} en inEnded))
          notZero : ((iret_12_1__count (iret_12_2__kept (MkState wm tables) rows) i == 0) = False)
          notZero = iret_12__bool_false_of _ (\z => nz (lcyc_1_1__elem_filter_fwd (\f => iret_12_1__count (iret_12_2__kept (MkState wm tables) rows) f == 0) (map rtarget es) inTargets z))
      in iret_12_1__count_row (iret_12_2__kept (MkState wm tables) rows) i (lcyc_1_1__nat_neq_false _ 0 notZero)

-- ---------------------------------------------------------------------
-- Surviving a retraction
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| A live fact whose id is not retracted survives.
export
iret_12_2__survives : (gone : List Nat) -> (wm : Rarc_5_6_4__wm) -> (g : Lfac_1_7_1__fact) -> Elem g wm -> Not (Elem (fid g) gone) ->
                      Elem g (iret_12_2__retract_ids gone wm)
iret_12_2__survives gone wm g e ng =
  lcyc_1_1__elem_filter_fwd (\f => not (rarc_5_6_5__elem (fid f) gone)) wm e
    (iret_12__not_false _ (iret_12__bool_false_of _ (\t => ng (lcyc_1_1__elem_l_elem (fid g) gone t))))

--@derives [IRET.12.2]
||| A survivor was live, with an id not retracted.
export
iret_12_2__survives_inv : (gone : List Nat) -> (wm : Rarc_5_6_4__wm) -> (g : Lfac_1_7_1__fact) -> Elem g (iret_12_2__retract_ids gone wm) ->
                          (Elem g wm, Not (Elem (fid g) gone))
iret_12_2__survives_inv gone wm g e =
  let (ew, nt) = lcyc_1_1__elem_filter_inv (\f => not (rarc_5_6_5__elem (fid f) gone)) wm e
  in (ew, \eg => lcyc_1_1__elem_l_false_not (fid g) gone (lcyc_1_1__not_true_is_false _ nt) eg)

--@derives [IRET.12.2]
||| An id live after a retraction was live before.
export
iret_12_2__live_before : (gone : List Nat) -> (wm : Rarc_5_6_4__wm) -> (i : Nat) ->
                         iret_12__elem i (iret_11_3__fact_ids (iret_12_2__retract_ids gone wm)) = True -> iret_12__elem i (iret_11_3__fact_ids wm) = True
iret_12_2__live_before gone wm i e = case iret_12_4__live_id i (iret_12_2__retract_ids gone wm) e of
  (g ** (eg, eq)) => replace {p = \j => iret_12__elem j (iret_11_3__fact_ids wm) = True} eq
                       (iret_12_4__id_live g wm (fst (iret_12_2__survives_inv gone wm g eg)))

--@derives [IRET.12.4]
||| A row's reading survives a retraction: a fact of it live afterwards is
||| the same fact, by uniqueness of ids.
export
iret_12_4__row_facts_retract : (gone : List Nat) -> (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (p : Lcyc_3_2_1__program) -> (row : Iret_12_4__row) ->
                               Iret_12_4__row_facts p wm row -> Iret_12_4__row_facts p (iret_12_2__retract_ids gone wm) row
iret_12_4__row_facts_retract gone wm uniq p row (r ** (fs ** (nr, ids, kinds, gd, liv))) =
  (r ** (fs ** (nr, ids, kinds, gd,
    lcyc_1_1__all_imp fs (\f, h, isl =>
      case rarc_5_6_4__is_live_inv (fid f) (iret_12_2__retract_ids gone wm) isl of
        (g ** (eg, eq)) =>
          let (egw, ng) = iret_12_2__survives_inv gone wm g eg
              fw : Elem f wm
              fw = h (replace {p = \j => rarc_5_6_4__is_live j wm = True} eq (rarc_5_6_4__is_live_of g wm egw))
              fg : (f = g)
              fg = uniq f g fw egw (sym eq)
          in replace {p = \x => Elem x (iret_12_2__retract_ids gone wm)} (sym fg) eg) liv)))

--@derives [IRET.12.2]
||| A target live after a retraction was live before.
export
iret_12_2__is_live_before : (gone : List Nat) -> (wm : Rarc_5_6_4__wm) -> (i : Nat) ->
                            rarc_5_6_4__is_live i (iret_12_2__retract_ids gone wm) = True -> rarc_5_6_4__is_live i wm = True
iret_12_2__is_live_before gone wm i isl = case rarc_5_6_4__is_live_inv i (iret_12_2__retract_ids gone wm) isl of
  (g ** (eg, eq)) => replace {p = \j => rarc_5_6_4__is_live j wm = True} eq (rarc_5_6_4__is_live_of g wm (fst (iret_12_2__survives_inv gone wm g eg)))

--@derives [LDET.5.9]
||| A refreshed token that is fired and unblocked was fired and unblocked:
||| refreshing never sets `fired`, and unblocking clears it.
export
ldet_5_9__refresh_live_inv : (blk : Bool) -> (t : Iret_11__tok) -> fired (ldet_5_9__refresh_with blk t) = True ->
                             blocked (ldet_5_9__refresh_with blk t) = False -> (fired t = True, blocked t = False)
ldet_5_9__refresh_live_inv False (MkTok fs True False) _ _ = (Refl, Refl)
ldet_5_9__refresh_live_inv False (MkTok fs False False) fr _ = absurd fr
ldet_5_9__refresh_live_inv False (MkTok fs fr True) fr' _ = absurd fr'
ldet_5_9__refresh_live_inv True t _ bl = absurd bl

--@derives [IRET.7.8]
||| A live activation after propagation was live before: an added token
||| is unfired, so the live token was kept, and a kept token keeps its
||| identity and its `fired`.
export
iret_7_8__live_before_propagate : (p : Lcyc_3_2_1__program) -> (wm' : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (row : Iret_12_4__row) ->
                                  iret_7_8__activation_live (rarc_5_6_5__propagate p wm' tables) row = True ->
                                  iret_7_8__activation_live tables row = True
iret_7_8__live_before_propagate p wm' tables row act with (rarc_5_6_5__nth (rrule row) (rarc_5_6_5__propagate p wm' tables)) proof nt'
  iret_7_8__live_before_propagate p wm' tables row act | Nothing = absurd act
  iret_7_8__live_before_propagate p wm' tables row act | Just ts' =
    let (r ** (ts ** (nr, nt, eq))) = lcyc_1_1__nth_zip_with_inv (\q, tq => rarc_5_6_5__prop_rule q wm' tq) (rrule row) (rules p) tables nt'
    in let (t' ** (te', ok')) = iret_12_2__any_true (\t => (iret_11_3__ids t == rids row) && (fired t && not (blocked t))) ts' act
    in let (t0 ** (te0, req)) = lcyc_1_1__elem_map_inv (ldet_5_9__refresh_tok r (iret_7_9__neg_facts r wm'))
                                  (iret_8_1__kept_of (iret_7_4__match_tuples r wm') ts ++ iret_8_1__added_of (iret_7_4__match_tuples r wm') ts)
                                  (replace {p = \l => Elem t' l} eq te')
    in let idsEq : (iret_11_3__ids t' = rids row)
           idsEq = lcyc_1_1__list_nat_eq_true _ _ (lcyc_1_1__and_true_l _ _ ok')
           firedT' : (fired t' = True)
           firedT' = lcyc_1_1__and_true_l _ _ (lcyc_1_1__and_true_r _ _ ok')
           unbl' : (blocked t' = False)
           unbl' = lcyc_1_1__not_true_is_false _ (lcyc_1_1__and_true_r _ _ (lcyc_1_1__and_true_r _ _ ok'))
    in let (fired0, unbl0) = ldet_5_9__refresh_live_inv (iret_7_9__is_blocked_with (iret_7_9__blockers r) (iret_7_9__neg_facts r wm') (tfacts t0)) t0
                               (replace {p = \x => fired x = True} (sym req) firedT') (replace {p = \x => blocked x = False} (sym req) unbl')
    in case lcyc_1_1__elem_append_inv (iret_8_1__kept_of (iret_7_4__match_tuples r wm') ts) te0 of
         Left inKept =>
           let (te, _) = lcyc_1_1__elem_filter_inv (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids (iret_7_4__match_tuples r wm'))) ts inKept
           in let ids0 : (iret_11_3__ids t0 = rids row)
                  ids0 = trans (cong iret_11_3__ids req) idsEq
           in replace {p = \tbl => rarc_5_6_5__any (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) tbl = True}
                      (sym (iret_11__table_at_nth (rrule row) tables ts nt))
                      (lcyc_1_1__any_elem (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) ts te
                         (iret_7_8__live_token_ok row t0 ids0 fired0 unbl0))
         Right inAdded =>
           let (fs ** (_, feq)) = lcyc_1_1__elem_map_inv iret_8_1__fresh_tok _ inAdded
           in absurd (replace {p = \x => fired x = True} (sym feq) fired0)

-- ---------------------------------------------------------------------
-- Preservation through one phase
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| A fact of Refcount's cascade is never zeroed by a phase: it is base,
||| and then no row targets it while an ended one does; or it is supported
||| in the cascade, and the supporting row is a kept activation.
export
iret_12_2__cascade_not_zeroed : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                                (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows ->
                                (es : Iret_12_4__table) -> iret_12_2__ended (MkState wm tables) rows = es -> (i : Nat) ->
                                iret_12__elem i (iret_12_2__cascade (iret_12_2__base rows0 live0) (iret_12_4__justifs rows0) live0) = True ->
                                Not (Elem i (iret_12_2__zeroed es (iret_12_2__kept (MkState wm tables) rows)))
iret_12_2__cascade_not_zeroed p dom rows0 live0 wm tables rows inv es en i ic ez =
  let (inT, z) = lcyc_1_1__elem_filter_inv (\f => iret_12_1__count (iret_12_2__kept (MkState wm tables) rows) f == 0) (map rtarget es) ez
  in case iret_12_2__cascade_closed (iret_12_2__base rows0 live0) (iret_12_4__justifs rows0) live0 i ic of
       Left ib =>
         let (_, nt) = iret_12__elem_filter_inv (\j => not (iret_12__elem j (iret_12_4__targets rows0))) live0 i ib
             (row ** (er, ti)) = lcyc_1_1__elem_map_inv rtarget es inT
             inRows0 : Elem row rows0
             inRows0 = rowsSub inv row (fst (lcyc_1_1__elem_filter_inv (\row => not (iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm)) rows
                                              (replace {p = \l => Elem row l} (sym en) er)))
             hit : (iret_12__elem i (iret_12_4__targets rows0) = True)
             hit =iret_12__elem_true i (map rtarget rows0) (replace {p = \j => Elem j (map rtarget rows0)} ti (lcyc_1_1__elem_map_fwd rtarget inRows0))
         in lcyc_1_1__bool_not_both _ hit (iret_12__not_true _ nt)
       Right sup =>
         let (j ** (ej, tj, aj)) = iret_12_1__supported_inv (iret_12_4__justifs rows0) (iret_12_2__cascade (iret_12_2__base rows0 live0) (iret_12_4__justifs rows0) live0) i sup
             (row ** (er0, rj)) = lcyc_1_1__elem_map_inv (\row => MkJustif (rids row) (rtarget row)) rows0 ej
             anteEq : (ante j = rids row)
             anteEq = cong ante (sym rj)
             targEq : (rtarget row = i)
             targEq = trans (cong target rj) tj
             allLive : (iret_12__all_in (rids row) (iret_11_3__fact_ids wm) = True)
             allLive = iret_12__all_in_sub (rids row) _ (iret_11_3__fact_ids wm) (gfpSub inv)
                         (replace {p = \as => iret_12__all_in as (iret_12_2__cascade (iret_12_2__base rows0 live0) (iret_12_4__justifs rows0) live0) = True} anteEq aj)
         in let (g ** (eg, geq)) = iret_12_4__live_id i wm (gfpSub inv i ic)
         in let tl : (rarc_5_6_4__is_live (rtarget row) wm = True)
                tl = replace {p = \j => rarc_5_6_4__is_live j wm = True} (trans geq (sym targEq)) (rarc_5_6_4__is_live_of g wm eg)
         in let (er, act) = rowLive inv row er0 allLive tl
         in let inKept : Elem row (iret_12_2__kept (MkState wm tables) rows)
                inKept = lcyc_1_1__elem_filter_fwd (\row => iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm) rows er (iret_12__and_both _ _ act tl)
         in iret_12__elem_nonempty (filter (\r => rtarget r == i) (iret_12_2__kept (MkState wm tables) rows))
              (lcyc_1_1__elem_filter_fwd (\r => rtarget r == i) (iret_12_2__kept (MkState wm tables) rows) inKept
                 (replace {p = \j => (rtarget row == j) = True} targEq (lcyc_1_1__nat_eq_refl (rtarget row))))
              (lcyc_1_1__nat_eq_true _ 0 z)

--@derives [IRET.12.2]
||| A phase that ends activations but zeroes nothing keeps the invariant
||| with the surviving rows.
export
iret_12_2__drop_preserves : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                            (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows ->
                            (es : Iret_12_4__table) -> iret_12_2__ended (MkState wm tables) rows = es ->
                            iret_12_2__zeroed es (iret_12_2__kept (MkState wm tables) rows) = [] ->
                            Iret_12_2__cascade_inv p dom rows0 live0 wm tables (iret_12_2__kept (MkState wm tables) rows)
iret_12_2__drop_preserves p dom rows0 live0 wm tables rows inv es en gz =
  MkCascadeInv (coreInv inv) (uniq inv)
    (\row, e => rowsSub inv row (fst (lcyc_1_1__elem_filter_inv (\row => iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm) rows e)))
    (liveSub inv)
    (rowFacts inv)
    (\row, e0, al, tl => let (er, act) = rowLive inv row e0 al tl
                         in (lcyc_1_1__elem_filter_fwd (\row => iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm) rows er (iret_12__and_both _ _ act tl), act))
    (gfpSub inv)
    (\i, li, nb => iret_12_2__target_kept wm tables rows es en i (hasRow inv i li nb)
                     (\ez => absurd (replace {p = \l => Elem i l} gz ez)))

--@derives [IRET.12.2]
||| A phase that retracts keeps the invariant: the core invariant by
||| propagation, uniqueness and the row readings by filtering, the live
||| activations by the token lemma, the cascade by `cascade_not_zeroed`.
export
iret_12_2__retract_preserves : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                               (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                               Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows ->
                               (es : Iret_12_4__table) -> iret_12_2__ended (MkState wm tables) rows = es ->
                               (gone : List Nat) -> iret_12_2__zeroed es (iret_12_2__kept (MkState wm tables) rows) = gone ->
                               Iret_12_2__cascade_inv p dom rows0 live0 (iret_12_2__retract_ids gone wm)
                                 (rarc_5_6_5__propagate p (iret_12_2__retract_ids gone wm) tables) (iret_12_2__kept (MkState wm tables) rows)
iret_12_2__retract_preserves p pos dom rows0 live0 wm tables rows inv es en gone gz =
  let notGone : (i : Nat) -> Elem i gone -> Elem i (iret_12_2__zeroed es (iret_12_2__kept (MkState wm tables) rows))
      notGone i e = replace {p = \l => Elem i l} (sym gz) e
      rowFacts' : (row : Iret_12_4__row) -> Elem row rows0 -> iret_7_8__activation_live tables row = True -> Iret_12_4__row_facts p (iret_12_2__retract_ids gone wm) row
      rowFacts' row e act = iret_12_4__row_facts_retract gone wm (uniq inv) p row (rowFacts inv row e act)
  in MkCascadeInv
       (lcyc_1_1__propagate_inv p dom (MkState wm tables) (coreInv inv) (iret_12_2__retract_ids gone wm)
          (lcyc_1_1__all_filter (\f => not (rarc_5_6_5__elem (fid f) gone)) wm (wmDom (coreInv inv))))
       (\f, g, ef, eg, eq => uniq inv f g (fst (iret_12_2__survives_inv gone wm f ef)) (fst (iret_12_2__survives_inv gone wm g eg)) eq)
       (\row, e => rowsSub inv row (fst (lcyc_1_1__elem_filter_inv (\row => iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm) rows e)))
       (\i, li => liveSub inv i (iret_12_2__live_before gone wm i li))
       (\row, e0, act' => rowFacts' row e0 (iret_7_8__live_before_propagate p (iret_12_2__retract_ids gone wm) tables row act'))
       (\row, e0, al, tl' =>
          let (er, act) = rowLive inv row e0 (iret_12__all_in_sub (rids row) _ _ (iret_12_2__live_before gone wm) al)
                            (iret_12_2__is_live_before gone wm (rtarget row) tl')
              inKept : Elem row (iret_12_2__kept (MkState wm tables) rows)
              inKept = lcyc_1_1__elem_filter_fwd (\row => iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm) rows er
                         (iret_12__and_both _ _ act (iret_12_2__is_live_before gone wm (rtarget row) tl'))
          in ( inKept
             , iret_7_8__live_after_propagate p pos dom (MkState wm tables) (coreInv inv) (iret_12_2__retract_ids gone wm) row (rowFacts' row e0 act) al act ))
       (\i, ic => case iret_12_4__live_id i wm (gfpSub inv i ic) of
          (g ** (eg, eq)) =>
            replace {p = \j => iret_12__elem j (iret_11_3__fact_ids (iret_12_2__retract_ids gone wm)) = True} eq
              (iret_12_4__id_live g (iret_12_2__retract_ids gone wm)
                 (iret_12_2__survives gone wm g eg
                    (\e => iret_12_2__cascade_not_zeroed p dom rows0 live0 wm tables rows inv es en i ic
                             (notGone i (replace {p = \j => Elem j gone} eq e))))))
       (\i, li, nb => case iret_12_4__live_id i (iret_12_2__retract_ids gone wm) li of
          (g ** (eg, eq)) =>
            let (egw, ng) = iret_12_2__survives_inv gone wm g eg
            in iret_12_2__target_kept wm tables rows es en i (hasRow inv i (iret_12_2__live_before gone wm i li) nb)
                 (\ez => ng (replace {p = \j => Elem j gone} (sym eq) (replace {p = \l => Elem i l} gz ez))))

--@derives [IRET.12.2]
||| After the endings, the phase's remainder keeps the invariant.
export
iret_12_2__phase_after_preserves : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                                   (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                   Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows ->
                                   (es : Iret_12_4__table) -> iret_12_2__ended (MkState wm tables) rows = es ->
                                   (wm' ** (tables' ** (rows' **
                                     ( iret_12_2__phase_after p wm tables (iret_12_2__kept (MkState wm tables) rows) (iret_12_2__zeroed es (iret_12_2__kept (MkState wm tables) rows))
                                         = MkTms (MkState wm' tables') rows'
                                     , Iret_12_2__cascade_inv p dom rows0 live0 wm' tables' rows' ))))
iret_12_2__phase_after_preserves p pos dom rows0 live0 wm tables rows inv es en with (iret_12_2__zeroed es (iret_12_2__kept (MkState wm tables) rows)) proof gz
  iret_12_2__phase_after_preserves p pos dom rows0 live0 wm tables rows inv es en | [] =
    (wm ** (tables ** (iret_12_2__kept (MkState wm tables) rows ** (Refl, iret_12_2__drop_preserves p dom rows0 live0 wm tables rows inv es en gz))))
  iret_12_2__phase_after_preserves p pos dom rows0 live0 wm tables rows inv es en | (g :: gs) =
    (iret_12_2__retract_ids (g :: gs) wm ** (rarc_5_6_5__propagate p (iret_12_2__retract_ids (g :: gs) wm) tables ** (iret_12_2__kept (MkState wm tables) rows **
      (Refl, iret_12_2__retract_preserves p pos dom rows0 live0 wm tables rows inv es en (g :: gs) gz))))

--@derives [IRET.12.2]
||| PRESERVATION. One phase keeps the invariant.
export
iret_12_2__phase_preserves : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                             (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows ->
                             (wm' ** (tables' ** (rows' **
                               ( iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                               , Iret_12_2__cascade_inv p dom rows0 live0 wm' tables' rows' ))))
iret_12_2__phase_preserves p pos dom rows0 live0 wm tables rows inv with (iret_12_2__ended (MkState wm tables) rows) proof en
  iret_12_2__phase_preserves p pos dom rows0 live0 wm tables rows inv | [] = (wm ** (tables ** (rows ** (Refl, inv))))
  iret_12_2__phase_preserves p pos dom rows0 live0 wm tables rows inv | (x :: xs) =
    iret_12_2__phase_after_preserves p pos dom rows0 live0 wm tables rows inv (x :: xs) en

--@derives [IRET.12.2]
||| And so does any number of phases.
export
iret_12_2__phase_n_preserves : (n : Nat) -> (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                               (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                               Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows ->
                               (wm' ** (tables' ** (rows' **
                                 ( iret_12_2__phase_n n p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                                 , Iret_12_2__cascade_inv p dom rows0 live0 wm' tables' rows' ))))
iret_12_2__phase_n_preserves Z p pos dom rows0 live0 wm tables rows inv = (wm ** (tables ** (rows ** (Refl, inv))))
iret_12_2__phase_n_preserves (S n) p pos dom rows0 live0 wm tables rows inv =
  case iret_12_2__phase_preserves p pos dom rows0 live0 wm tables rows inv of
    (wm1 ** (tables1 ** (rows1 ** (eq, inv1)))) =>
      case iret_12_2__phase_n_preserves n p pos dom rows0 live0 wm1 tables1 rows1 inv1 of
        (wm2 ** (tables2 ** (rows2 ** (eq2, inv2)))) =>
          (wm2 ** (tables2 ** (rows2 ** (trans (iret_12_2__phase_n_succ n p (MkTms (MkState wm tables) rows) (MkState wm1 tables1) rows1 eq) eq2, inv2))))

-- ---------------------------------------------------------------------
-- At the fixpoint: every live fact is base or supported
-- ---------------------------------------------------------------------

--@derives [IRET.7.4]
||| Every enumerated tuple is made of live facts.
export
iret_7_4__tuples_live : (ks : List Nat) -> (w : Rarc_5_6_4__wm) -> All (\fs => All (\f => Elem f w) fs) (iret_7_4__tuples ks w)
iret_7_4__tuples_live [] w = [[]]
iret_7_4__tuples_live (k :: ks) w =
  lcyc_1_1__all_concat_map (\f => map (f ::) (iret_7_4__tuples ks w)) (rarc_5_6_4__facts_of_kind k w)
    (lcyc_1_1__all_from_elem (rarc_5_6_4__facts_of_kind k w)
       (\f, ef => lcyc_1_1__all_map (f ::)
                    (lcyc_1_1__all_imp (iret_7_4__tuples ks w)
                       (\fs, fsl => fst (lcyc_1_1__elem_filter_inv (\g => fkind g == k) w ef) :: fsl)
                       (iret_7_4__tuples_live ks w))))

--@derives [IRET.7.8]
||| A live activation's identity is a current match's ids, all live: its
||| token is settled, so its facts are an enumerated tuple of live facts.
export
iret_7_8__live_activation_facts : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (st : Rarc_5_6_5__state) -> Lcyc_1_1__inv p dom st ->
                                  (row : Iret_12_4__row) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth (rrule row) (rules p) = Just r ->
                                  iret_7_8__activation_live (toks st) row = True ->
                                  iret_12__all_in (rids row) (iret_11_3__fact_ids (wm st)) = True
iret_7_8__live_activation_facts p dom st inv row r nr act with (rarc_5_6_5__nth (rrule row) (toks st)) proof nt
  iret_7_8__live_activation_facts p dom st inv row r nr act | Nothing = absurd act
  iret_7_8__live_activation_facts p dom st inv row r nr act | Just ts =
    case iret_12_2__any_true (\t => (iret_11_3__ids t == rids row) && (fired t && not (blocked t))) ts act of
      (t ** (te, ok)) =>
        let (_, inNow) = lcyc_1_1__all_lookup (fst (settled inv (rrule row) r ts nr nt)) te
            idsEq : (iret_11_3__ids t = rids row)
            idsEq = lcyc_1_1__list_nat_eq_true _ _ (lcyc_1_1__and_true_l _ _ ok)
            inNowE : Elem (iret_11_3__ids t) (iret_11_3__now_ids (iret_7_4__match_tuples r (wm st)))
            inNowE = lcyc_1_1__elem_ll_elem _ _ inNow
        in let (fs ** (efs, fsEq)) = lcyc_1_1__elem_map_inv iret_11_3__fact_ids (iret_7_4__match_tuples r (wm st)) inNowE
        in let fsLive : All (\f => Elem f (wm st)) fs
               fsLive = lcyc_1_1__all_lookup (iret_7_4__tuples_live (posKinds r) (wm st)) (fst (lcyc_1_1__elem_filter_inv (guard r) (iret_7_4__tuples (posKinds r) (wm st)) efs))
        in iret_12__all_in_from (rids row) (iret_11_3__fact_ids (wm st)) (\a, ea =>
             case lcyc_1_1__elem_map_inv fid fs (replace {p = \l => Elem a l} (sym (trans fsEq idsEq)) ea) of
               (f ** (ef, fa)) => replace {p = \j => iret_12__elem j (iret_11_3__fact_ids (wm st)) = True} fa
                                    (iret_12_4__id_live f (wm st) (lcyc_1_1__all_lookup fsLive ef)))

--@derives [IRET.12.2]
||| At a phase that ends nothing every live fact is base or supported by a
||| row's activation among the live facts: the live set is self-supported.
export
iret_12_2__fixed_post : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                        (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                        Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows ->
                        iret_12_2__ended (MkState wm tables) rows = [] ->
                        Iret_12__sub (iret_11_3__fact_ids wm) (iret_12_2__cascade_step (iret_12_2__base rows0 live0) (iret_12_4__justifs rows0) (iret_11_3__fact_ids wm))
iret_12_2__fixed_post p dom rows0 live0 wm tables rows inv fixed i li =
  iret_12__elem_filter (\t => iret_12__elem t (iret_12_2__base rows0 live0) || iret_12__supported (iret_12_4__justifs rows0) (iret_11_3__fact_ids wm) t) (iret_11_3__fact_ids wm) i li
    (case iret_12__bool_split (iret_12__elem i (iret_12_2__base rows0 live0)) of
       Left b => iret_12__or_true_l _ _ b
       Right nb => iret_12__or_true_r _ _
         (case hasRow inv i li nb of
            (row ** (e, ti)) =>
              let q : ((iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm) = True)
                  q = lcyc_1_1__not_false_is_true _ (iret_12__filter_nil_all (\row => not (iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm)) rows fixed row e)
                  act : (iret_7_8__activation_live tables row = True)
                  act = lcyc_1_1__and_true_l _ _ q
              in let (r ** (fs ** (nr, ids, kinds, gd, liv))) = rowFacts inv row (rowsSub inv row e) act
              in let allLive : (iret_12__all_in (rids row) (iret_11_3__fact_ids wm) = True)
                     allLive = iret_7_8__live_activation_facts p dom (MkState wm tables) (coreInv inv) row r nr act
              in replace {p = \j => iret_12__supported (iret_12_4__justifs rows0) (iret_11_3__fact_ids wm) j = True} ti
                   (iret_12_1__supported_of (iret_12_4__justifs rows0) (iret_11_3__fact_ids wm) (MkJustif (rids row) (rtarget row))
                      (lcyc_1_1__elem_map_fwd (\row => MkJustif (rids row) (rtarget row)) (rowsSub inv row e)) allLive)))

-- ---------------------------------------------------------------------
-- THE BRIDGE
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| THE BRIDGE THEOREM. Start a cascade in a settled state with unique
||| ids, whose live rows read as matches and whose rows with live
||| antecedents and a live target are live activations. Then the cascade
||| reaches a fixpoint within its fuel, and the ids live there are exactly
||| Rete/Refcount.idr's cascade of the engine's own table, read over the
||| ids live at the start with the never-justified ones as base. Positive
||| programs.
export
iret_12_2__bridge : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                    (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                    Lcyc_1_1__inv p dom (MkState wm tables) -> Iret_4_4__unique wm ->
                    ((row : Iret_12_4__row) -> Elem row rows -> iret_7_8__activation_live tables row = True -> Iret_12_4__row_facts p wm row) ->
                    ((row : Iret_12_4__row) -> Elem row rows -> iret_12__all_in (rids row) (iret_11_3__fact_ids wm) = True ->
                       rarc_5_6_4__is_live (rtarget row) wm = True -> iret_7_8__activation_live tables row = True) ->
                    (wmF ** (tablesF ** (rowsF **
                      ( iret_12_2__phase p (MkTms (MkState wm tables) rows) = MkTms (MkState wmF tablesF) rowsF
                      , Iret_12__sub (iret_11_3__fact_ids wmF)
                                     (iret_12_2__cascade (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
                      , Iret_12__sub (iret_12_2__cascade (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
                                     (iret_11_3__fact_ids wmF)
                      , iret_12_2__ended (MkState wmF tablesF) rowsF = [] ))))
iret_12_2__bridge p pos dom wm tables rows cinv uq rf rl =
  let inv0 : Iret_12_2__cascade_inv p dom rows (iret_11_3__fact_ids wm) wm tables rows
      inv0 = MkCascadeInv cinv uq (\row, e => e) (\i, e => e) rf
               (\row, e, al, tl => (e, rl row e al tl))
               (iret_12_2__cascade_sub (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
               (iret_12_2__base_row rows (iret_11_3__fact_ids wm))
  in case iret_12_2__phase_n_preserves (S (length rows)) p pos dom rows (iret_11_3__fact_ids wm) wm tables rows inv0 of
       (wmF ** (tablesF ** (rowsF ** (eq, invF)))) =>
         let fixed : (iret_12_2__ended (MkState wmF tablesF) rowsF = [])
             fixed =replace {p = \x => iret_12_2__ended (core x) (deps x) = []} eq
                       (iret_12_2__phase_n_fixed (S (length rows)) p wm tables rows (iret_12__lte_succ_self (length rows)))
         in (wmF ** (tablesF ** (rowsF **
              ( eq
              , iret_12_2__cascade_greatest (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm) (iret_11_3__fact_ids wmF)
                  (liveSub invF) (iret_12_2__fixed_post p dom rows (iret_11_3__fact_ids wm) wmF tablesF rowsF invF fixed)
              , gfpSub invF
              , fixed ))))

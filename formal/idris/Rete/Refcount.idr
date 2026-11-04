-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The justification refcount of [IRET.12] over a justification graph that
||| may contain cycles — the case the other models never draw
||| (tms_justification.als is a snapshot; tms_cascade.tla hardwires an
||| acyclic support graph, see its header).
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr.
||| [LLOG.2.5] is the contract: a `logical` fact goes when its LAST
||| justification goes, read well-foundedly. [IRET.12.2] states that
||| obligation and keeps the justification count as libds's mechanism,
||| correct because [LCYC.3.1.1] makes support acyclic on every admitted
||| program. So the `iret_12_2__` elements model the count and its cascade
||| (the clause's steps 1-4 and its "correct only because support is
||| acyclic"), the `llog_2_5__` elements the well-founded contract, and the
||| theorems below say exactly where the two part. [IRET.12.3]'s
||| multiple-justifier fact is the ranked case; the ranking definition and
||| its exactness theorem are named under it for that reason.
|||
||| This file is standalone: it imports only the base library and relies
||| on nothing another module establishes.
|||
||| THE MODEL. Facts are naturals. Some are BASE (externally asserted,
||| never touched by the cascade). A justification is a rule activation
||| that emitted a `logical` fact: its antecedents (the facts its LHS
||| matched) and its target. `justif_count F` [IRET.12.1] is the number of
||| justifications of F whose antecedents are all live. An activation ends
||| when an antecedent is retracted [IRET.12.2]; a fact whose count hits
||| zero is retracted, and the retraction cascades. So one cascade STEP
||| keeps exactly the live facts that are base or currently supported, and
||| the cascade iterates that to a fixpoint. The engine's bookkeeping does
||| this incrementally; the fixpoint it reaches is the same.
|||
||| THE TWO FIXPOINTS. `llog_2_5__well_founded` computes what the contract
||| keeps live: the least fixpoint of support, built up from the base facts.
||| `iret_12_2__cascade` computes what the count LEAVES live after every
||| base retraction has been applied: the greatest fixpoint of support
||| below the current live set. They agree exactly when no unfounded set
||| exists — a nonempty set of derived facts every one of which is
||| supported only through the set itself. On a ranked support graph they
||| agree (`iret_12_3__ranked_agree`); that every admitted program's support
||| graph is ranked is [IRET.12.2]'s own sentence, proved on the engine by
||| Rete/RecomputeDiff.idr's `iret_12_3__certified_ranked`, not here.
|||
||| WHAT IS PROVED, all of it mechanized:
|||
|||   * Both iterations reach their fixpoint within their fuel
|||     (`iret_12_2__cascade_fixed`, `llog_2_5__wf_fixed`), by one counting
|||     fact: a filter that changes something is strictly shorter.
|||   * The cascade is the GREATEST self-supported subset of the live set
|||     (`iret_12_2__cascade_greatest`); the well-founded set is the LEAST
|||     closed superset of the base facts (`llog_2_5__wf_least`), and is
|||     monotone in the base facts (`llog_2_5__wf_mono_base`): a withdrawal
|||     of inputs only ever retracts derived facts.
|||   * The cascade never retracts a well-founded fact
|||     (`llog_2_5__wf_in_cascade`), and what it keeps beyond the
|||     well-founded set is an unfounded set (`iret_12_2__cascade_unfounded`);
|||     conversely an unfounded set among the survivors is disjoint from
|||     the well-founded set (`llog_2_5__unfounded_disagrees`). The two agree
|||     exactly when no unfounded set survives.
|||   * On a ranked (acyclic) support graph the refcount is exact
|||     (`iret_12_3__ranked_exact`, `iret_12_3__ranked_agree`) — the scope
|||     tms_cascade.tla covers, now a theorem rather than an instance.
|||   * Stratified recomputation composes (`llog_2_5__stratified_compose`):
|||     recomputing an upper stratum over a lower stratum's recomputed
|||     output is the global recompute.
|||
||| The executed witnesses remain: the smallest unfounded cycle
||| (`iret_12_2__witness_refcount` / `llog_2_5__witness_well_founded`), the
||| `+recursive` proposal's shape (`iret_12_2__reach_refcount` /
||| `llog_2_5__reach_well_founded`), the TLA+ instance
||| (`iret_12_2__tla_retract_f1` / `iret_12_2__tla_retract_both`), and two
||| recursive strata composing (`llog_2_5__strata_*`,
||| `iret_12_2__strata_refcount`).
module Rete.Refcount

import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

--@spec [IRET.12]
public export
Iret_12__fact : Type
Iret_12__fact = Nat

--@spec [IRET.12.1]
||| A justification: the antecedents a rule activation matched, and the
||| `logical` fact it emitted.
public export
record Iret_12_1__justif where
  constructor MkJustif
  ante   : List Iret_12__fact
  target : Iret_12__fact

--@spec [IRET.12]
public export
iret_12__elem : Nat -> List Nat -> Bool
iret_12__elem x [] = False
iret_12__elem x (y :: ys) = if y == x then True else iret_12__elem x ys

--@spec [IRET.12]
public export
iret_12__all_in : List Iret_12__fact -> List Iret_12__fact -> Bool
iret_12__all_in [] live = True
iret_12__all_in (a :: as) live = if iret_12__elem a live then iret_12__all_in as live else False

--@spec [IRET.12]
--@spec [IRET.12.1]
||| A fact is supported by `live` when some justification targets it and
||| has every antecedent in `live` — `justif_count > 0`, counted against
||| `live` [IRET.12].
public export
iret_12__supported : List Iret_12_1__justif -> List Iret_12__fact -> Iret_12__fact -> Bool
iret_12__supported [] live t = False
iret_12__supported (j :: js) live t =
  if (target j == t) && iret_12__all_in (ante j) live then True else iret_12__supported js live t

-- ---------------------------------------------------------------------
-- What the refcount leaves: the cascade, a downward iteration
-- ---------------------------------------------------------------------

--@spec [IRET.12.2]
||| One cascade step [IRET.12.2]: every live derived fact whose count is
||| zero against the current live set is retracted, all at once.
public export
iret_12_2__cascade_step : List Iret_12__fact -> List Iret_12_1__justif -> List Iret_12__fact -> List Iret_12__fact
iret_12_2__cascade_step base js live = filter (\t => iret_12__elem t base || iret_12__supported js live t) live

--@spec [IRET.12.2]
||| Iterate to the fixpoint. `fuel` = the number of live facts suffices:
||| a step that changes anything removes at least one fact.
public export
iret_12_2__cascade_n : Nat -> List Iret_12__fact -> List Iret_12_1__justif -> List Iret_12__fact -> List Iret_12__fact
iret_12_2__cascade_n Z base js live = live
iret_12_2__cascade_n (S n) base js live = iret_12_2__cascade_n n base js (iret_12_2__cascade_step base js live)

--@spec [IRET.12.2]
public export
iret_12_2__cascade : List Iret_12__fact -> List Iret_12_1__justif -> List Iret_12__fact -> List Iret_12__fact
iret_12_2__cascade base js live = iret_12_2__cascade_n (length live) base js live

-- ---------------------------------------------------------------------
-- What should be live: well-founded support, an upward iteration
-- ---------------------------------------------------------------------

--@spec [LLOG.2.5]
||| One derivation round from what is known, restricted to the universe
||| `all` of facts under consideration.
public export
llog_2_5__derive_step : List Iret_12__fact -> List Iret_12_1__justif -> List Iret_12__fact -> List Iret_12__fact -> List Iret_12__fact
llog_2_5__derive_step base js univ known = filter (\t => iret_12__elem t base || iret_12__supported js known t) univ

--@spec [LLOG.2.5]
public export
llog_2_5__derive_n : Nat -> List Iret_12__fact -> List Iret_12_1__justif -> List Iret_12__fact -> List Iret_12__fact -> List Iret_12__fact
llog_2_5__derive_n Z base js univ known = known
llog_2_5__derive_n (S n) base js univ known = llog_2_5__derive_n n base js univ (llog_2_5__derive_step base js univ known)

--@spec [LLOG.2.5]
--@spec [LLOG.15.1]
||| The least fixpoint: iterate from the base facts alone.
public export
llog_2_5__well_founded : List Iret_12__fact -> List Iret_12_1__justif -> List Iret_12__fact -> List Iret_12__fact
llog_2_5__well_founded base js univ = llog_2_5__derive_n (length univ) base js univ (filter (\t => iret_12__elem t base) univ)

-- ---------------------------------------------------------------------
-- The witness: mutual support survives the loss of its only real source
-- ---------------------------------------------------------------------

--@spec [LLOG.2.5]
||| Facts: 0 is the base fact P; 1 is Q; 2 is R.
||| Rules: P -> emit Q logical;  Q -> emit R logical;  R -> emit Q logical.
||| After P is retracted, Q keeps one live justifier (the R activation)
||| and R keeps one (the Q activation): justif_count never reaches zero.
export
llog_2_5__witness_js : List Iret_12_1__justif
llog_2_5__witness_js = [MkJustif [0] 1, MkJustif [1] 2, MkJustif [2] 1]

--@derives [LLOG.2.5]
||| Before the retraction everything is live and well-founded.
export
llog_2_5__witness_before : llog_2_5__well_founded [0] Rete.Refcount.llog_2_5__witness_js [0, 1, 2] = [0, 1, 2]
llog_2_5__witness_before = Refl

--@derives [IRET.12.2]
--@derives [LLOG.2.5]
||| After P (0) is retracted: no base facts remain; the refcount cascade
||| retracts nothing, the well-founded answer retracts everything.
export
iret_12_2__witness_refcount : iret_12_2__cascade [] Rete.Refcount.llog_2_5__witness_js [1, 2] = [1, 2]
iret_12_2__witness_refcount = Refl

--@derives [LLOG.2.5]
export
llog_2_5__witness_well_founded : llog_2_5__well_founded [] Rete.Refcount.llog_2_5__witness_js [1, 2] = []
llog_2_5__witness_well_founded = Refl

--@spec [LLOG.2.5]
||| The same shape as the cycle-admission proposal's motivating use: a seed
||| fact 3 (Reach0) emits Reach(a,b) = 1; Reach(a,b) + Edge(b,a) = 4
||| derives Reach(a,a) = 2; Reach(a,a) + Edge(a,b) = 5 re-derives
||| Reach(a,b). Withdraw the seed while both edges stay: both Reach facts
||| survive with nothing founding them.
export
llog_2_5__reach_js : List Iret_12_1__justif
llog_2_5__reach_js = [MkJustif [3] 1, MkJustif [1, 4] 2, MkJustif [2, 5] 1]

--@derives [IRET.12.2]
--@derives [LLOG.2.5]
export
iret_12_2__reach_refcount : iret_12_2__cascade [4, 5] Rete.Refcount.llog_2_5__reach_js [1, 2, 4, 5] = [1, 2, 4, 5]
iret_12_2__reach_refcount = Refl

--@derives [LLOG.2.5]
export
llog_2_5__reach_well_founded : llog_2_5__well_founded [4, 5] Rete.Refcount.llog_2_5__reach_js [1, 2, 4, 5] = [4, 5]
llog_2_5__reach_well_founded = Refl

-- ---------------------------------------------------------------------
-- Soundness: the cascade never retracts a well-founded fact
-- ---------------------------------------------------------------------

--@derives [IRET.12]
export
iret_12__nat_eq_refl : (n : Nat) -> (n == n) = True
iret_12__nat_eq_refl Z = Refl
iret_12__nat_eq_refl (S n) = iret_12__nat_eq_refl n

--@derives [IRET.12]
export
iret_12__elem_true : (x : Nat) -> (xs : List Nat) -> Elem x xs -> iret_12__elem x xs = True
iret_12__elem_true x (x :: xs) Here = rewrite iret_12__nat_eq_refl x in Refl
iret_12__elem_true x (y :: xs) (There e) with (y == x)
  iret_12__elem_true x (y :: xs) (There e) | True = Refl
  iret_12__elem_true x (y :: xs) (There e) | False = iret_12__elem_true x xs e

--@derives [IRET.12]
export
iret_12__nat_eq_true : (a, b : Nat) -> (a == b) = True -> a = b
iret_12__nat_eq_true Z Z _ = Refl
iret_12__nat_eq_true Z (S _) prf = absurd prf
iret_12__nat_eq_true (S _) Z prf = absurd prf
iret_12__nat_eq_true (S a) (S b) prf = cong S (iret_12__nat_eq_true a b prf)

--@derives [IRET.12]
export
iret_12__elem_elem : (x : Nat) -> (xs : List Nat) -> iret_12__elem x xs = True -> Elem x xs
iret_12__elem_elem x [] prf = absurd prf
iret_12__elem_elem x (y :: xs) prf with (y == x) proof yx
  iret_12__elem_elem x (y :: xs) prf | True = rewrite sym (iret_12__nat_eq_true y x yx) in Here
  iret_12__elem_elem x (y :: xs) prf | False = There (iret_12__elem_elem x xs prf)

--@spec [IRET.12]
||| Subset, as a Bool-membership implication.
public export
Iret_12__sub : List Iret_12__fact -> List Iret_12__fact -> Type
Iret_12__sub xs ys = (x : Iret_12__fact) -> iret_12__elem x xs = True -> iret_12__elem x ys = True

--@derives [IRET.12]
export
iret_12__all_in_sub : (as, xs, ys : List Iret_12__fact) -> Iret_12__sub xs ys -> iret_12__all_in as xs = True -> iret_12__all_in as ys = True
iret_12__all_in_sub [] xs ys sub prf = Refl
iret_12__all_in_sub (a :: as) xs ys sub prf with (iret_12__elem a xs) proof ax
  iret_12__all_in_sub (a :: as) xs ys sub prf | True = rewrite sub a ax in iret_12__all_in_sub as xs ys sub prf
  iret_12__all_in_sub (a :: as) xs ys sub prf | False = absurd prf

--@derives [IRET.12]
||| Support is monotone in the live set.
export
iret_12__supported_mono : (js : List Iret_12_1__justif) -> (xs, ys : List Iret_12__fact) -> Iret_12__sub xs ys -> (t : Iret_12__fact) ->
                iret_12__supported js xs t = True -> iret_12__supported js ys t = True
iret_12__supported_mono [] xs ys sub t prf = absurd prf
iret_12__supported_mono (j :: js) xs ys sub t prf with (target j == t) proof tj
  iret_12__supported_mono (j :: js) xs ys sub t prf | True with (iret_12__all_in (ante j) xs) proof ax
    iret_12__supported_mono (j :: js) xs ys sub t prf | True | True =
      rewrite iret_12__all_in_sub (ante j) xs ys sub ax in Refl
    iret_12__supported_mono (j :: js) xs ys sub t prf | True | False with (iret_12__all_in (ante j) ys)
      iret_12__supported_mono (j :: js) xs ys sub t prf | True | False | True = Refl
      iret_12__supported_mono (j :: js) xs ys sub t prf | True | False | False = iret_12__supported_mono js xs ys sub t prf
  iret_12__supported_mono (j :: js) xs ys sub t prf | False = iret_12__supported_mono js xs ys sub t prf

--@derives [IRET.12]
export
iret_12__elem_filter : (p : Iret_12__fact -> Bool) -> (xs : List Iret_12__fact) -> (x : Iret_12__fact) ->
              iret_12__elem x xs = True -> p x = True -> iret_12__elem x (filter p xs) = True
iret_12__elem_filter p xs x ex px = iret_12__elem_true x (filter p xs) (go xs (iret_12__elem_elem x xs ex))
  where
    go : (ys : List Iret_12__fact) -> Elem x ys -> Elem x (filter p ys)
    go (_ :: ys) Here = rewrite px in Here
    go (y :: ys) (There e) with (p y)
      go (y :: ys) (There e) | True = There (go ys e)
      go (y :: ys) (There e) | False = go ys e

--@derives [IRET.12]
export
iret_12__elem_filter_inv : (p : Iret_12__fact -> Bool) -> (xs : List Iret_12__fact) -> (x : Iret_12__fact) ->
                 iret_12__elem x (filter p xs) = True -> (iret_12__elem x xs = True, p x = True)
iret_12__elem_filter_inv p [] x prf = absurd prf
iret_12__elem_filter_inv p (y :: xs) x prf with (p y) proof py
  iret_12__elem_filter_inv p (y :: xs) x prf | True with (y == x) proof yx
    iret_12__elem_filter_inv p (y :: xs) x prf | True | True = (Refl, rewrite sym (iret_12__nat_eq_true y x yx) in py)
    iret_12__elem_filter_inv p (y :: xs) x prf | True | False = iret_12__elem_filter_inv p xs x prf
  iret_12__elem_filter_inv p (y :: xs) x prf | False with (y == x)
    iret_12__elem_filter_inv p (y :: xs) x prf | False | True = let (_, px) = iret_12__elem_filter_inv p xs x prf in (Refl, px)
    iret_12__elem_filter_inv p (y :: xs) x prf | False | False = iret_12__elem_filter_inv p xs x prf

--@derives [IRET.12]
export
iret_12__or_true_l : (a, b : Bool) -> a = True -> (a || b) = True
iret_12__or_true_l True b _ = Refl
iret_12__or_true_l False b prf = absurd prf

--@derives [IRET.12]
export
iret_12__or_true_r : (a, b : Bool) -> b = True -> (a || b) = True
iret_12__or_true_r True b _ = Refl
iret_12__or_true_r False b prf = prf

-- ---------------------------------------------------------------------
-- Counting. Everything about fuel rests on one fact: a filter that
-- changes something is strictly shorter than its input.
-- ---------------------------------------------------------------------

--@derives [IRET.12]
export
iret_12__elem_head : (x : Nat) -> (xs : List Nat) -> iret_12__elem x (x :: xs) = True
iret_12__elem_head x xs = iret_12__elem_true x (x :: xs) Here

--@derives [IRET.12]
export
iret_12__elem_tail : (x, y : Nat) -> (xs : List Nat) -> iret_12__elem y xs = True -> iret_12__elem y (x :: xs) = True
iret_12__elem_tail x y xs prf with (x == y)
  iret_12__elem_tail x y xs prf | True = Refl
  iret_12__elem_tail x y xs prf | False = prf

--@derives [IRET.12]
export
iret_12__or_inv : (a, b : Bool) -> (a || b) = True -> Either (a = True) (b = True)
iret_12__or_inv True b prf = Left Refl
iret_12__or_inv False b prf = Right prf

--@derives [IRET.12]
export
iret_12__not_true : (b : Bool) -> not b = True -> b = False
iret_12__not_true False prf = Refl
iret_12__not_true True prf = absurd prf

--@derives [IRET.12]
export
iret_12__not_false : (b : Bool) -> b = False -> not b = True
iret_12__not_false False prf = Refl
iret_12__not_false True prf = absurd prf

--@derives [IRET.12]
export
iret_12__nonempty : (t : Nat) -> (xs : List Nat) -> iret_12__elem t xs = True -> NonEmpty xs
iret_12__nonempty t [] prf = absurd prf
iret_12__nonempty t (x :: xs) prf = IsNonEmpty

--@derives [IRET.12]
export
iret_12__len_zero : (xs : List Nat) -> LTE (length xs) Z -> xs = []
iret_12__len_zero [] _ = Refl
iret_12__len_zero (x :: xs) prf = absurd prf

--@derives [IRET.12]
||| A filter is a subset of its input.
export
iret_12__filter_sub : (p : Nat -> Bool) -> (xs : List Nat) -> Iret_12__sub (filter p xs) xs
iret_12__filter_sub p xs t et = fst (iret_12__elem_filter_inv p xs t et)

--@derives [IRET.12]
export
iret_12__filter_lte : (p : Nat -> Bool) -> (xs : List Nat) -> LTE (length (filter p xs)) (length xs)
iret_12__filter_lte p [] = LTEZero
iret_12__filter_lte p (x :: xs) with (p x)
  iret_12__filter_lte p (x :: xs) | True = LTESucc (iret_12__filter_lte p xs)
  iret_12__filter_lte p (x :: xs) | False = lteSuccRight (iret_12__filter_lte p xs)

--@derives [IRET.12]
||| A filter that changes something is strictly shorter than its input.
export
iret_12__filter_neq_lt : (p : Nat -> Bool) -> (xs : List Nat) -> Not (filter p xs = xs) -> LT (length (filter p xs)) (length xs)
iret_12__filter_neq_lt p [] neq = void (neq Refl)
iret_12__filter_neq_lt p (x :: xs) neq with (p x)
  iret_12__filter_neq_lt p (x :: xs) neq | True = LTESucc (iret_12__filter_neq_lt p xs (\e => neq (cong (x ::) e)))
  iret_12__filter_neq_lt p (x :: xs) neq | False = LTESucc (iret_12__filter_lte p xs)

--@derives [IRET.12]
||| Every member passes the test: the filter is the identity.
export
iret_12__filter_all : (p : Nat -> Bool) -> (xs : List Nat) -> ((y : Nat) -> iret_12__elem y xs = True -> p y = True) -> filter p xs = xs
iret_12__filter_all p [] h = Refl
iret_12__filter_all p (x :: xs) h with (p x) proof px
  iret_12__filter_all p (x :: xs) h | True = cong (x ::) (iret_12__filter_all p xs (\y, ey => h y (iret_12__elem_tail x y xs ey)))
  iret_12__filter_all p (x :: xs) h | False = absurd (trans (sym px) (h x (iret_12__elem_head x xs)))

--@derives [IRET.12]
||| A filter as long as its input is its input.
export
iret_12__filter_full : (p : Nat -> Bool) -> (xs : List Nat) -> LTE (length xs) (length (filter p xs)) -> filter p xs = xs
iret_12__filter_full p [] _ = Refl
iret_12__filter_full p (x :: xs) prf with (p x)
  iret_12__filter_full p (x :: xs) prf | True = cong (x ::) (iret_12__filter_full p xs (fromLteSucc prf))
  iret_12__filter_full p (x :: xs) prf | False = void (succNotLTEpred (transitive prf (iret_12__filter_lte p xs)))

--@derives [IRET.12]
export
iret_12__imp_tail : (q, p : Nat -> Bool) -> (x : Nat) -> (xs : List Nat) ->
                    ((y : Nat) -> iret_12__elem y (x :: xs) = True -> q y = True -> p y = True) ->
                    ((y : Nat) -> iret_12__elem y xs = True -> q y = True -> p y = True)
iret_12__imp_tail q p x xs h y ey qy = h y (iret_12__elem_tail x y xs ey) qy

--@derives [IRET.12]
||| On one list, a filter by a stronger test is no longer than one by a
||| weaker test.
export
iret_12__filter_imp_lte : (q, p : Nat -> Bool) -> (xs : List Nat) ->
                          ((y : Nat) -> iret_12__elem y xs = True -> q y = True -> p y = True) ->
                          LTE (length (filter q xs)) (length (filter p xs))
iret_12__filter_imp_lte q p [] h = LTEZero
iret_12__filter_imp_lte q p (x :: xs) h with (q x) proof qx
  iret_12__filter_imp_lte q p (x :: xs) h | True with (p x) proof px
    iret_12__filter_imp_lte q p (x :: xs) h | True | True = LTESucc (iret_12__filter_imp_lte q p xs (iret_12__imp_tail q p x xs h))
    iret_12__filter_imp_lte q p (x :: xs) h | True | False = absurd (trans (sym px) (h x (iret_12__elem_head x xs) qx))
  iret_12__filter_imp_lte q p (x :: xs) h | False with (p x)
    iret_12__filter_imp_lte q p (x :: xs) h | False | True = lteSuccRight (iret_12__filter_imp_lte q p xs (iret_12__imp_tail q p x xs h))
    iret_12__filter_imp_lte q p (x :: xs) h | False | False = iret_12__filter_imp_lte q p xs (iret_12__imp_tail q p x xs h)

--@derives [IRET.12]
||| And strictly shorter when the two differ.
export
iret_12__filter_imp_lt : (q, p : Nat -> Bool) -> (xs : List Nat) ->
                         ((y : Nat) -> iret_12__elem y xs = True -> q y = True -> p y = True) ->
                         Not (filter q xs = filter p xs) -> LT (length (filter q xs)) (length (filter p xs))
iret_12__filter_imp_lt q p [] h neq = void (neq Refl)
iret_12__filter_imp_lt q p (x :: xs) h neq with (q x) proof qx
  iret_12__filter_imp_lt q p (x :: xs) h neq | True with (p x) proof px
    iret_12__filter_imp_lt q p (x :: xs) h neq | True | True =
      LTESucc (iret_12__filter_imp_lt q p xs (iret_12__imp_tail q p x xs h) (\e => neq (cong (x ::) e)))
    iret_12__filter_imp_lt q p (x :: xs) h neq | True | False = absurd (trans (sym px) (h x (iret_12__elem_head x xs) qx))
  iret_12__filter_imp_lt q p (x :: xs) h neq | False with (p x)
    iret_12__filter_imp_lt q p (x :: xs) h neq | False | True = LTESucc (iret_12__filter_imp_lte q p xs (iret_12__imp_tail q p x xs h))
    iret_12__filter_imp_lt q p (x :: xs) h neq | False | False = iret_12__filter_imp_lt q p xs (iret_12__imp_tail q p x xs h) neq

-- ---------------------------------------------------------------------
-- Justifications: taking support apart and putting it together
-- ---------------------------------------------------------------------

--@derives [IRET.12]
||| Every antecedent live, from a proof per antecedent.
export
iret_12__all_in_from : (as, live : List Iret_12__fact) -> ((a : Iret_12__fact) -> Elem a as -> iret_12__elem a live = True) -> iret_12__all_in as live = True
iret_12__all_in_from [] live h = Refl
iret_12__all_in_from (a :: as) live h with (iret_12__elem a live) proof ea
  iret_12__all_in_from (a :: as) live h | True = iret_12__all_in_from as live (\b, eb => h b (There eb))
  iret_12__all_in_from (a :: as) live h | False = absurd (trans (sym ea) (h a Here))

--@derives [IRET.12]
export
iret_12__all_in_elem : (as, live : List Iret_12__fact) -> iret_12__all_in as live = True -> (a : Iret_12__fact) -> Elem a as -> iret_12__elem a live = True
iret_12__all_in_elem (a :: as) live prf a Here with (iret_12__elem a live)
  iret_12__all_in_elem (a :: as) live prf a Here | True = Refl
  iret_12__all_in_elem (a :: as) live prf a Here | False = absurd prf
iret_12__all_in_elem (b :: as) live prf a (There e) with (iret_12__elem b live)
  iret_12__all_in_elem (b :: as) live prf a (There e) | True = iret_12__all_in_elem as live prf a e
  iret_12__all_in_elem (b :: as) live prf a (There e) | False = absurd prf

--@derives [IRET.12]
||| Not every antecedent live: one that is not.
export
iret_12__all_in_false : (as, live : List Iret_12__fact) -> iret_12__all_in as live = False -> (a ** (Elem a as, iret_12__elem a live = False))
iret_12__all_in_false [] live prf = absurd prf
iret_12__all_in_false (a :: as) live prf with (iret_12__elem a live) proof ea
  iret_12__all_in_false (a :: as) live prf | True = case iret_12__all_in_false as live prf of
    (b ** (e, eb)) => (b ** (There e, eb))
  iret_12__all_in_false (a :: as) live prf | False = (a ** (Here, ea))

--@derives [IRET.12.1]
||| Support taken apart: the justification that provides it.
export
iret_12_1__supported_inv : (js : List Iret_12_1__justif) -> (live : List Iret_12__fact) -> (t : Iret_12__fact) ->
                           iret_12__supported js live t = True ->
                           (j ** (Elem j js, target j = t, iret_12__all_in (ante j) live = True))
iret_12_1__supported_inv [] live t prf = absurd prf
iret_12_1__supported_inv (j :: js) live t prf with (target j == t) proof tj
  iret_12_1__supported_inv (j :: js) live t prf | True with (iret_12__all_in (ante j) live) proof aj
    iret_12_1__supported_inv (j :: js) live t prf | True | True = (j ** (Here, iret_12__nat_eq_true (target j) t tj, aj))
    iret_12_1__supported_inv (j :: js) live t prf | True | False = case iret_12_1__supported_inv js live t prf of
      (j' ** (e, te, ae)) => (j' ** (There e, te, ae))
  iret_12_1__supported_inv (j :: js) live t prf | False = case iret_12_1__supported_inv js live t prf of
    (j' ** (e, te, ae)) => (j' ** (There e, te, ae))

--@derives [IRET.12.1]
||| Support put together: a justification of the list with every
||| antecedent live supports its target.
export
iret_12_1__supported_of : (js : List Iret_12_1__justif) -> (live : List Iret_12__fact) -> (j : Iret_12_1__justif) -> Elem j js ->
                          iret_12__all_in (ante j) live = True -> iret_12__supported js live (target j) = True
iret_12_1__supported_of (_ :: js) live j Here aj with (target j == target j) proof e
  iret_12_1__supported_of (_ :: js) live j Here aj | True with (iret_12__all_in (ante j) live)
    iret_12_1__supported_of (_ :: js) live j Here aj | True | True = Refl
    iret_12_1__supported_of (_ :: js) live j Here aj | True | False = absurd aj
  iret_12_1__supported_of (_ :: js) live j Here aj | False = absurd (trans (sym e) (iret_12__nat_eq_refl (target j)))
iret_12_1__supported_of (j' :: js) live j (There e) aj with ((target j' == target j) && iret_12__all_in (ante j') live)
  iret_12_1__supported_of (j' :: js) live j (There e) aj | True = Refl
  iret_12_1__supported_of (j' :: js) live j (There e) aj | False = iret_12_1__supported_of js live j e aj

--@derives [IRET.12.1]
export
iret_12_1__supported_append_l : (js1, js2 : List Iret_12_1__justif) -> (live : List Iret_12__fact) -> (t : Iret_12__fact) ->
                                iret_12__supported js1 live t = True -> iret_12__supported (js1 ++ js2) live t = True
iret_12_1__supported_append_l [] js2 live t prf = absurd prf
iret_12_1__supported_append_l (j :: js1) js2 live t prf with ((target j == t) && iret_12__all_in (ante j) live)
  iret_12_1__supported_append_l (j :: js1) js2 live t prf | True = Refl
  iret_12_1__supported_append_l (j :: js1) js2 live t prf | False = iret_12_1__supported_append_l js1 js2 live t prf

--@derives [IRET.12.1]
export
iret_12_1__supported_append_r : (js1, js2 : List Iret_12_1__justif) -> (live : List Iret_12__fact) -> (t : Iret_12__fact) ->
                                iret_12__supported js2 live t = True -> iret_12__supported (js1 ++ js2) live t = True
iret_12_1__supported_append_r [] js2 live t prf = prf
iret_12_1__supported_append_r (j :: js1) js2 live t prf with ((target j == t) && iret_12__all_in (ante j) live)
  iret_12_1__supported_append_r (j :: js1) js2 live t prf | True = Refl
  iret_12_1__supported_append_r (j :: js1) js2 live t prf | False = iret_12_1__supported_append_r js1 js2 live t prf

--@derives [IRET.12.1]
export
iret_12_1__supported_append_inv : (js1, js2 : List Iret_12_1__justif) -> (live : List Iret_12__fact) -> (t : Iret_12__fact) ->
                                  iret_12__supported (js1 ++ js2) live t = True ->
                                  Either (iret_12__supported js1 live t = True) (iret_12__supported js2 live t = True)
iret_12_1__supported_append_inv [] js2 live t prf = Right prf
iret_12_1__supported_append_inv (j :: js1) js2 live t prf with ((target j == t) && iret_12__all_in (ante j) live)
  iret_12_1__supported_append_inv (j :: js1) js2 live t prf | True = Left Refl
  iret_12_1__supported_append_inv (j :: js1) js2 live t prf | False = iret_12_1__supported_append_inv js1 js2 live t prf

-- ---------------------------------------------------------------------
-- The cascade is a fixpoint within its fuel, and the GREATEST
-- self-supported subset of the live set
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
export
iret_12_2__cascade_step_sub : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (live : List Iret_12__fact) ->
                              Iret_12__sub (iret_12_2__cascade_step base js live) live
iret_12_2__cascade_step_sub base js live = iret_12__filter_sub (\t => iret_12__elem t base || iret_12__supported js live t) live

--@derives [IRET.12.2]
||| Once a step retracts nothing, no later step does.
export
iret_12_2__cascade_n_stable : (n : Nat) -> (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (live : List Iret_12__fact) ->
                              iret_12_2__cascade_step base js live = live -> iret_12_2__cascade_n n base js live = live
iret_12_2__cascade_n_stable Z base js live fix = Refl
iret_12_2__cascade_n_stable (S n) base js live fix =
  replace {p = \l => iret_12_2__cascade_n n base js l = live} (sym fix) (iret_12_2__cascade_n_stable n base js live fix)

--@derives [IRET.12.2]
||| The cascade stabilises within as many steps as there are live facts:
||| a step that retracts nothing is the fixpoint, and one that retracts
||| something shortens the live list.
export
iret_12_2__cascade_n_fixed : (n : Nat) -> (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (live : List Iret_12__fact) ->
                             LTE (length live) n ->
                             iret_12_2__cascade_step base js (iret_12_2__cascade_n n base js live) = iret_12_2__cascade_n n base js live
iret_12_2__cascade_n_fixed Z base js live bound =
  replace {p = \l => iret_12_2__cascade_step base js l = l} (sym (iret_12__len_zero live bound)) Refl
iret_12_2__cascade_n_fixed (S m) base js live bound with (decEq (iret_12_2__cascade_step base js live) live)
  iret_12_2__cascade_n_fixed (S m) base js live bound | Yes fix =
    replace {p = \l => iret_12_2__cascade_step base js l = l}
            (sym (replace {p = \l => iret_12_2__cascade_n m base js l = live} (sym fix) (iret_12_2__cascade_n_stable m base js live fix)))
            fix
  iret_12_2__cascade_n_fixed (S m) base js live bound | No neq =
    iret_12_2__cascade_n_fixed m base js (iret_12_2__cascade_step base js live)
      (fromLteSucc (transitive (iret_12__filter_neq_lt (\t => iret_12__elem t base || iret_12__supported js live t) live neq) bound))

--@derives [IRET.12.2]
||| The cascade's result is a fixpoint of the cascade step.
export
iret_12_2__cascade_fixed : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (live : List Iret_12__fact) ->
                           iret_12_2__cascade_step base js (iret_12_2__cascade base js live) = iret_12_2__cascade base js live
iret_12_2__cascade_fixed base js live = iret_12_2__cascade_n_fixed (length live) base js live reflexive

--@derives [IRET.12.2]
||| The cascade only ever retracts.
export
iret_12_2__cascade_sub : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (live : List Iret_12__fact) ->
                         Iret_12__sub (iret_12_2__cascade base js live) live
iret_12_2__cascade_sub base js live = go (length live) live
  where
    go : (n : Nat) -> (l : List Iret_12__fact) -> Iret_12__sub (iret_12_2__cascade_n n base js l) l
    go Z l t et = et
    go (S n) l t et = iret_12_2__cascade_step_sub base js l t (go n (iret_12_2__cascade_step base js l) t et)

--@derives [IRET.12.2]
||| A survivor is a base fact or is supported by the survivors.
export
iret_12_2__cascade_closed : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (live : List Iret_12__fact) -> (t : Iret_12__fact) ->
                            iret_12__elem t (iret_12_2__cascade base js live) = True ->
                            Either (iret_12__elem t base = True) (iret_12__supported js (iret_12_2__cascade base js live) t = True)
iret_12_2__cascade_closed base js live t et =
  iret_12__or_inv _ _ (snd (iret_12__elem_filter_inv (\u => iret_12__elem u base || iret_12__supported js (iret_12_2__cascade base js live) u)
                                                     (iret_12_2__cascade base js live) t
                                                     (replace {p = \l => iret_12__elem t l = True} (sym (iret_12_2__cascade_fixed base js live)) et)))

--@derives [IRET.12.2]
||| The cascade keeps every self-supported subset of the live set: a set
||| whose members are each base or supported within the set survives
||| every step. So the cascade is the GREATEST such set — which is why
||| an unfounded cycle survives it.
export
iret_12_2__cascade_greatest : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (live, l : List Iret_12__fact) ->
                              Iret_12__sub l live -> Iret_12__sub l (iret_12_2__cascade_step base js l) ->
                              Iret_12__sub l (iret_12_2__cascade base js live)
iret_12_2__cascade_greatest base js live l sub post = go (length live) live sub
  where
    keep : (v : List Iret_12__fact) -> Iret_12__sub l v -> Iret_12__sub l (iret_12_2__cascade_step base js v)
    keep v subV t et =
      let (inL, pt) = iret_12__elem_filter_inv (\u => iret_12__elem u base || iret_12__supported js l u) l t (post t et)
      in iret_12__elem_filter (\u => iret_12__elem u base || iret_12__supported js v u) v t (subV t inL) (lift t pt)
      where
        lift : (u : Iret_12__fact) -> (iret_12__elem u base || iret_12__supported js l u) = True -> (iret_12__elem u base || iret_12__supported js v u) = True
        lift u prf with (iret_12__elem u base)
          lift u prf | True = Refl
          lift u prf | False = iret_12__supported_mono js l v subV u prf
    go : (n : Nat) -> (v : List Iret_12__fact) -> Iret_12__sub l v -> Iret_12__sub l (iret_12_2__cascade_n n base js v)
    go Z v subV = subV
    go (S n) v subV = go n (iret_12_2__cascade_step base js v) (keep v subV)

-- ---------------------------------------------------------------------
-- The derivation is a fixpoint within its fuel, and the LEAST closed
-- superset of the base facts
-- ---------------------------------------------------------------------

--@derives [LLOG.2.5]
||| One derivation round is monotone in what is known.
export
llog_2_5__derive_step_mono : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, xs, ys : List Iret_12__fact) ->
                             Iret_12__sub xs ys -> Iret_12__sub (llog_2_5__derive_step base js univ xs) (llog_2_5__derive_step base js univ ys)
llog_2_5__derive_step_mono base js univ xs ys sub t et =
  let (inAll, pt) = iret_12__elem_filter_inv (\u => iret_12__elem u base || iret_12__supported js xs u) univ t et
  in iret_12__elem_filter (\u => iret_12__elem u base || iret_12__supported js ys u) univ t inAll (lift t pt)
  where
    lift : (u : Iret_12__fact) -> (iret_12__elem u base || iret_12__supported js xs u) = True -> (iret_12__elem u base || iret_12__supported js ys u) = True
    lift u prf with (iret_12__elem u base)
      lift u prf | True = Refl
      lift u prf | False = iret_12__supported_mono js xs ys sub u prf

--@derives [LLOG.2.5]
||| Once a round adds nothing, no later round does.
export
llog_2_5__derive_n_stable : (n : Nat) -> (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, known : List Iret_12__fact) ->
                            llog_2_5__derive_step base js univ known = known -> llog_2_5__derive_n n base js univ known = known
llog_2_5__derive_n_stable Z base js univ known fix = Refl
llog_2_5__derive_n_stable (S n) base js univ known fix =
  replace {p = \k => llog_2_5__derive_n n base js univ k = known} (sym fix) (llog_2_5__derive_n_stable n base js univ known fix)

--@derives [LLOG.2.5]
||| From a known set that is a filter of the universe and that one round
||| keeps, the derivation stabilises within as many rounds as the
||| universe has facts beyond it: a round that adds nothing is the
||| fixpoint, and one that adds something lengthens the filter.
export
llog_2_5__derive_n_fixed : (n : Nat) -> (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ : List Iret_12__fact) ->
                           (q : Iret_12__fact -> Bool) -> (known : List Iret_12__fact) -> known = filter q univ ->
                           Iret_12__sub known (llog_2_5__derive_step base js univ known) ->
                           LTE (length univ) (n + length known) ->
                           llog_2_5__derive_step base js univ (llog_2_5__derive_n n base js univ known) = llog_2_5__derive_n n base js univ known
llog_2_5__derive_n_fixed Z base js univ q known kq sub bound =
  let full : (filter q univ = univ)
      full = iret_12__filter_full q univ (replace {p = \k => LTE (length univ) (length k)} kq bound)
      eqA : (known = univ)
      eqA = trans kq full
      every : (y : Iret_12__fact) -> iret_12__elem y univ = True -> (iret_12__elem y base || iret_12__supported js known y) = True
      every y ey = snd (iret_12__elem_filter_inv (\u => iret_12__elem u base || iret_12__supported js known u) univ y
                          (sub y (replace {p = \k => iret_12__elem y k = True} (sym eqA) ey)))
  in trans (iret_12__filter_all (\u => iret_12__elem u base || iret_12__supported js known u) univ every) (sym eqA)
llog_2_5__derive_n_fixed (S m) base js univ q known kq sub bound with (decEq (llog_2_5__derive_step base js univ known) known)
  llog_2_5__derive_n_fixed (S m) base js univ q known kq sub bound | Yes fix =
    replace {p = \k => llog_2_5__derive_step base js univ k = k}
            (sym (replace {p = \k => llog_2_5__derive_n m base js univ k = known} (sym fix) (llog_2_5__derive_n_stable m base js univ known fix)))
            fix
  llog_2_5__derive_n_fixed (S m) base js univ q known kq sub bound | No neq =
    let himp : (y : Iret_12__fact) -> iret_12__elem y univ = True -> q y = True -> (iret_12__elem y base || iret_12__supported js known y) = True
        himp y ey qy = snd (iret_12__elem_filter_inv (\u => iret_12__elem u base || iret_12__supported js known u) univ y
                              (sub y (replace {p = \k => iret_12__elem y k = True} (sym kq) (iret_12__elem_filter q univ y ey qy))))
        neq' : Not (filter q univ = filter (\u => iret_12__elem u base || iret_12__supported js known u) univ)
        neq' e = neq (trans (sym e) (sym kq))
        lt : LT (length known) (length (llog_2_5__derive_step base js univ known))
        lt = replace {p = \k => LT (length k) (length (llog_2_5__derive_step base js univ known))} (sym kq)
               (iret_12__filter_imp_lt q (\u => iret_12__elem u base || iret_12__supported js known u) univ himp neq')
        bound' : LTE (length univ) (m + length (llog_2_5__derive_step base js univ known))
        bound' = transitive bound
                   (replace {p = \z => LTE z (m + length (llog_2_5__derive_step base js univ known))}
                            (sym (plusSuccRightSucc m (length known)))
                            (plusLteMonotoneLeft m _ _ lt))
    in llog_2_5__derive_n_fixed m base js univ (\u => iret_12__elem u base || iret_12__supported js known u)
         (llog_2_5__derive_step base js univ known) Refl
         (llog_2_5__derive_step_mono base js univ known (llog_2_5__derive_step base js univ known) sub)
         bound'

--@derives [LLOG.2.5]
||| The well-founded set is a fixpoint of derivation.
export
llog_2_5__wf_fixed : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ : List Iret_12__fact) ->
                     llog_2_5__derive_step base js univ (llog_2_5__well_founded base js univ) = llog_2_5__well_founded base js univ
llog_2_5__wf_fixed base js univ =
  llog_2_5__derive_n_fixed (length univ) base js univ (\t => iret_12__elem t base) (filter (\t => iret_12__elem t base) univ) Refl sub0
    (lteAddRight (length univ))
  where
    sub0 : Iret_12__sub (filter (\t => iret_12__elem t base) univ)
                        (llog_2_5__derive_step base js univ (filter (\t => iret_12__elem t base) univ))
    sub0 t et =
      let (inAll, bt) = iret_12__elem_filter_inv (\u => iret_12__elem u base) univ t et
      in iret_12__elem_filter (\u => iret_12__elem u base || iret_12__supported js (filter (\v => iret_12__elem v base) univ) u) univ t inAll
           (iret_12__or_true_l _ _ bt)

--@derives [LLOG.2.5]
||| The well-founded set lies in the universe.
export
llog_2_5__wf_sub_all : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ : List Iret_12__fact) ->
                       Iret_12__sub (llog_2_5__well_founded base js univ) univ
llog_2_5__wf_sub_all base js univ = go (length univ) (filter (\t => iret_12__elem t base) univ) (iret_12__filter_sub (\t => iret_12__elem t base) univ)
  where
    go : (n : Nat) -> (known : List Iret_12__fact) -> Iret_12__sub known univ -> Iret_12__sub (llog_2_5__derive_n n base js univ known) univ
    go Z known sub = sub
    go (S n) known sub = go n (llog_2_5__derive_step base js univ known)
                           (iret_12__filter_sub (\u => iret_12__elem u base || iret_12__supported js known u) univ)

--@derives [LLOG.2.5]
||| A base fact of the universe is well-founded.
export
llog_2_5__base_in_wf : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ : List Iret_12__fact) -> (t : Iret_12__fact) ->
                       iret_12__elem t univ = True -> iret_12__elem t base = True -> iret_12__elem t (llog_2_5__well_founded base js univ) = True
llog_2_5__base_in_wf base js univ t ta tb =
  replace {p = \k => iret_12__elem t k = True} (llog_2_5__wf_fixed base js univ)
    (iret_12__elem_filter (\u => iret_12__elem u base || iret_12__supported js (llog_2_5__well_founded base js univ) u) univ t ta
       (iret_12__or_true_l _ _ tb))

--@derives [LLOG.2.5]
||| A fact of the universe supported by well-founded facts is well-founded.
export
llog_2_5__wf_closed : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ : List Iret_12__fact) -> (t : Iret_12__fact) ->
                      iret_12__elem t univ = True -> iret_12__supported js (llog_2_5__well_founded base js univ) t = True ->
                      iret_12__elem t (llog_2_5__well_founded base js univ) = True
llog_2_5__wf_closed base js univ t ta ts =
  replace {p = \k => iret_12__elem t k = True} (llog_2_5__wf_fixed base js univ)
    (iret_12__elem_filter (\u => iret_12__elem u base || iret_12__supported js (llog_2_5__well_founded base js univ) u) univ t ta
       (iret_12__or_true_r _ _ ts))

--@derives [LLOG.2.5]
||| The well-founded set is below every closed set: one that holds the
||| base facts of the universe and is closed under support. So it is the
||| LEAST fixpoint — the [LLOG.2.5] reading in which a justification
||| counts only when grounded.
export
llog_2_5__wf_least : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, l : List Iret_12__fact) ->
                     ((t : Iret_12__fact) -> iret_12__elem t univ = True -> iret_12__elem t base = True -> iret_12__elem t l = True) ->
                     ((t : Iret_12__fact) -> iret_12__elem t univ = True -> iret_12__supported js l t = True -> iret_12__elem t l = True) ->
                     Iret_12__sub (llog_2_5__well_founded base js univ) l
llog_2_5__wf_least base js univ l hb hs = go (length univ) (filter (\t => iret_12__elem t base) univ) k0
  where
    k0 : Iret_12__sub (filter (\t => iret_12__elem t base) univ) l
    k0 t et = let (inAll, bt) = iret_12__elem_filter_inv (\u => iret_12__elem u base) univ t et in hb t inAll bt
    step : (known : List Iret_12__fact) -> Iret_12__sub known l -> Iret_12__sub (llog_2_5__derive_step base js univ known) l
    step known sub t et =
      let (inAll, pt) = iret_12__elem_filter_inv (\u => iret_12__elem u base || iret_12__supported js known u) univ t et
      in case iret_12__or_inv _ _ pt of
           Left bt => hb t inAll bt
           Right st => hs t inAll (iret_12__supported_mono js known l sub t st)
    go : (n : Nat) -> (known : List Iret_12__fact) -> Iret_12__sub known l -> Iret_12__sub (llog_2_5__derive_n n base js univ known) l
    go Z known sub = sub
    go (S n) known sub = go n (llog_2_5__derive_step base js univ known) (step known sub)

--@derives [LLOG.2.5]
||| Fewer base facts, no more well-founded facts: a retraction of inputs
||| only ever retracts derived facts, never adds one. The net difference
||| recompute-and-diff commits after a withdrawal is retractions only.
export
llog_2_5__wf_mono_base : (base', base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ : List Iret_12__fact) ->
                         Iret_12__sub base' base -> Iret_12__sub (llog_2_5__well_founded base' js univ) (llog_2_5__well_founded base js univ)
llog_2_5__wf_mono_base base' base js univ sub =
  llog_2_5__wf_least base' js univ (llog_2_5__well_founded base js univ)
    (\t, ta, tb => llog_2_5__base_in_wf base js univ t ta (sub t tb))
    (\t, ta, ts => llog_2_5__wf_closed base js univ t ta ts)

--@derives [LLOG.2.5]
--@derives [IRET.12.2]
||| The cascade never retracts a well-founded fact: the well-founded set
||| is self-supported, so the greatest self-supported set contains it.
export
llog_2_5__wf_in_cascade : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, live : List Iret_12__fact) ->
                          Iret_12__sub (llog_2_5__well_founded base js univ) live ->
                          Iret_12__sub (llog_2_5__well_founded base js univ) (iret_12_2__cascade base js live)
llog_2_5__wf_in_cascade base js univ live sub = iret_12_2__cascade_greatest base js live (llog_2_5__well_founded base js univ) sub post
  where
    post : Iret_12__sub (llog_2_5__well_founded base js univ) (iret_12_2__cascade_step base js (llog_2_5__well_founded base js univ))
    post t et =
      let (inAll, pt) = iret_12__elem_filter_inv (\u => iret_12__elem u base || iret_12__supported js (llog_2_5__well_founded base js univ) u) univ t
                          (replace {p = \k => iret_12__elem t k = True} (sym (llog_2_5__wf_fixed base js univ)) et)
      in iret_12__elem_filter (\u => iret_12__elem u base || iret_12__supported js (llog_2_5__well_founded base js univ) u)
                              (llog_2_5__well_founded base js univ) t et pt

-- ---------------------------------------------------------------------
-- The unfounded set: exactly what separates the two fixpoints
-- ---------------------------------------------------------------------

--@spec [LLOG.2.5]
||| An unfounded set among a live set: nonempty, free of base facts, and
||| every justification that keeps one of its members alive uses another
||| of its members. Mutual support with nothing under it.
public export
Llog_2_5__unfounded : List Iret_12__fact -> List Iret_12_1__justif -> List Iret_12__fact -> List Iret_12__fact -> Type
Llog_2_5__unfounded base js live u =
  ( NonEmpty u
  , (t : Iret_12__fact) -> iret_12__elem t u = True -> iret_12__elem t base = False
  , (t : Iret_12__fact) -> iret_12__elem t u = True -> (j : Iret_12_1__justif) -> Elem j js -> target j = t ->
      iret_12__all_in (ante j) live = True -> (a ** (Elem a (ante j), iret_12__elem a u = True)) )

--@spec [LLOG.2.5]
||| The facts outside a set — applied to the well-founded set, the
||| candidate unfounded set among the survivors.
public export
llog_2_5__outside : List Iret_12__fact -> Iret_12__fact -> Bool
llog_2_5__outside w x = not (iret_12__elem x w)

--@derives [IRET.12]
export
iret_12__bool_false_of : (b : Bool) -> (b = True -> Void) -> b = False
iret_12__bool_false_of True h = void (h Refl)
iret_12__bool_false_of False h = Refl

--@derives [IRET.12]
export
iret_12__bool_split : (b : Bool) -> Either (b = True) (b = False)
iret_12__bool_split True = Left Refl
iret_12__bool_split False = Right Refl

--@derives [IRET.12.2]
||| A survivor outside the well-founded set is not a base fact.
export
iret_12_2__unfounded_base_free : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, live : List Iret_12__fact) ->
                                 Iret_12__sub live univ -> (x : Iret_12__fact) ->
                                 iret_12__elem x (filter (llog_2_5__outside (llog_2_5__well_founded base js univ)) (iret_12_2__cascade base js live)) = True ->
                                 iret_12__elem x base = False
iret_12_2__unfounded_base_free base js univ live sub x xU =
  let (xG, ox) = iret_12__elem_filter_inv (llog_2_5__outside (llog_2_5__well_founded base js univ)) (iret_12_2__cascade base js live) x xU
  in iret_12__bool_false_of (iret_12__elem x base)
       (\xb => absurd (trans (sym (iret_12__not_true _ ox))
                             (llog_2_5__base_in_wf base js univ x (sub x (iret_12_2__cascade_sub base js live x xG)) xb)))

--@derives [IRET.12.2]
||| A justification that keeps a survivor outside the well-founded set
||| alive has an antecedent outside it too: were every antecedent
||| well-founded, so would the survivor be.
export
iret_12_2__unfounded_held : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, live : List Iret_12__fact) ->
                            Iret_12__sub live univ -> (x : Iret_12__fact) ->
                            iret_12__elem x (filter (llog_2_5__outside (llog_2_5__well_founded base js univ)) (iret_12_2__cascade base js live)) = True ->
                            (j : Iret_12_1__justif) -> Elem j js -> target j = x ->
                            iret_12__all_in (ante j) (iret_12_2__cascade base js live) = True ->
                            (a ** (Elem a (ante j), iret_12__elem a (filter (llog_2_5__outside (llog_2_5__well_founded base js univ)) (iret_12_2__cascade base js live)) = True))
iret_12_2__unfounded_held base js univ live sub x xU j ej tj aj =
  case iret_12__bool_split (iret_12__all_in (ante j) (llog_2_5__well_founded base js univ)) of
    Left ajW =>
      let (xG, ox) = iret_12__elem_filter_inv (llog_2_5__outside (llog_2_5__well_founded base js univ)) (iret_12_2__cascade base js live) x xU
          xW : (iret_12__elem x (llog_2_5__well_founded base js univ) = True)
          xW = llog_2_5__wf_closed base js univ x (sub x (iret_12_2__cascade_sub base js live x xG))
                 (replace {p = \v => iret_12__supported js (llog_2_5__well_founded base js univ) v = True} tj
                    (iret_12_1__supported_of js (llog_2_5__well_founded base js univ) j ej ajW))
      in absurd (trans (sym (iret_12__not_true _ ox)) xW)
    Right ajF => case iret_12__all_in_false (ante j) (llog_2_5__well_founded base js univ) ajF of
      (a ** (ea, aW)) => (a ** (ea, iret_12__elem_filter (llog_2_5__outside (llog_2_5__well_founded base js univ)) (iret_12_2__cascade base js live) a
                                      (iret_12__all_in_elem (ante j) (iret_12_2__cascade base js live) aj a ea)
                                      (iret_12__not_false _ aW)))

--@derives [IRET.12.2]
--@derives [LLOG.2.5]
||| What the refcount keeps beyond the well-founded answer is an
||| unfounded set: if any survivor of the cascade is not well-founded,
||| the survivors outside the well-founded set hold each other up.
export
iret_12_2__cascade_unfounded : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, live : List Iret_12__fact) ->
                               Iret_12__sub live univ ->
                               (t : Iret_12__fact) -> iret_12__elem t (iret_12_2__cascade base js live) = True ->
                               iret_12__elem t (llog_2_5__well_founded base js univ) = False ->
                               Llog_2_5__unfounded base js (iret_12_2__cascade base js live)
                                 (filter (llog_2_5__outside (llog_2_5__well_founded base js univ)) (iret_12_2__cascade base js live))
iret_12_2__cascade_unfounded base js univ live sub t tG tW =
  ( iret_12__nonempty t (filter (llog_2_5__outside (llog_2_5__well_founded base js univ)) (iret_12_2__cascade base js live))
      (iret_12__elem_filter (llog_2_5__outside (llog_2_5__well_founded base js univ)) (iret_12_2__cascade base js live) t tG (iret_12__not_false _ tW))
  , iret_12_2__unfounded_base_free base js univ live sub
  , iret_12_2__unfounded_held base js univ live sub )

--@derives [LLOG.2.5]
||| The well-founded facts outside an unfounded set hold the base facts
||| of the universe (an unfounded set has none)...
export
llog_2_5__unfounded_hb : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, u : List Iret_12__fact) ->
                         ((t : Iret_12__fact) -> iret_12__elem t u = True -> iret_12__elem t base = False) ->
                         (x : Iret_12__fact) -> iret_12__elem x univ = True -> iret_12__elem x base = True ->
                         iret_12__elem x (filter (llog_2_5__outside u) (llog_2_5__well_founded base js univ)) = True
llog_2_5__unfounded_hb base js univ u ufree x xa xb =
  case iret_12__bool_split (iret_12__elem x u) of
    Left xu => absurd (trans (sym (ufree x xu)) xb)
    Right xu => iret_12__elem_filter (llog_2_5__outside u) (llog_2_5__well_founded base js univ) x (llog_2_5__base_in_wf base js univ x xa xb) (iret_12__not_false _ xu)

--@derives [LLOG.2.5]
||| ...and are closed under support: a fact they support is well-founded
||| and cannot be in the unfounded set, since the justification's
||| antecedents all lie outside it.
export
llog_2_5__unfounded_hs : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, live, u : List Iret_12__fact) ->
                         Iret_12__sub (llog_2_5__well_founded base js univ) live ->
                         ((t : Iret_12__fact) -> iret_12__elem t u = True -> (j : Iret_12_1__justif) -> Elem j js -> target j = t ->
                            iret_12__all_in (ante j) (iret_12_2__cascade base js live) = True -> (a ** (Elem a (ante j), iret_12__elem a u = True))) ->
                         (x : Iret_12__fact) -> iret_12__elem x univ = True ->
                         iret_12__supported js (filter (llog_2_5__outside u) (llog_2_5__well_founded base js univ)) x = True ->
                         iret_12__elem x (filter (llog_2_5__outside u) (llog_2_5__well_founded base js univ)) = True
llog_2_5__unfounded_hs base js univ live u wfLive uheld x xa xs =
  case iret_12_1__supported_inv js (filter (llog_2_5__outside u) (llog_2_5__well_founded base js univ)) x xs of
    (j ** (ej, tj, aj)) =>
      let xW : (iret_12__elem x (llog_2_5__well_founded base js univ) = True)
          xW = llog_2_5__wf_closed base js univ x xa
                 (replace {p = \v => iret_12__supported js (llog_2_5__well_founded base js univ) v = True} tj
                    (iret_12_1__supported_of js (llog_2_5__well_founded base js univ) j ej
                       (iret_12__all_in_sub (ante j) (filter (llog_2_5__outside u) (llog_2_5__well_founded base js univ)) (llog_2_5__well_founded base js univ)
                          (iret_12__filter_sub (llog_2_5__outside u) (llog_2_5__well_founded base js univ)) aj)))
      in case iret_12__bool_split (iret_12__elem x u) of
           Right xu => iret_12__elem_filter (llog_2_5__outside u) (llog_2_5__well_founded base js univ) x xW (iret_12__not_false _ xu)
           Left xu => case uheld x xu j ej tj
                             (iret_12__all_in_sub (ante j) (filter (llog_2_5__outside u) (llog_2_5__well_founded base js univ)) (iret_12_2__cascade base js live)
                                (\y, yl => llog_2_5__wf_in_cascade base js univ live wfLive y
                                             (iret_12__filter_sub (llog_2_5__outside u) (llog_2_5__well_founded base js univ) y yl)) aj) of
             (a ** (ea, au)) =>
               absurd (trans (sym (iret_12__not_true _ (snd (iret_12__elem_filter_inv (llog_2_5__outside u) (llog_2_5__well_founded base js univ) a
                                                                (iret_12__all_in_elem (ante j) (filter (llog_2_5__outside u) (llog_2_5__well_founded base js univ)) aj a ea)))))
                             au)

--@derives [LLOG.2.5]
||| And conversely: an unfounded set among the survivors is disjoint
||| from the well-founded answer, so the two fixpoints differ on it. With
||| `iret_12_2__cascade_unfounded`: the cascade and the well-founded set
||| agree exactly when the survivors hold no unfounded set.
export
llog_2_5__unfounded_disagrees : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, live, u : List Iret_12__fact) ->
                                Iret_12__sub (llog_2_5__well_founded base js univ) live ->
                                Llog_2_5__unfounded base js (iret_12_2__cascade base js live) u ->
                                (t : Iret_12__fact) -> iret_12__elem t u = True -> iret_12__elem t (llog_2_5__well_founded base js univ) = False
llog_2_5__unfounded_disagrees base js univ live u wfLive (_, ufree, uheld) t tu =
  iret_12__bool_false_of (iret_12__elem t (llog_2_5__well_founded base js univ))
    (\tW => absurd (trans (sym (iret_12__not_true _ (snd (iret_12__elem_filter_inv (llog_2_5__outside u) (llog_2_5__well_founded base js univ) t
                                                          (llog_2_5__wf_least base js univ (filter (llog_2_5__outside u) (llog_2_5__well_founded base js univ))
                                                             (llog_2_5__unfounded_hb base js univ u ufree)
                                                             (llog_2_5__unfounded_hs base js univ live u wfLive uheld) t tW)))))
                          tu))

-- ---------------------------------------------------------------------
-- Exactness on ranked (acyclic) support: the TLA+ scope
-- ---------------------------------------------------------------------

--@spec [IRET.12.3]
||| A ranking: every antecedent of a justification ranks strictly below
||| its target. A support graph admits one iff it is acyclic.
public export
Iret_12_3__ranked : (Iret_12__fact -> Nat) -> List Iret_12_1__justif -> Type
Iret_12_3__ranked rank js = (j : Iret_12_1__justif) -> Elem j js -> (a : Iret_12__fact) -> Elem a (ante j) -> LT (rank a) (rank (target j))

--@derives [IRET.12.3]
--@derives [IRET.12.2]
||| Under a ranking every survivor of the cascade is well-founded, by
||| strong induction on rank: a survivor is a base fact, or is kept alive
||| by a justification whose antecedents survive and rank lower, hence
||| are well-founded, so the same justification derives it.
export
iret_12_3__ranked_exact : (rank : Iret_12__fact -> Nat) -> (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) ->
                          (univ, live : List Iret_12__fact) -> Iret_12_3__ranked rank js -> Iret_12__sub live univ ->
                          Iret_12__sub (iret_12_2__cascade base js live) (llog_2_5__well_founded base js univ)
iret_12_3__ranked_exact rank base js univ live ranked sub t tG = go (S (rank t)) t reflexive tG
  where
    go : (n : Nat) -> (u : Iret_12__fact) -> LT (rank u) n ->
         iret_12__elem u (iret_12_2__cascade base js live) = True -> iret_12__elem u (llog_2_5__well_founded base js univ) = True
    go Z u lt _ = absurd lt
    go (S m) u lt uG = case iret_12_2__cascade_closed base js live u uG of
      Left ub => llog_2_5__base_in_wf base js univ u (sub u (iret_12_2__cascade_sub base js live u uG)) ub
      Right us => case iret_12_1__supported_inv js (iret_12_2__cascade base js live) u us of
        (j ** (ej, tj, aj)) =>
          let lower : (a : Iret_12__fact) -> Elem a (ante j) -> LT (rank a) m
              lower a ea = transitive (ranked j ej a ea)
                             (replace {p = \v => LTE (rank v) m} (sym tj) (fromLteSucc lt))
          in llog_2_5__wf_closed base js univ u (sub u (iret_12_2__cascade_sub base js live u uG))
               (replace {p = \v => iret_12__supported js (llog_2_5__well_founded base js univ) v = True} tj
                  (iret_12_1__supported_of js (llog_2_5__well_founded base js univ) j ej
                     (iret_12__all_in_from (ante j) (llog_2_5__well_founded base js univ)
                        (\a, ea => go m a (lower a ea) (iret_12__all_in_elem (ante j) (iret_12_2__cascade base js live) aj a ea)))))

--@derives [IRET.12.3]
--@derives [IRET.12.2]
--@derives [LLOG.2.5]
||| On a ranked (acyclic) support graph the refcount is exact: the
||| cascade and the well-founded set contain each other. This is the
||| scope on which [IRET.12.2]'s mechanism and [LLOG.2.5]'s intent
||| coincide. tms_cascade.tla's `no_unsupported_forever` is an instance
||| of `iret_12_2__cascade_fixed` (the cascade reaches its fixpoint); that
||| the fixpoint is the well-founded set on that model's ranked instance
||| is this theorem there, executed as `iret_12_2__tla_retract_f1` and
||| `iret_12_2__tla_retract_both`.
export
iret_12_3__ranked_agree : (rank : Iret_12__fact -> Nat) -> (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) ->
                          (univ, live : List Iret_12__fact) -> Iret_12_3__ranked rank js -> Iret_12__sub live univ ->
                          Iret_12__sub (llog_2_5__well_founded base js univ) live ->
                          ( Iret_12__sub (iret_12_2__cascade base js live) (llog_2_5__well_founded base js univ)
                          , Iret_12__sub (llog_2_5__well_founded base js univ) (iret_12_2__cascade base js live) )
iret_12_3__ranked_agree rank base js univ live ranked sub wfLive =
  (iret_12_3__ranked_exact rank base js univ live ranked sub, llog_2_5__wf_in_cascade base js univ live wfLive)

--@spec [IRET.12.3]
||| The ranked instance tms_cascade.tla draws: f2 <- {f1}, f2 <- {f4},
||| f3 <- {f2}. The executable checks below are `iret_12_3__ranked_agree`
||| on it. That it IS the module's instance under f1..f4 -> 1..4, and that
||| the two witnesses below are RetractBase histories of it, is held by
||| scripts/formal/check_instances.py on every run of the lane;
||| `llog_2_5__witness_js` is held to the module's cycle
||| the same way, under P, Q, R -> 0, 1, 2.
export
iret_12_3__tla_js : List Iret_12_1__justif
iret_12_3__tla_js = [MkJustif [1] 2, MkJustif [4] 2, MkJustif [2] 3]

--@derives [IRET.12.2]
--@derives [IRET.12.3]
export
iret_12_2__tla_retract_f1 : iret_12_2__cascade [4] Rete.Refcount.iret_12_3__tla_js [2, 3, 4] = llog_2_5__well_founded [4] Rete.Refcount.iret_12_3__tla_js [2, 3, 4]
iret_12_2__tla_retract_f1 = Refl

--@derives [IRET.12.2]
export
iret_12_2__tla_retract_both : iret_12_2__cascade [] Rete.Refcount.iret_12_3__tla_js [2, 3] = llog_2_5__well_founded [] Rete.Refcount.iret_12_3__tla_js [2, 3]
iret_12_2__tla_retract_both = Refl

-- ---------------------------------------------------------------------
-- Strata compose: recomputing a stratum over another's recomputed
-- output is the global recompute
-- ---------------------------------------------------------------------

--@spec [LLOG.2.5]
||| Two strata of justifications in the SCC-DAG's order: the lower one
||| never reads what the upper one derives.
public export
Llog_2_5__stratified : List Iret_12_1__justif -> List Iret_12_1__justif -> Type
Llog_2_5__stratified js1 js2 =
  (j1 : Iret_12_1__justif) -> Elem j1 js1 -> (a : Iret_12__fact) -> Elem a (ante j1) ->
  (j2 : Iret_12_1__justif) -> Elem j2 js2 -> Not (target j2 = a)

--@derives [LLOG.2.5]
||| An antecedent of a lower-stratum justification that the composed
||| recompute derives is derived by the lower stratum alone: it is the
||| upper recompute's base, or an upper-stratum target, which the
||| stratification forbids.
export
llog_2_5__stratified_ante : (base : List Iret_12__fact) -> (js1, js2 : List Iret_12_1__justif) -> (univ : List Iret_12__fact) ->
                            Llog_2_5__stratified js1 js2 -> (j : Iret_12_1__justif) -> Elem j js1 -> (a : Iret_12__fact) -> Elem a (ante j) ->
                            iret_12__elem a (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ) = True ->
                            iret_12__elem a (llog_2_5__well_founded base js1 univ) = True
llog_2_5__stratified_ante base js1 js2 univ strat j ej a ea aW2 =
  let (aU, pa) = iret_12__elem_filter_inv
                   (\u => iret_12__elem u (llog_2_5__well_founded base js1 univ) || iret_12__supported js2 (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ) u)
                   univ a
                   (replace {p = \k => iret_12__elem a k = True} (sym (llog_2_5__wf_fixed (llog_2_5__well_founded base js1 univ) js2 univ)) aW2)
  in case iret_12__or_inv _ _ pa of
       Left a1 => a1
       Right s2 => case iret_12_1__supported_inv js2 (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ) a s2 of
         (j2 ** (ej2, tj2, _)) => void (strat j ej a ea j2 ej2 tj2)

--@derives [LLOG.2.5]
||| The composed recompute holds the base facts of the universe.
export
llog_2_5__compose_hb : (base : List Iret_12__fact) -> (js1, js2 : List Iret_12_1__justif) -> (univ : List Iret_12__fact) ->
                       (t : Iret_12__fact) -> iret_12__elem t univ = True -> iret_12__elem t base = True ->
                       iret_12__elem t (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ) = True
llog_2_5__compose_hb base js1 js2 univ t ta tb =
  llog_2_5__base_in_wf (llog_2_5__well_founded base js1 univ) js2 univ t ta (llog_2_5__base_in_wf base js1 univ t ta tb)

--@derives [LLOG.2.5]
||| And is closed under both strata's support: under the upper stratum
||| by its own fixpoint, under the lower stratum because the antecedents
||| lie in the lower recompute, which is closed and is the upper
||| recompute's base.
export
llog_2_5__compose_hs : (base : List Iret_12__fact) -> (js1, js2 : List Iret_12_1__justif) -> (univ : List Iret_12__fact) ->
                       Llog_2_5__stratified js1 js2 ->
                       (t : Iret_12__fact) -> iret_12__elem t univ = True ->
                       iret_12__supported (js1 ++ js2) (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ) t = True ->
                       iret_12__elem t (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ) = True
llog_2_5__compose_hs base js1 js2 univ strat t ta st =
  case iret_12_1__supported_append_inv js1 js2 (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ) t st of
    Right s2 => llog_2_5__wf_closed (llog_2_5__well_founded base js1 univ) js2 univ t ta s2
    Left s1 => case iret_12_1__supported_inv js1 (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ) t s1 of
      (j ** (ej, tj, aj)) =>
        llog_2_5__base_in_wf (llog_2_5__well_founded base js1 univ) js2 univ t ta
          (llog_2_5__wf_closed base js1 univ t ta
             (replace {p = \v => iret_12__supported js1 (llog_2_5__well_founded base js1 univ) v = True} tj
                (iret_12_1__supported_of js1 (llog_2_5__well_founded base js1 univ) j ej
                   (iret_12__all_in_from (ante j) (llog_2_5__well_founded base js1 univ)
                      (\a, ea => llog_2_5__stratified_ante base js1 js2 univ strat j ej a ea
                                   (iret_12__all_in_elem (ante j) (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ) aj a ea))))))

--@derives [LLOG.2.5]
||| The lower stratum's recompute is within the global one.
export
llog_2_5__compose_lower_in : (base : List Iret_12__fact) -> (js1, js2 : List Iret_12_1__justif) -> (univ : List Iret_12__fact) ->
                             Iret_12__sub (llog_2_5__well_founded base js1 univ) (llog_2_5__well_founded base (js1 ++ js2) univ)
llog_2_5__compose_lower_in base js1 js2 univ =
  llog_2_5__wf_least base js1 univ (llog_2_5__well_founded base (js1 ++ js2) univ)
    (\t, ta, tb => llog_2_5__base_in_wf base (js1 ++ js2) univ t ta tb)
    (\t, ta, s1 => llog_2_5__wf_closed base (js1 ++ js2) univ t ta (iret_12_1__supported_append_l js1 js2 (llog_2_5__well_founded base (js1 ++ js2) univ) t s1))

--@derives [LLOG.2.5]
--@derives [LLOG.15.1]
||| Stratified recomputation composes: the least fixpoint of two strata
||| together is the least fixpoint of the upper stratum over the lower
||| stratum's least fixpoint. A recursive stratum that reads another's
||| net-diff output sees exactly what one global recompute would give
||| it, so recompute-and-diff can run stratum by stratum in the DAG's
||| order.
export
llog_2_5__stratified_compose : (base : List Iret_12__fact) -> (js1, js2 : List Iret_12_1__justif) -> (univ : List Iret_12__fact) ->
                               Llog_2_5__stratified js1 js2 ->
                               ( Iret_12__sub (llog_2_5__well_founded base (js1 ++ js2) univ)
                                              (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ)
                               , Iret_12__sub (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ)
                                              (llog_2_5__well_founded base (js1 ++ js2) univ) )
llog_2_5__stratified_compose base js1 js2 univ strat =
  ( llog_2_5__wf_least base (js1 ++ js2) univ (llog_2_5__well_founded (llog_2_5__well_founded base js1 univ) js2 univ)
      (llog_2_5__compose_hb base js1 js2 univ) (llog_2_5__compose_hs base js1 js2 univ strat)
  , llog_2_5__wf_least (llog_2_5__well_founded base js1 univ) js2 univ (llog_2_5__well_founded base (js1 ++ js2) univ)
      (\t, ta, t1 => llog_2_5__compose_lower_in base js1 js2 univ t t1)
      (\t, ta, s2 => llog_2_5__wf_closed base (js1 ++ js2) univ t ta
                       (iret_12_1__supported_append_r js1 js2 (llog_2_5__well_founded base (js1 ++ js2) univ) t s2)) )

-- ---------------------------------------------------------------------
-- The two-strata witness: a recursive stratum reading another's output
-- ---------------------------------------------------------------------

--@spec [LLOG.2.5]
||| Facts: 10 is the seed; 1 and 2 are the lower stratum's pair, 5 and 6
||| the upper stratum's. Lower stratum: 10 -> 1; 1 -> 2; 2 -> 1, a cycle
||| seeded from outside it. Small on purpose: the type-level evaluator
||| re-evaluates a derivation round once per membership test, so a
||| witness costs about (antecedents)^(rounds) round evaluations.
export
llog_2_5__strata_js1 : List Iret_12_1__justif
llog_2_5__strata_js1 = [MkJustif [10] 1, MkJustif [1] 2, MkJustif [2] 1]

--@spec [LLOG.2.5]
||| Upper stratum: 1 -> 5; 5 -> 6; 6 -> 5, a second cycle seeded by the
||| lower stratum's 1. It reads 1 and never the other way round.
export
llog_2_5__strata_js2 : List Iret_12_1__justif
llog_2_5__strata_js2 = [MkJustif [1] 5, MkJustif [5] 6, MkJustif [6] 5]

--@spec [LLOG.2.5]
export
llog_2_5__strata_all : List Iret_12__fact
llog_2_5__strata_all = [1, 2, 5, 6, 10]

--@derives [LLOG.2.5]
||| One more round at the front of a derivation, against literal states.
||| A witness over several rounds is a chain of single-round `Refl`s, as
||| in Lcyc/WitnessProofs.idr, each against a literal known set.
export
llog_2_5__derive_n_cons : (n : Nat) -> (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) -> (univ, known, k', r : List Iret_12__fact) ->
                          llog_2_5__derive_step base js univ known = k' -> llog_2_5__derive_n n base js univ k' = r ->
                          llog_2_5__derive_n (S n) base js univ known = r
llog_2_5__derive_n_cons n base js univ known k' r eq rest = replace {p = \k => llog_2_5__derive_n n base js univ k = r} (sym eq) rest

--@derives [LLOG.2.5]
||| With the seed everything is well-founded: three productive rounds
||| (1; then 2 and 5; then 6), then stable.
export
llog_2_5__strata_before : llog_2_5__well_founded [10] (Rete.Refcount.llog_2_5__strata_js1 ++ Rete.Refcount.llog_2_5__strata_js2) Rete.Refcount.llog_2_5__strata_all
                          = [1, 2, 5, 6, 10]
llog_2_5__strata_before =
  replace {p = \k => llog_2_5__derive_n 5 [10] (Rete.Refcount.llog_2_5__strata_js1 ++ Rete.Refcount.llog_2_5__strata_js2) Rete.Refcount.llog_2_5__strata_all k
                     = [1, 2, 5, 6, 10]} (sym k0)
    (llog_2_5__derive_n_cons 4 [10] (Rete.Refcount.llog_2_5__strata_js1 ++ Rete.Refcount.llog_2_5__strata_js2) Rete.Refcount.llog_2_5__strata_all
       [10] [1, 10] _ Refl
      (llog_2_5__derive_n_cons 3 [10] (Rete.Refcount.llog_2_5__strata_js1 ++ Rete.Refcount.llog_2_5__strata_js2) Rete.Refcount.llog_2_5__strata_all
         [1, 10] [1, 2, 5, 10] _ Refl
        (llog_2_5__derive_n_cons 2 [10] (Rete.Refcount.llog_2_5__strata_js1 ++ Rete.Refcount.llog_2_5__strata_js2) Rete.Refcount.llog_2_5__strata_all
           [1, 2, 5, 10] [1, 2, 5, 6, 10] _ Refl
          (llog_2_5__derive_n_stable 2 [10] (Rete.Refcount.llog_2_5__strata_js1 ++ Rete.Refcount.llog_2_5__strata_js2) Rete.Refcount.llog_2_5__strata_all
             [1, 2, 5, 6, 10] Refl))))
  where
    k0 : filter (\t => iret_12__elem t [10]) Rete.Refcount.llog_2_5__strata_all = [10]
    k0 = Refl

--@derives [LLOG.2.5]
||| Withdraw the seed: the global recompute keeps nothing, and the first
||| round already adds nothing.
export
llog_2_5__strata_after : llog_2_5__well_founded [] (Rete.Refcount.llog_2_5__strata_js1 ++ Rete.Refcount.llog_2_5__strata_js2) Rete.Refcount.llog_2_5__strata_all = []
llog_2_5__strata_after =
  llog_2_5__derive_n_stable 5 [] (Rete.Refcount.llog_2_5__strata_js1 ++ Rete.Refcount.llog_2_5__strata_js2) Rete.Refcount.llog_2_5__strata_all [] Refl

--@derives [LLOG.2.5]
||| Stratum by stratum, first the lower: its recompute from the surviving
||| inputs drops 1 and 2 -- its net diff is two retractions.
export
llog_2_5__strata_lower : llog_2_5__well_founded [] Rete.Refcount.llog_2_5__strata_js1 Rete.Refcount.llog_2_5__strata_all = []
llog_2_5__strata_lower = llog_2_5__derive_n_stable 5 [] Rete.Refcount.llog_2_5__strata_js1 Rete.Refcount.llog_2_5__strata_all [] Refl

--@derives [LLOG.2.5]
--@derives [LLOG.15.1]
||| Then the upper, over the lower's net-diff output: it drops 5 and 6,
||| although nothing of its own was withdrawn -- it read a fact the lower
||| stratum retracted.
export
llog_2_5__strata_upper : llog_2_5__well_founded [] Rete.Refcount.llog_2_5__strata_js2 Rete.Refcount.llog_2_5__strata_all = []
llog_2_5__strata_upper = llog_2_5__derive_n_stable 5 [] Rete.Refcount.llog_2_5__strata_js2 Rete.Refcount.llog_2_5__strata_all [] Refl

--@derives [LLOG.2.5]
--@derives [LLOG.15.1]
||| The two composed are the global recompute, as
||| `llog_2_5__stratified_compose` says in general.
export
llog_2_5__strata_composed : llog_2_5__well_founded (llog_2_5__well_founded [] Rete.Refcount.llog_2_5__strata_js1 Rete.Refcount.llog_2_5__strata_all)
                                                    Rete.Refcount.llog_2_5__strata_js2 Rete.Refcount.llog_2_5__strata_all = []
llog_2_5__strata_composed =
  replace {p = \b => llog_2_5__well_founded b Rete.Refcount.llog_2_5__strata_js2 Rete.Refcount.llog_2_5__strata_all = []}
          (sym llog_2_5__strata_lower) llog_2_5__strata_upper

--@derives [IRET.12.2]
||| The refcount on the same withdrawal keeps all four derived facts:
||| both cycles hold themselves up, the upper one through a lower-stratum
||| fact that is itself unfounded. The first step retracts nothing.
export
iret_12_2__strata_refcount : iret_12_2__cascade [] (Rete.Refcount.llog_2_5__strata_js1 ++ Rete.Refcount.llog_2_5__strata_js2) [1, 2, 5, 6] = [1, 2, 5, 6]
iret_12_2__strata_refcount =
  iret_12_2__cascade_n_stable 4 [] (Rete.Refcount.llog_2_5__strata_js1 ++ Rete.Refcount.llog_2_5__strata_js2) [1, 2, 5, 6] Refl

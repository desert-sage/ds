-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Machine-checked claims about the witness programs of Lcyc/Witnesses.idr:
||| divergence by literal periodicity (`lcyc_1_1__periodic_diverges`,
||| `lcyc_1_1__diverges_from`) and halting by evaluation. The run-composition
||| lemmas those rest on (`iret_11_4__step_n_plus`, `_prefix`) live here too:
||| Rete/FireLoop.idr is the model and carries no proofs.
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr.
||| Each claim is named under the clause its program exercises; the run's
||| states and single-firing equations it is built from live in the claim's
||| own `where` block, where they are proof-internal rather than elements
||| of the model.
|||
||| HOW THE PROOFS ARE SHAPED. Idris 2's type-level evaluator shares no
||| work between uses of a value, so one `Refl` over a twelve-firing run
||| does not finish. Each run is therefore given as its sequence of states,
||| written out as literals (printed by `iret_11_4__trace` and pasted), and
||| the claim is a chain of single-firing `Refl`s, `step (s i) = Just (s (i+1))`,
||| each of which the evaluator settles in seconds. Nothing is assumed about
||| the literals: a wrong literal fails its `Refl`.
|||
||| The states are one where-local FUNCTION `s : Nat -> state` per claim
||| rather than one constant each, because Idris 2 (0.8.0) does not unfold a
||| zero-argument where-local definition during conversion checking — a
||| `Refl` against a local constant `s0` fails with `s0` left opaque — while
||| a where-local function with a pattern argument reduces as expected.
||| `s n` for an `n` outside the run is the empty state, so `s` is total.
module Lcyc.WitnessProofs

import Rete.FireLoop
import Lcyc.Witnesses
import Data.List
import Data.Maybe
import Data.Nat

%default total

-- ---------------------------------------------------------------------
-- Chaining single firings
-- ---------------------------------------------------------------------

--@spec [LCYC.1.1]
||| Quiescent after exactly n firings: the run is still going after n and
||| the agenda is empty after n + 1.
public export
Lcyc_1_1__halts_at : Lcyc_3_2_1__program -> Nat -> Rarc_5_6_5__state -> Type
Lcyc_1_1__halts_at p n st = (IsJust (iret_11_4__step_n p n st), iret_11_4__step_n p (S n) st = Nothing)

--@derives [IRET.11.4]
||| One more firing at the front of a run.
export
iret_11_4__step_n_cons : (p : Lcyc_3_2_1__program) -> (n : Nat) -> (s, s' : Rarc_5_6_5__state) ->
                         (r : Maybe Rarc_5_6_5__state) ->
                         iret_11_4__step p s = Just s' -> iret_11_4__step_n p n s' = r ->
                         iret_11_4__step_n p (S n) s = r
iret_11_4__step_n_cons p n s s' r eq rest = rewrite eq in rest

--@derives [IRET.11.4]
||| A run that stops.
export
iret_11_4__step_n_end : (p : Lcyc_3_2_1__program) -> (n : Nat) -> (s : Rarc_5_6_5__state) ->
                        iret_11_4__step p s = Nothing -> iret_11_4__step_n p (S n) s = Nothing
iret_11_4__step_n_end p n s eq = rewrite eq in Refl

--@derives [IRET.11.4]
||| Runs compose: m + n firings is m firings, then n from where they left off.
export
iret_11_4__step_n_plus : (p : Lcyc_3_2_1__program) -> (m, n : Nat) -> (st : Rarc_5_6_5__state) ->
            iret_11_4__step_n p (m + n) st = (iret_11_4__step_n p m st >>= iret_11_4__step_n p n)
iret_11_4__step_n_plus p Z n st = Refl
iret_11_4__step_n_plus p (S m) n st with (iret_11_4__step p st)
  iret_11_4__step_n_plus p (S m) n st | Nothing = Refl
  iret_11_4__step_n_plus p (S m) n st | (Just st') = iret_11_4__step_n_plus p m n st'

--@derives [IRET.11.4]
||| Every prefix of a possible run is possible.
export
iret_11_4__step_n_prefix : (p : Lcyc_3_2_1__program) -> (m, n : Nat) -> (st : Rarc_5_6_5__state) ->
              IsJust (iret_11_4__step_n p (m + n) st) -> IsJust (iret_11_4__step_n p m st)
iret_11_4__step_n_prefix p Z n st prf = ItIsJust
iret_11_4__step_n_prefix p (S m) n st prf with (iret_11_4__step p st)
  iret_11_4__step_n_prefix p (S m) n st prf | Nothing = absurd prf
  iret_11_4__step_n_prefix p (S m) n st prf | (Just st') = iret_11_4__step_n_prefix p m n st' prf

--@derives [LCYC.1.1]
||| Divergence from a state reached after m firings is divergence from
||| the start.
export
lcyc_1_1__diverges_from : (p : Lcyc_3_2_1__program) -> (m : Nat) -> (st, st' : Rarc_5_6_5__state) ->
                          iret_11_4__step_n p m st = Just st' ->
                          Lcyc_1_1__diverges p st' -> Lcyc_1_1__diverges p st
lcyc_1_1__diverges_from p m st st' reach div n = case isLTE n m of
  Yes le =>
    let full : IsJust (iret_11_4__step_n p m st)
        full = rewrite reach in ItIsJust
    in iret_11_4__step_n_prefix p n (m `minus` n) st
         (rewrite plusCommutative n (m `minus` n) in rewrite plusMinusLte n m le in full)
  No gt =>
    let mLEn : LTE m n
        mLEn = lteSuccLeft (notLTEImpliesGT gt)
        tot : (m + (n `minus` m) = n)
        tot = trans (plusCommutative m (n `minus` m)) (plusMinusLte m n mLEn)
        split : (iret_11_4__step_n p n st = (iret_11_4__step_n p m st >>= iret_11_4__step_n p (n `minus` m)))
        split = replace {p = \x => iret_11_4__step_n p x st = (iret_11_4__step_n p m st >>= iret_11_4__step_n p (n `minus` m))}
                        tot (iret_11_4__step_n_plus p m (n `minus` m) st)
    in rewrite split in rewrite reach in div (n `minus` m)

--@derives [LCYC.1.1]
||| Period `S k`: after `S k` firings the state is literally `st` again, so
||| every multiple of `S k` firings is possible, and every prefix of a
||| possible run is possible.
export
lcyc_1_1__periodic_diverges : (p : Lcyc_3_2_1__program) -> (k : Nat) -> (st : Rarc_5_6_5__state) ->
                   iret_11_4__step_n p (S k) st = Just st -> Lcyc_1_1__diverges p st
lcyc_1_1__periodic_diverges p k st period n = go n
  where
    -- every multiple of the period is reachable, by induction on the multiplier
    multiples : (m : Nat) -> iret_11_4__step_n p (m * S k) st = Just st
    multiples Z = Refl
    multiples (S m) = rewrite iret_11_4__step_n_plus p (S k) (m * S k) st in
                      rewrite period in multiples m
    -- m <= m * S k, so m firings are a prefix of m * S k firings
    boundK : (m : Nat) -> LTE m (m * S k)
    boundK Z = LTEZero
    boundK (S m) = LTESucc (transitive (boundK m)
                     (rewrite plusCommutative k (m * S k) in lteAddRight (m * S k)))
    go : (m : Nat) -> IsJust (iret_11_4__step_n p m st)
    go m = let full : IsJust (iret_11_4__step_n p (m * S k) st)
               full = rewrite multiples m in ItIsJust
           in iret_11_4__step_n_prefix p m ((m * S k) `minus` m) st
                (rewrite plusCommutative m ((m * S k) `minus` m) in
                 rewrite plusMinusLte m (m * S k) (boundK m) in full)

-- ---------------------------------------------------------------------
-- W1. refill / drain: withdraw re-arming a `no`. Period 2 from the start.
-- The oscillation [LSCO.4.5.9] names, exhibited: the removal of X lets
-- refill fire again, re-establishing the condition drain fires on.
-- ---------------------------------------------------------------------

--@derives [LSCO.4.5.9]
export
lsco_4_5_9__refill_drain_diverges :
  Lcyc_1_1__diverges Lcyc.Witnesses.lsco_4_5_9__refill_drain Lcyc.Witnesses.lsco_4_5_9__refill_drain0
lsco_4_5_9__refill_drain_diverges = rewrite init in
  lcyc_1_1__periodic_diverges lsco_4_5_9__refill_drain 1 (s 0)
    (iret_11_4__step_n_cons lsco_4_5_9__refill_drain 1 (s 0) (s 1) (Just (s 0)) step0
      (iret_11_4__step_n_cons lsco_4_5_9__refill_drain 0 (s 1) (s 0) (Just (s 0)) step1 Refl))
  where
    s : Nat -> Rarc_5_6_5__state
    s 0 = MkState [] [[MkTok [] False False], []]
    s 1 = MkState [MkFact 0 0 0 0] [[MkTok [] True True], [MkTok [MkFact 0 0 0 0] False False]]
    s _ = MkState [] []
    init : Lcyc.Witnesses.lsco_4_5_9__refill_drain0 = s 0
    init = Refl
    step0 : iret_11_4__step Lcyc.Witnesses.lsco_4_5_9__refill_drain (s 0) = Just (s 1)
    step0 = Refl
    step1 : iret_11_4__step Lcyc.Witnesses.lsco_4_5_9__refill_drain (s 1) = Just (s 0)
    step1 = Refl

-- ---------------------------------------------------------------------
-- W2. Entity upsert churn. Period 2 from the start: each replace
-- [LFAC.2.5.3] is a new fact, hence a new token, hence a firing.
-- ---------------------------------------------------------------------

--@derives [LFAC.2.5.3]
export
lfac_2_5_3__churn_diverges :
  Lcyc_1_1__diverges Lcyc.Witnesses.lfac_2_5_3__churn_prog Lcyc.Witnesses.lfac_2_5_3__churn0
lfac_2_5_3__churn_diverges = rewrite init in
  lcyc_1_1__periodic_diverges lfac_2_5_3__churn_prog 1 (s 0)
    (iret_11_4__step_n_cons lfac_2_5_3__churn_prog 1 (s 0) (s 1) (Just (s 0)) step0
      (iret_11_4__step_n_cons lfac_2_5_3__churn_prog 0 (s 1) (s 0) (Just (s 0)) step1 Refl))
  where
    s : Nat -> Rarc_5_6_5__state
    s 0 = MkState [MkFact 0 0 1 0] [[MkTok [MkFact 0 0 1 0] False False]]
    s 1 = MkState [MkFact 1 0 1 1] [[MkTok [MkFact 1 0 1 1] False False]]
    s _ = MkState [] []
    init : Lcyc.Witnesses.lfac_2_5_3__churn0 = s 0
    init = Refl
    step0 : iret_11_4__step Lcyc.Witnesses.lfac_2_5_3__churn_prog (s 0) = Just (s 1)
    step0 = Refl
    step1 : iret_11_4__step Lcyc.Witnesses.lfac_2_5_3__churn_prog (s 1) = Just (s 0)
    step1 = Refl

-- ---------------------------------------------------------------------
-- W3. The SCC [LCYC.3.1.1] refuses (W emitted and matched inside it), with
-- an internal positive cycle. After the consumption fires (s 0 -> s 1 -> s 2),
-- the run is periodic: s 2 recurs after twelve more firings. The refusal is
-- not gratuitous.
-- ---------------------------------------------------------------------

--@derives [LCYC.3.1.1]
export
lcyc_3_1_1__row2_diverges : Lcyc_1_1__diverges Lcyc.Witnesses.lcyc_3_1_1__row2_prog Lcyc.Witnesses.lcyc_3_1_1__row2_s0
lcyc_3_1_1__row2_diverges = rewrite init in
  lcyc_1_1__diverges_from lcyc_3_1_1__row2_prog 2 (s 0) (s 2) reach
    (lcyc_1_1__periodic_diverges lcyc_3_1_1__row2_prog 11 (s 2) period)
  where
    s : Nat -> Rarc_5_6_5__state
    s 0 = MkState [MkFact 0 0 0 0, MkFact 1 1 0 0] [[MkTok [MkFact 0 0 0 0, MkFact 1 1 0 0] False False], [], []]
    s 1 = MkState [MkFact 1 1 0 0, MkFact 2 2 0 0] [[], [MkTok [MkFact 2 2 0 0] False False], []]
    s 2 = MkState [MkFact 1 1 0 0, MkFact 2 2 0 0, MkFact 0 3 0 0] [[], [MkTok [MkFact 2 2 0 0] True False], [MkTok [MkFact 0 3 0 0] False False]]
    s 3 = MkState [MkFact 1 1 0 0, MkFact 0 3 0 0, MkFact 3 2 0 1] [[], [MkTok [MkFact 3 2 0 1] False False], [MkTok [MkFact 0 3 0 0] True False]]
    s 4 = MkState [MkFact 1 1 0 0, MkFact 3 2 0 1, MkFact 2 3 0 1] [[], [MkTok [MkFact 3 2 0 1] True False], [MkTok [MkFact 2 3 0 1] False False]]
    s 5 = MkState [MkFact 1 1 0 0, MkFact 2 3 0 1, MkFact 0 2 0 0] [[], [MkTok [MkFact 0 2 0 0] False False], [MkTok [MkFact 2 3 0 1] True False]]
    s 6 = MkState [MkFact 1 1 0 0, MkFact 0 2 0 0, MkFact 3 3 0 0] [[], [MkTok [MkFact 0 2 0 0] True False], [MkTok [MkFact 3 3 0 0] False False]]
    s 7 = MkState [MkFact 1 1 0 0, MkFact 3 3 0 0, MkFact 2 2 0 1] [[], [MkTok [MkFact 2 2 0 1] False False], [MkTok [MkFact 3 3 0 0] True False]]
    s 8 = MkState [MkFact 1 1 0 0, MkFact 2 2 0 1, MkFact 0 3 0 1] [[], [MkTok [MkFact 2 2 0 1] True False], [MkTok [MkFact 0 3 0 1] False False]]
    s 9 = MkState [MkFact 1 1 0 0, MkFact 0 3 0 1, MkFact 3 2 0 0] [[], [MkTok [MkFact 3 2 0 0] False False], [MkTok [MkFact 0 3 0 1] True False]]
    s 10 = MkState [MkFact 1 1 0 0, MkFact 3 2 0 0, MkFact 2 3 0 0] [[], [MkTok [MkFact 3 2 0 0] True False], [MkTok [MkFact 2 3 0 0] False False]]
    s 11 = MkState [MkFact 1 1 0 0, MkFact 2 3 0 0, MkFact 0 2 0 1] [[], [MkTok [MkFact 0 2 0 1] False False], [MkTok [MkFact 2 3 0 0] True False]]
    s 12 = MkState [MkFact 1 1 0 0, MkFact 0 2 0 1, MkFact 3 3 0 1] [[], [MkTok [MkFact 0 2 0 1] True False], [MkTok [MkFact 3 3 0 1] False False]]
    s 13 = MkState [MkFact 1 1 0 0, MkFact 3 3 0 1, MkFact 2 2 0 0] [[], [MkTok [MkFact 2 2 0 0] False False], [MkTok [MkFact 3 3 0 1] True False]]
    s _ = MkState [] []
    init : Lcyc.Witnesses.lcyc_3_1_1__row2_s0 = s 0
    init = Refl
    step0 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 0) = Just (s 1)
    step0 = Refl
    step1 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 1) = Just (s 2)
    step1 = Refl
    step2 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 2) = Just (s 3)
    step2 = Refl
    step3 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 3) = Just (s 4)
    step3 = Refl
    step4 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 4) = Just (s 5)
    step4 = Refl
    step5 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 5) = Just (s 6)
    step5 = Refl
    step6 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 6) = Just (s 7)
    step6 = Refl
    step7 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 7) = Just (s 8)
    step7 = Refl
    step8 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 8) = Just (s 9)
    step8 = Refl
    step9 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 9) = Just (s 10)
    step9 = Refl
    step10 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 10) = Just (s 11)
    step10 = Refl
    step11 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 11) = Just (s 12)
    step11 = Refl
    step12 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 12) = Just (s 13)
    step12 = Refl
    step13 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__row2_prog (s 13) = Just (s 2)
    step13 = Refl
    reach : iret_11_4__step_n Lcyc.Witnesses.lcyc_3_1_1__row2_prog 2 (s 0) = Just (s 2)
    reach = iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 1 (s 0) (s 1) _ step0
              (iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 0 (s 1) (s 2) _ step1 Refl)
    period : iret_11_4__step_n Lcyc.Witnesses.lcyc_3_1_1__row2_prog 12 (s 2) = Just (s 2)
    period =
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 11 (s 2) (s 3) _ step2 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 10 (s 3) (s 4) _ step3 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 9 (s 4) (s 5) _ step4 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 8 (s 5) (s 6) _ step5 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 7 (s 6) (s 7) _ step6 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 6 (s 7) (s 8) _ step7 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 5 (s 8) (s 9) _ step8 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 4 (s 9) (s 10) _ step9 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 3 (s 10) (s 11) _ step10 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 2 (s 11) (s 12) _ step11 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 1 (s 12) (s 13) _ step12 (
      iret_11_4__step_n_cons lcyc_3_1_1__row2_prog 0 (s 13) (s 2) _ step13 Refl)))))))))))

-- ---------------------------------------------------------------------
-- W4. grow / reap over a dedup'd Reach on a cyclic graph, grow first:
-- grow, grow as a no-op, reap, quiescent. The `+recursive` proposal's own
-- §2 example, which it claimed cannot terminate.
-- ---------------------------------------------------------------------

--@gap
export
gap__grow_reap_rel_halts :
  Lcyc_1_1__halts_at Lcyc.Witnesses.gap__grow_reap_rel 3
    (rarc_5_6_5__init_state Lcyc.Witnesses.gap__grow_reap_rel Lcyc.Witnesses.gap__cyclic_input)
gap__grow_reap_rel_halts = replace {p = \x => Lcyc_1_1__halts_at gap__grow_reap_rel 3 x} (sym init)
  ( replace {p = \m => IsJust m}
      (sym (iret_11_4__step_n_cons gap__grow_reap_rel 2 (s 0) (s 1) (Just (s 3)) step0
              (iret_11_4__step_n_cons gap__grow_reap_rel 1 (s 1) (s 2) (Just (s 3)) step1
                (iret_11_4__step_n_cons gap__grow_reap_rel 0 (s 2) (s 3) (Just (s 3)) step2 Refl)))) ItIsJust
  , iret_11_4__step_n_cons gap__grow_reap_rel 3 (s 0) (s 1) Nothing step0
      (iret_11_4__step_n_cons gap__grow_reap_rel 2 (s 1) (s 2) Nothing step1
        (iret_11_4__step_n_cons gap__grow_reap_rel 1 (s 2) (s 3) Nothing step2
          (iret_11_4__step_n_end gap__grow_reap_rel 0 (s 3) step3))) )
  where
    s : Nat -> Rarc_5_6_5__state
    s 0 = MkState [MkFact 0 5 1 2, MkFact 1 5 2 1, MkFact 2 4 1 2] [[MkTok [MkFact 2 4 1 2, MkFact 1 5 2 1] False False], []]
    s 1 = MkState [MkFact 0 5 1 2, MkFact 1 5 2 1, MkFact 2 4 1 2, MkFact 3 4 1 1] [[MkTok [MkFact 2 4 1 2, MkFact 1 5 2 1] True False, MkTok [MkFact 3 4 1 1, MkFact 0 5 1 2] False False], [MkTok [MkFact 3 4 1 1] False False]]
    s 2 = MkState [MkFact 0 5 1 2, MkFact 1 5 2 1, MkFact 2 4 1 2, MkFact 3 4 1 1] [[MkTok [MkFact 2 4 1 2, MkFact 1 5 2 1] True False, MkTok [MkFact 3 4 1 1, MkFact 0 5 1 2] True False], [MkTok [MkFact 3 4 1 1] False False]]
    s 3 = MkState [MkFact 0 5 1 2, MkFact 1 5 2 1, MkFact 2 4 1 2] [[MkTok [MkFact 2 4 1 2, MkFact 1 5 2 1] True False], []]
    s _ = MkState [] []
    init : rarc_5_6_5__init_state Lcyc.Witnesses.gap__grow_reap_rel Lcyc.Witnesses.gap__cyclic_input = s 0
    init = Refl
    step0 : iret_11_4__step Lcyc.Witnesses.gap__grow_reap_rel (s 0) = Just (s 1)
    step0 = Refl
    step1 : iret_11_4__step Lcyc.Witnesses.gap__grow_reap_rel (s 1) = Just (s 2)
    step1 = Refl
    step2 : iret_11_4__step Lcyc.Witnesses.gap__grow_reap_rel (s 2) = Just (s 3)
    step2 = Refl
    step3 : iret_11_4__step Lcyc.Witnesses.gap__grow_reap_rel (s 3) = Nothing
    step3 = Refl

-- ---------------------------------------------------------------------
-- W5. grow / reap over an EXPLICIT Reach, reap first: reap kills the
-- self-loop fact before grow can use it. Two firings and quiescent.
-- ---------------------------------------------------------------------

--@gap
export
gap__reap_grow_exp_halts :
  Lcyc_1_1__halts_at Lcyc.Witnesses.gap__reap_grow_exp 2
    (rarc_5_6_5__init_state Lcyc.Witnesses.gap__reap_grow_exp Lcyc.Witnesses.gap__cyclic_input)
gap__reap_grow_exp_halts = replace {p = \x => Lcyc_1_1__halts_at gap__reap_grow_exp 2 x} (sym init)
  ( replace {p = \m => IsJust m}
      (sym (iret_11_4__step_n_cons gap__reap_grow_exp 1 (s 0) (s 1) (Just (s 2)) step0
              (iret_11_4__step_n_cons gap__reap_grow_exp 0 (s 1) (s 2) (Just (s 2)) step1 Refl))) ItIsJust
  , iret_11_4__step_n_cons gap__reap_grow_exp 2 (s 0) (s 1) Nothing step0
      (iret_11_4__step_n_cons gap__reap_grow_exp 1 (s 1) (s 2) Nothing step1
        (iret_11_4__step_n_end gap__reap_grow_exp 0 (s 2) step2)) )
  where
    s : Nat -> Rarc_5_6_5__state
    s 0 = MkState [MkFact 0 5 1 2, MkFact 1 5 2 1, MkFact 2 4 1 2] [[], [MkTok [MkFact 2 4 1 2, MkFact 1 5 2 1] False False]]
    s 1 = MkState [MkFact 0 5 1 2, MkFact 1 5 2 1, MkFact 2 4 1 2, MkFact 3 4 1 1] [[MkTok [MkFact 3 4 1 1] False False], [MkTok [MkFact 2 4 1 2, MkFact 1 5 2 1] True False, MkTok [MkFact 3 4 1 1, MkFact 0 5 1 2] False False]]
    s 2 = MkState [MkFact 0 5 1 2, MkFact 1 5 2 1, MkFact 2 4 1 2] [[], [MkTok [MkFact 2 4 1 2, MkFact 1 5 2 1] True False]]
    s _ = MkState [] []
    init : rarc_5_6_5__init_state Lcyc.Witnesses.gap__reap_grow_exp Lcyc.Witnesses.gap__cyclic_input = s 0
    init = Refl
    step0 : iret_11_4__step Lcyc.Witnesses.gap__reap_grow_exp (s 0) = Just (s 1)
    step0 = Refl
    step1 : iret_11_4__step Lcyc.Witnesses.gap__reap_grow_exp (s 1) = Just (s 2)
    step1 = Refl
    step2 : iret_11_4__step Lcyc.Witnesses.gap__reap_grow_exp (s 2) = Nothing
    step2 = Refl

-- ---------------------------------------------------------------------
-- W4 / W5, the two corners that do not halt: an EXPLICIT Reach with grow
-- first. Reach accumulates, so every firing re-derives a Reach the memory
-- already holds as a new fact and the closure never settles. A
-- fuel-bounded model cannot state divergence; it can state that a run does
-- not quiesce within a fuel. Six firings: twice what any halting corner
-- needs (they quiesce by the second or third), and as much as the
-- elaborator will normalise in reasonable time -- twenty did not finish.
-- ---------------------------------------------------------------------

--@gap
||| grow then reap over an Explicit Reach: six firings, no quiescence.
export
gap__grow_reap_exp_fuel_out :
  fst (snd (iret_11_4__run Lcyc.Witnesses.gap__grow_reap_exp 6
              (rarc_5_6_5__init_state Lcyc.Witnesses.gap__grow_reap_exp Lcyc.Witnesses.gap__cyclic_input))) = FuelOut
gap__grow_reap_exp_fuel_out = Refl

--@gap
||| grow alone over an Explicit Reach: the same, with nothing to reap.
export
gap__grow_only_exp_fuel_out :
  fst (snd (iret_11_4__run Lcyc.Witnesses.gap__grow_only_exp 6
              (rarc_5_6_5__init_state Lcyc.Witnesses.gap__grow_only_exp Lcyc.Witnesses.gap__cyclic_input))) = FuelOut
gap__grow_only_exp_fuel_out = Refl

-- ---------------------------------------------------------------------
-- grow alone over a dedup'd Reach: closure of a cyclic graph, two
-- firings (the second a no-op) and quiescent — the one shape recursion
-- terminates under, and the instance of the certificate's theorem.
-- ---------------------------------------------------------------------

--@gap
export
gap__grow_only_rel_halts :
  Lcyc_1_1__halts_at Lcyc.Witnesses.gap__grow_only_rel 2
    (rarc_5_6_5__init_state Lcyc.Witnesses.gap__grow_only_rel Lcyc.Witnesses.gap__cyclic_input)
gap__grow_only_rel_halts = replace {p = \x => Lcyc_1_1__halts_at gap__grow_only_rel 2 x} (sym init)
  ( replace {p = \m => IsJust m}
      (sym (iret_11_4__step_n_cons gap__grow_only_rel 1 (s 0) (s 1) (Just (s 2)) step0
              (iret_11_4__step_n_cons gap__grow_only_rel 0 (s 1) (s 2) (Just (s 2)) step1 Refl))) ItIsJust
  , iret_11_4__step_n_cons gap__grow_only_rel 2 (s 0) (s 1) Nothing step0
      (iret_11_4__step_n_cons gap__grow_only_rel 1 (s 1) (s 2) Nothing step1
        (iret_11_4__step_n_end gap__grow_only_rel 0 (s 2) step2)) )
  where
    s : Nat -> Rarc_5_6_5__state
    s 0 = MkState [MkFact 0 5 1 2, MkFact 1 5 2 1, MkFact 2 4 1 2] [[MkTok [MkFact 2 4 1 2, MkFact 1 5 2 1] False False]]
    s 1 = MkState [MkFact 0 5 1 2, MkFact 1 5 2 1, MkFact 2 4 1 2, MkFact 3 4 1 1] [[MkTok [MkFact 2 4 1 2, MkFact 1 5 2 1] True False, MkTok [MkFact 3 4 1 1, MkFact 0 5 1 2] False False]]
    s 2 = MkState [MkFact 0 5 1 2, MkFact 1 5 2 1, MkFact 2 4 1 2, MkFact 3 4 1 1] [[MkTok [MkFact 2 4 1 2, MkFact 1 5 2 1] True False, MkTok [MkFact 3 4 1 1, MkFact 0 5 1 2] True False]]
    s _ = MkState [] []
    init : rarc_5_6_5__init_state Lcyc.Witnesses.gap__grow_only_rel Lcyc.Witnesses.gap__cyclic_input = s 0
    init = Refl
    step0 : iret_11_4__step Lcyc.Witnesses.gap__grow_only_rel (s 0) = Just (s 1)
    step0 = Refl
    step1 : iret_11_4__step Lcyc.Witnesses.gap__grow_only_rel (s 1) = Just (s 2)
    step1 = Refl
    step2 : iret_11_4__step Lcyc.Witnesses.gap__grow_only_rel (s 2) = Nothing
    step2 = Refl

-- ---------------------------------------------------------------------
-- W6. Rules that defeat each other, over explicit facts: one firing, and
-- the run settles on the answer source order gives — [LCYC.2.3.2]'s
-- "settle on one answer depending on which rule the engine evaluated
-- first", with the rule fixed by [LDET.5.4].
-- ---------------------------------------------------------------------

--@derives [LCYC.2.3.2]
export
lcyc_2_3_2__defeat_halts :
  Lcyc_1_1__halts_at Lcyc.Witnesses.lcyc_2_3_1__defeat_prog 1 Lcyc.Witnesses.lcyc_2_3_1__defeat0
lcyc_2_3_2__defeat_halts = replace {p = \x => Lcyc_1_1__halts_at lcyc_2_3_1__defeat_prog 1 x} (sym init)
  ( replace {p = \m => IsJust m}
      (sym (iret_11_4__step_n_cons lcyc_2_3_1__defeat_prog 0 (s 0) (s 1) (Just (s 1)) step0 Refl)) ItIsJust
  , iret_11_4__step_n_cons lcyc_2_3_1__defeat_prog 1 (s 0) (s 1) Nothing step0
      (iret_11_4__step_n_end lcyc_2_3_1__defeat_prog 0 (s 1) step1) )
  where
    s : Nat -> Rarc_5_6_5__state
    s 0 = MkState [] [[MkTok [] False False], [MkTok [] False False]]
    s 1 = MkState [MkFact 0 0 0 0] [[MkTok [] True False], [MkTok [] False True]]
    s _ = MkState [] []
    init : Lcyc.Witnesses.lcyc_2_3_1__defeat0 = s 0
    init = Refl
    step0 : iret_11_4__step Lcyc.Witnesses.lcyc_2_3_1__defeat_prog (s 0) = Just (s 1)
    step0 = Refl
    step1 : iret_11_4__step Lcyc.Witnesses.lcyc_2_3_1__defeat_prog (s 1) = Nothing
    step1 = Refl

-- ---------------------------------------------------------------------
-- W8. The join wave over dedup'd kinds, in the reference source order:
-- three no-op re-emits, three withdrawals, quiescent after six firings.
-- [LCYC.3.1.1] refuses this SCC too (X is emitted by RX and matched by
-- three rules), so this is the certificate being conservative, knowingly.
-- (Every one of the 720 orders quiesced within 30 in the REPL sweep,
-- `lcyc_3_1_1__sweep_join_wave`; that run is not a proof.)
-- ---------------------------------------------------------------------

--@derives [LCYC.3.1.1]
export
lcyc_3_1_1__join_wave_rel_halts :
  Lcyc_1_1__halts_at Lcyc.Witnesses.lcyc_3_1_1__join_wave_rel 6
    (rarc_5_6_5__init_state Lcyc.Witnesses.lcyc_3_1_1__join_wave_rel Lcyc.Witnesses.lcyc_3_1_1__join_wave_input)
lcyc_3_1_1__join_wave_rel_halts = replace {p = \x => Lcyc_1_1__halts_at lcyc_3_1_1__join_wave_rel 6 x} (sym init)
  ( replace {p = \m => IsJust m}
      (sym (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 5 (s 0) (s 1) (Just (s 6)) step0
              (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 4 (s 1) (s 2) (Just (s 6)) step1
                (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 3 (s 2) (s 3) (Just (s 6)) step2
                  (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 2 (s 3) (s 4) (Just (s 6)) step3
                    (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 1 (s 4) (s 5) (Just (s 6)) step4
                      (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 0 (s 5) (s 6) (Just (s 6)) step5 Refl))))))) ItIsJust
  , iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 6 (s 0) (s 1) Nothing step0
      (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 5 (s 1) (s 2) Nothing step1
        (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 4 (s 2) (s 3) Nothing step2
          (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 3 (s 3) (s 4) Nothing step3
            (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 2 (s 4) (s 5) Nothing step4
              (iret_11_4__step_n_cons lcyc_3_1_1__join_wave_rel 1 (s 5) (s 6) Nothing step5
                (iret_11_4__step_n_end lcyc_3_1_1__join_wave_rel 0 (s 6) step6)))))) )
  where
    s : Nat -> Rarc_5_6_5__state
    s 0 = MkState [MkFact 0 0 0 0, MkFact 1 1 0 0, MkFact 2 6 0 0] [[MkTok [MkFact 1 1 0 0, MkFact 2 6 0 0] False False], [MkTok [MkFact 0 0 0 0] False False], [MkTok [MkFact 0 0 0 0] False False], [MkTok [MkFact 0 0 0 0] False False], [MkTok [MkFact 1 1 0 0] False False], [MkTok [MkFact 2 6 0 0] False False]]
    s 1 = MkState [MkFact 0 0 0 0, MkFact 1 1 0 0, MkFact 2 6 0 0] [[MkTok [MkFact 1 1 0 0, MkFact 2 6 0 0] True False], [MkTok [MkFact 0 0 0 0] False False], [MkTok [MkFact 0 0 0 0] False False], [MkTok [MkFact 0 0 0 0] False False], [MkTok [MkFact 1 1 0 0] False False], [MkTok [MkFact 2 6 0 0] False False]]
    s 2 = MkState [MkFact 0 0 0 0, MkFact 1 1 0 0, MkFact 2 6 0 0] [[MkTok [MkFact 1 1 0 0, MkFact 2 6 0 0] True False], [MkTok [MkFact 0 0 0 0] True False], [MkTok [MkFact 0 0 0 0] False False], [MkTok [MkFact 0 0 0 0] False False], [MkTok [MkFact 1 1 0 0] False False], [MkTok [MkFact 2 6 0 0] False False]]
    s 3 = MkState [MkFact 0 0 0 0, MkFact 1 1 0 0, MkFact 2 6 0 0] [[MkTok [MkFact 1 1 0 0, MkFact 2 6 0 0] True False], [MkTok [MkFact 0 0 0 0] True False], [MkTok [MkFact 0 0 0 0] True False], [MkTok [MkFact 0 0 0 0] False False], [MkTok [MkFact 1 1 0 0] False False], [MkTok [MkFact 2 6 0 0] False False]]
    s 4 = MkState [MkFact 1 1 0 0, MkFact 2 6 0 0] [[MkTok [MkFact 1 1 0 0, MkFact 2 6 0 0] True False], [], [], [], [MkTok [MkFact 1 1 0 0] False False], [MkTok [MkFact 2 6 0 0] False False]]
    s 5 = MkState [MkFact 2 6 0 0] [[], [], [], [], [], [MkTok [MkFact 2 6 0 0] False False]]
    s 6 = MkState [] [[], [], [], [], [], []]
    s _ = MkState [] []
    init : rarc_5_6_5__init_state Lcyc.Witnesses.lcyc_3_1_1__join_wave_rel Lcyc.Witnesses.lcyc_3_1_1__join_wave_input = s 0
    init = Refl
    step0 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__join_wave_rel (s 0) = Just (s 1)
    step0 = Refl
    step1 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__join_wave_rel (s 1) = Just (s 2)
    step1 = Refl
    step2 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__join_wave_rel (s 2) = Just (s 3)
    step2 = Refl
    step3 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__join_wave_rel (s 3) = Just (s 4)
    step3 = Refl
    step4 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__join_wave_rel (s 4) = Just (s 5)
    step4 = Refl
    step5 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__join_wave_rel (s 5) = Just (s 6)
    step5 = Refl
    step6 : iret_11_4__step Lcyc.Witnesses.lcyc_3_1_1__join_wave_rel (s 6) = Nothing
    step6 = Refl

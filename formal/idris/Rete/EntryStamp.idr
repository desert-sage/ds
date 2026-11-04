-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The entry stamp's lifecycle: which asserts stamp ([LTIM.2.8.6]), on the
||| engine's own assert. The two-clock draft's gap 1.
|||
||| THE CLAUSES. [LTIM.2.8.6]: the engine stamps each fact, when it enters
||| working memory, with the monotonic clock's current sample; a fact
||| replaced by retract-and-replace ([LFAC.1.2.2]) enters anew and takes a
||| new stamp; a suppressed no-op reassertion ([LFAC.2.5.1]) does not enter
||| and keeps its stamp; `dwell` and `within` measure from the entry stamp.
||| [IRET.4.3]: the stamp is the fact's `assert_ns`.
|||
||| STANDS ON THE ASSERT. Which asserts enter working memory and which are
||| suppressed is decided by `Rete/FireLoop.idr`'s `iret_19_1__assert_fact`,
||| under the lifecycle: suppressed is `Nothing`, entered is `Just` the new
||| working memory with the minted fact. The stamps are a table beside
||| working memory, from fact id to stamp, as `Rete/TtlSweep.idr` keeps the
||| deadlines; that module's table is for TTL kinds alone, whose assert
||| always mints, so the two cases the clause names are decided here and not
||| there.
|||
||| WHAT IS PROVED, for every lifecycle, working memory, value and sample. A
||| suppressed reassertion leaves every stamp as it was
||| (`ltim_2_8_6__suppressed_keeps_stamps`); an assert that changes working
||| memory stamps the fact it minted with the sample
||| (`ltim_2_8_6__entered_is_stamped`). One entity, executed: asserted at 3;
||| reasserted unchanged at 5, its stamp still 3; replaced at 8, the new
||| fact stamped 8 and the old id without a row
||| (`ltim_2_8_6__three_asserts`).
|||
||| AND WHAT THE STAMP GIVES A GATE. For a fixed stamp, a `dwell >= d` gate
||| true at one monotonic sample is true at every later one
||| (`ltim_2_8_6__dwell_gate_rises`), and a `within` false at one sample is
||| false at every later one (`ltim_2_7_1__within_falls`). Each uses that
||| the monotonic clock does not decrease and that a suppressed reassertion
||| leaves the stamp. What that gives [LTIM.2.5.1]: a gate on elapsed
||| monotonic time changes at most once for one entry, so it cannot shut
||| and reopen, and once per edge is once per wrapper for it. Only a gate
||| that reads the wall clock can reopen, which is what [LTIM.2.8.3]'s last
||| sentence says.
|||
||| NOT MODELLED. The stamps threaded through a run of firings, that every
||| fact a pump mints is stamped with the pump's held sample ([IRET.19.1],
||| step 4), and that a cascade's retractions drop their rows; the stamp as
||| a field of the fact ([IRET.4.3]'s `assert_ns`), which is the table here.
module Rete.EntryStamp

import Rete.FireLoop
import Lcyc.Lemmas
import TwoClocks
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The stamps, and what the assert does to them
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.6]
--@spec [IRET.4.3]
||| The entry stamps: fact id to the monotonic sample at which it entered.
public export
Ltim_2_8_6__stamps : Type
Ltim_2_8_6__stamps = List (Nat, Nat)

--@spec [LTIM.2.8.6]
||| The row is the one looked for, or it is not: a first-order choice, so
||| that a proof can rewrite the comparison and let the choice reduce.
public export
ltim_2_8_6__pick : Bool -> Nat -> Maybe Nat -> Maybe Nat
ltim_2_8_6__pick True v _ = Just v
ltim_2_8_6__pick False _ r = r

--@spec [LTIM.2.8.6]
||| A fact's stamp, by id: `Nothing` for a fact that never entered.
public export
ltim_2_8_6__stamp_of : Nat -> Ltim_2_8_6__stamps -> Maybe Nat
ltim_2_8_6__stamp_of i [] = Nothing
ltim_2_8_6__stamp_of i ((j, v) :: rest) = ltim_2_8_6__pick (j == i) v (ltim_2_8_6__stamp_of i rest)

--@spec [LTIM.2.8.6]
--@spec [LFAC.1.2.2]
||| AFTER AN ASSERT THAT CHANGED WORKING MEMORY: a row for the id it minted,
||| at the sample; the rows of facts no longer live go, and so does any
||| stale row of the minted id.
public export
ltim_2_8_6__restamp : Rarc_5_6_4__wm -> (minted, now : Nat) -> Ltim_2_8_6__stamps -> Ltim_2_8_6__stamps
ltim_2_8_6__restamp wm' minted now st =
  (minted, now) :: filter (\r => rarc_5_6_4__is_live (fst r) wm' && not (fst r == minted)) st

--@spec [LTIM.2.8.6]
--@spec [LFAC.2.5.1]
||| WHAT THE ASSERT'S OUTCOME DOES TO THE STAMPS: nothing where it was
||| suppressed; the re-stamp where it changed working memory.
public export
ltim_2_8_6__after : (minted, now : Nat) -> Ltim_2_8_6__stamps -> Maybe Rarc_5_6_4__wm -> Ltim_2_8_6__stamps
ltim_2_8_6__after minted now st Nothing = st
ltim_2_8_6__after minted now st (Just wm') = ltim_2_8_6__restamp wm' minted now st

--@spec [LTIM.2.8.6]
||| THE ENGINE'S ASSERT, at a monotonic sample, on the stamps: the id it
||| would mint is the fresh one, and the outcome decides.
public export
ltim_2_8_6__assert_stamps : Lscp_1_3__lifecycle -> List Nat -> (kind, key, pay : Nat) -> (now : Nat) ->
                            Rarc_5_6_4__wm -> Ltim_2_8_6__stamps -> Ltim_2_8_6__stamps
ltim_2_8_6__assert_stamps life avoid kind key pay now wm st =
  ltim_2_8_6__after (lfac_2_5_3__fresh_id avoid wm) now st (iret_19_1__assert_fact life avoid kind key pay wm)

-- ---------------------------------------------------------------------
-- Suppressed keeps, entered stamps
-- ---------------------------------------------------------------------

--@derives [LTIM.2.8.6]
--@derives [LFAC.2.5.1]
||| A SUPPRESSED REASSERTION LEAVES EVERY STAMP AS IT WAS: for every
||| lifecycle, working memory, value and sample.
export
ltim_2_8_6__suppressed_keeps_stamps : (life : Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (kind, key, pay, now : Nat) ->
                                      (wm : Rarc_5_6_4__wm) -> (st : Ltim_2_8_6__stamps) ->
                                      iret_19_1__assert_fact life avoid kind key pay wm = Nothing ->
                                      ltim_2_8_6__assert_stamps life avoid kind key pay now wm st = st
ltim_2_8_6__suppressed_keeps_stamps life avoid kind key pay now wm st eq =
  cong (ltim_2_8_6__after (lfac_2_5_3__fresh_id avoid wm) now st) eq

--@derives [LTIM.2.8.6]
||| The row at the head is found.
export
ltim_2_8_6__stamp_of_head : (i, v : Nat) -> (rest : Ltim_2_8_6__stamps) -> ltim_2_8_6__stamp_of i ((i, v) :: rest) = Just v
ltim_2_8_6__stamp_of_head i v rest =
  cong (\b => ltim_2_8_6__pick b v (ltim_2_8_6__stamp_of i rest)) (lcyc_1_1__nat_eq_refl i)

--@derives [LTIM.2.8.6]
--@derives [LFAC.1.2.2]
||| AN ASSERT THAT CHANGES WORKING MEMORY STAMPS THE FACT IT MINTED with the
||| sample, for every lifecycle, working memory, value and sample.
export
ltim_2_8_6__entered_is_stamped : (life : Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (kind, key, pay, now : Nat) ->
                                 (wm, wm' : Rarc_5_6_4__wm) -> (st : Ltim_2_8_6__stamps) ->
                                 iret_19_1__assert_fact life avoid kind key pay wm = Just wm' ->
                                 ltim_2_8_6__stamp_of (lfac_2_5_3__fresh_id avoid wm) (ltim_2_8_6__assert_stamps life avoid kind key pay now wm st) = Just now
ltim_2_8_6__entered_is_stamped life avoid kind key pay now wm wm' st eq =
  trans (cong (\o => ltim_2_8_6__stamp_of (lfac_2_5_3__fresh_id avoid wm) (ltim_2_8_6__after (lfac_2_5_3__fresh_id avoid wm) now st o)) eq)
        (ltim_2_8_6__stamp_of_head (lfac_2_5_3__fresh_id avoid wm) now
           (filter (\r => rarc_5_6_4__is_live (fst r) wm' && not (fst r == lfac_2_5_3__fresh_id avoid wm)) st))

-- ---------------------------------------------------------------------
-- One entity, three asserts
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.6]
||| An entity of kind 0 and key 1, asserted with value 10 at sample 3.
public export
ltim_2_8_6__first : (Rarc_5_6_4__wm, Ltim_2_8_6__stamps)
ltim_2_8_6__first = ( [MkFact 0 0 1 10]
                    , ltim_2_8_6__assert_stamps Entity [] 0 1 10 3 [] [] )

--@spec [LTIM.2.8.6]
||| Reasserted unchanged at 5: the assert is suppressed.
public export
ltim_2_8_6__second : Ltim_2_8_6__stamps
ltim_2_8_6__second = ltim_2_8_6__assert_stamps Entity [] 0 1 10 5 (fst ltim_2_8_6__first) (snd ltim_2_8_6__first)

--@spec [LTIM.2.8.6]
||| Replaced with value 20 at 8: retract-and-replace mints a new fact.
public export
ltim_2_8_6__third : Ltim_2_8_6__stamps
ltim_2_8_6__third = ltim_2_8_6__assert_stamps Entity [] 0 1 20 8 (fst ltim_2_8_6__first) ltim_2_8_6__second

--@derives [LTIM.2.8.6]
--@derives [LFAC.2.5.1]
--@derives [LFAC.1.2.2]
||| THREE ASSERTS, EXECUTED: stamped 3 on entry; still 3 after the
||| suppressed reassertion at 5; after the replacement at 8 the new fact,
||| id 1, is stamped 8 and the old id has no row.
export
ltim_2_8_6__three_asserts :
  ( snd ltim_2_8_6__first = [(0, 3)]
  , ltim_2_8_6__second = [(0, 3)]
  , ltim_2_8_6__third = [(1, 8)] )
ltim_2_8_6__three_asserts = (Refl, Refl, Refl)

-- ---------------------------------------------------------------------
-- What the stamp gives a gate: it changes at most once
-- ---------------------------------------------------------------------

--@derives [LTIM.2.8.6]
||| From the Boolean order to the proof.
export
ltim_2_8_6__lte_true : (a, b : Nat) -> lte a b = True -> LTE a b
ltim_2_8_6__lte_true Z b prf = LTEZero
ltim_2_8_6__lte_true (S a) Z prf = absurd prf
ltim_2_8_6__lte_true (S a) (S b) prf = LTESucc (ltim_2_8_6__lte_true a b prf)

--@derives [LTIM.2.8.6]
||| And back.
export
ltim_2_8_6__lte_of : (a, b : Nat) -> LTE a b -> lte a b = True
ltim_2_8_6__lte_of Z b LTEZero = Refl
ltim_2_8_6__lte_of (S a) (S b) (LTESucc le) = ltim_2_8_6__lte_of a b le

--@derives [LTIM.2.8.6]
||| A false Boolean order is the strict order the other way.
export
ltim_2_8_6__lte_false : (a, b : Nat) -> lte a b = False -> LTE (S b) a
ltim_2_8_6__lte_false Z b prf = absurd prf
ltim_2_8_6__lte_false (S a) Z prf = LTESucc LTEZero
ltim_2_8_6__lte_false (S a) (S b) prf = LTESucc (ltim_2_8_6__lte_false a b prf)

--@derives [LTIM.2.8.6]
||| And back.
export
ltim_2_8_6__gt_of : (a, b : Nat) -> LTE (S b) a -> lte a b = False
ltim_2_8_6__gt_of Z b le = absurd le
ltim_2_8_6__gt_of (S a) Z (LTESucc _) = Refl
ltim_2_8_6__gt_of (S a) (S b) (LTESucc le) = ltim_2_8_6__gt_of a b le

--@derives [LTIM.2.8.6]
--@derives [LTIM.2.5.1]
||| A `dwell >= d` GATE RISES ONCE: for a fixed stamp, true at one monotonic
||| sample, it is true at every later one, whatever the wall clock does.
export
ltim_2_8_6__dwell_gate_rises : (stamp, d, m, m', w, w' : Nat) -> LTE m m' ->
                               lte d (lexp_9_5_1__dwell (m, w) stamp) = True ->
                               lte d (lexp_9_5_1__dwell (m', w') stamp) = True
ltim_2_8_6__dwell_gate_rises stamp d m m' w w' le h =
  ltim_2_8_6__lte_of d (minus m' stamp)
    (transitive (ltim_2_8_6__lte_true d (minus m stamp) h) (minusLteMonotone le))

--@derives [LTIM.2.7.1]
--@derives [LTIM.2.5.1]
||| A `within` FALLS ONCE: for a fixed stamp, false at one monotonic sample,
||| it is false at every later one, whatever the wall clock does.
export
ltim_2_7_1__within_falls : (stamp, dur, m, m', w, w' : Nat) -> LTE m m' ->
                           ltim_2_7_1__within (m, w) stamp dur = False ->
                           ltim_2_7_1__within (m', w') stamp dur = False
ltim_2_7_1__within_falls stamp dur m m' w w' le h =
  ltim_2_8_6__gt_of (S (minus m' stamp)) dur
    (LTESucc (transitive (fromLteSucc (ltim_2_8_6__lte_false (S (minus m stamp)) dur h))
                         (minusLteMonotone le)))

-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| A series window's membership is settled by the monotonic clock, and a
||| query discounts what eviction has not yet removed ([LSIG.2.5.1],
||| [LTIM.2.8.2]). The half `TwoClocks.idr`'s `ltim_2_8_2__in_window` leaves
||| unsaid.
|||
||| THE CLAUSE. [LSIG.2.5.1]: "Eviction of backing state is driven by new
||| assertions, not by query time, but every query returns a fresh answer as
||| of the monotonic clock's sample `t`: the query walks and discounts the
||| not-yet-evicted out-of-window portion without mutating stored state."
||| Two operations on one store, then: EVICTION, at the sample of an
||| assertion, which drops what has left the window; and the DISCOUNT, at
||| the sample of a query, which sees only what is still in the window and
||| writes nothing. The claim with content is that the two compose: a store
||| evicted at any earlier sample and discounted at `t` has the members the
||| unevicted store has at `t`. So eviction may lag a query by any number of
||| samples, or run at every one, and the query's answer is the same.
|||
||| WHAT IS PROVED. For every store, every window, every pair of monotonic
||| samples `m <= m'` and every two wall samples, the discount at `m'` of the
||| store evicted at `m` is the discount at `m'` of the store
||| (`lsig_2_5_1__discount_after_eviction`). It rests on one fact, which is
||| why the clause can say "driven by new assertions, not by query time":
||| a value that has left a window never re-enters it on a clock that does
||| not go back (`lsig_2_5_1__out_stays_out`, the `in_window` instance of
||| `Rete/EntryStamp.idr`'s `ltim_2_7_1__within_falls`). The hypothesis
||| `m <= m'` is [LTIM.2.8.2]'s monotonic clock between an assertion and a
||| later query; the witness `lsig_2_5_1__query_before_eviction_differs`
||| shows it is needed, by an eviction at a sample AFTER the query's.
|||
||| NOT MODELLED. The discounted VALUE: what `active_fraction`, `onset_rate`
||| or `integral` compute over the members. A store here is the monotonic
||| samples at which a series' values were absorbed, and what is proved is
||| which of them a query at `t` takes into account. The window's width is
||| one `w` for the store; the per-aggregation windows of [LSER.10.18] are
||| one store each.
module SeriesWindow

import Data.Nat
import Data.List
import TwoClocks
import Rete.EntryStamp

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The store, the discount and eviction
-- ---------------------------------------------------------------------

--@spec [LSIG.2.5.1]
||| THE STORE: the monotonic samples at which a series' values were
||| absorbed and not yet evicted. What a value is is not modelled; which
||| values take part is.
public export
Lsig_2_5_1__store : Type
Lsig_2_5_1__store = List Nat

--@spec [LSIG.2.5.1]
||| THE DISCOUNT: what a query at sample `s` sees of a store, for a window
||| of `w` -- the members still in the window at `s`, the rest discounted.
||| The store is not mutated: this is a reading of it.
public export
lsig_2_5_1__discount : Ltim_2_8_1__sample -> (w : Nat) -> Lsig_2_5_1__store -> Lsig_2_5_1__store
lsig_2_5_1__discount s w store = filter (\at => ltim_2_8_2__in_window s at w) store

--@spec [LSIG.2.5.1]
||| EVICTION, at the sample of a new assertion: the store keeps what is in
||| the window at that sample. The same filter as the discount, applied to
||| the store itself and kept; the clause's claim is exactly that applying
||| it early changes nothing a later discount sees.
public export
lsig_2_5_1__evict : Ltim_2_8_1__sample -> (w : Nat) -> Lsig_2_5_1__store -> Lsig_2_5_1__store
lsig_2_5_1__evict s w store = filter (\at => ltim_2_8_2__in_window s at w) store

-- ---------------------------------------------------------------------
-- Out stays out, on a clock that does not go back
-- ---------------------------------------------------------------------

--@derives [LSIG.2.5.1]
--@derives [LTIM.2.8.2]
||| OUT STAYS OUT: a value out of the window at monotonic sample `m` is out
||| at every later sample `m'`, whatever the wall clock reads at either.
||| The `in_window` instance of `ltim_2_7_1__within_falls`: membership is
||| `within`'s formula, and `within` falls once.
export
lsig_2_5_1__out_stays_out : (at, w, m, m', wm, wm' : Nat) -> LTE m m' ->
                            ltim_2_8_2__in_window (m, wm) at w = False ->
                            ltim_2_8_2__in_window (m', wm') at w = False
lsig_2_5_1__out_stays_out at w m m' wm wm' le h = ltim_2_7_1__within_falls at w m m' wm wm' le h

--@derives [LSIG.2.5.1]
||| A Boolean is not both `True` and `False`.
export
lsig_2_5_1__not_both : (b : Bool) -> b = True -> b = False -> Void
lsig_2_5_1__not_both _ Refl Refl impossible

-- ---------------------------------------------------------------------
-- Eviction at an assertion, the discount at a query: one answer
-- ---------------------------------------------------------------------

--@derives [LSIG.2.5.1]
--@derives [LTIM.2.8.2]
||| EVICTION IS DRIVEN BY ASSERTIONS, NOT BY QUERY TIME, AND THE QUERY'S
||| ANSWER IS THE SAME: for every store, every window, every monotonic
||| sample `m` of an eviction and every later sample `m'` of a query, and
||| whatever the wall clock read at either, the discount at `m'` of the
||| store evicted at `m` is the discount at `m'` of the store. By induction
||| on the store: a member evicted at `m` is out at `m'` too
||| (`lsig_2_5_1__out_stays_out`), so the discount would have dropped it;
||| a member kept at `m` is judged at `m'` on both sides alike.
export
lsig_2_5_1__discount_after_eviction : (w, m, m', wm, wm' : Nat) -> LTE m m' -> (store : Lsig_2_5_1__store) ->
                                      lsig_2_5_1__discount (m', wm') w (lsig_2_5_1__evict (m, wm) w store)
                                        = lsig_2_5_1__discount (m', wm') w store
lsig_2_5_1__discount_after_eviction w m m' wm wm' le [] = Refl
lsig_2_5_1__discount_after_eviction w m m' wm wm' le (at :: rest) with (ltim_2_8_2__in_window (m, wm) at w) proof early
  lsig_2_5_1__discount_after_eviction w m m' wm wm' le (at :: rest) | True with (ltim_2_8_2__in_window (m', wm') at w)
    lsig_2_5_1__discount_after_eviction w m m' wm wm' le (at :: rest) | True | True =
      cong (at ::) (lsig_2_5_1__discount_after_eviction w m m' wm wm' le rest)
    lsig_2_5_1__discount_after_eviction w m m' wm wm' le (at :: rest) | True | False =
      lsig_2_5_1__discount_after_eviction w m m' wm wm' le rest
  lsig_2_5_1__discount_after_eviction w m m' wm wm' le (at :: rest) | False with (ltim_2_8_2__in_window (m', wm') at w) proof late
    lsig_2_5_1__discount_after_eviction w m m' wm wm' le (at :: rest) | False | True =
      void (lsig_2_5_1__not_both (ltim_2_8_2__in_window (m', wm') at w) late
              (lsig_2_5_1__out_stays_out at w m m' wm wm' le early))
    lsig_2_5_1__discount_after_eviction w m m' wm wm' le (at :: rest) | False | False =
      lsig_2_5_1__discount_after_eviction w m m' wm wm' le rest

--@derives [LSIG.2.5.1]
||| EXECUTED: values absorbed at 1, 2 and 3, a window of 2. An eviction at
||| sample 3 (wall 50) drops the value of 1 and keeps 2 and 3; a query at
||| sample 4 (wall 0) sees the value of 3 alone, whether the store was
||| evicted or not.
export
lsig_2_5_1__eviction_not_at_query_time :
  ( lsig_2_5_1__evict (3, 50) 2 [1, 2, 3] = [2, 3]
  , lsig_2_5_1__discount (4, 0) 2 (lsig_2_5_1__evict (3, 50) 2 [1, 2, 3]) = [3]
  , lsig_2_5_1__discount (4, 0) 2 [1, 2, 3] = [3] )
lsig_2_5_1__eviction_not_at_query_time = (Refl, Refl, Refl)

--@derives [LSIG.2.5.1]
||| AND THE HYPOTHESIS IS NEEDED: an eviction at a sample AFTER the query's
||| -- at 4, the query at 3 -- drops the value of 2, which the query at 3
||| would have seen. The theorem asks `m <= m'` because [LTIM.2.8.2]'s clock
||| does not go back between an assertion and a later query; a store
||| evicted in the query's future is not the clause's case.
export
lsig_2_5_1__query_before_eviction_differs :
  Not (lsig_2_5_1__discount (3, 0) 2 (lsig_2_5_1__evict (4, 0) 2 [1, 2, 3])
         = lsig_2_5_1__discount (3, 0) 2 [1, 2, 3])
lsig_2_5_1__query_before_eviction_differs Refl impossible

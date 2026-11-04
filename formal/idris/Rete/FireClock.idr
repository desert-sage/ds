-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| A NOW node reads the held wall-clock sample ([IRET.25.4.1], [IRET.14.1]):
||| nothing is cached, no clock function is called, and every encounter in a
||| pump returns one value -- which is how [LTIM.2.1.3]'s activation
||| atomicity is delivered.
|||
||| THE CLAUSES. [IRET.25.4.1]: `DS_RETE_EXPR_NOW` nodes read the held
||| wall-clock sample; the sample does not change between two sample points
||| ([LTIM.2.8.4]), so nothing is cached and every encounter in a pump returns
||| one value. [IRET.14.1]: a NOW node reads the engine's held wall-clock
||| sample directly and calls no clock function, which runs only at a sample
||| point. [LTIM.2.1.3]: two calls to `now()` within one rule activation
||| return the same value; the engine samples only between steps, never
||| within an activation.
|||
||| WHAT THIS FILE WAS. [IRET.25.4.1] once read "evaluated once per rule fire
||| and cached. On first encounter of a NOW node the evaluator calls
||| `engine->clock.fn`": a per-fire cache with a clock read at its first
||| encounter, and an in-range `-1` sentinel for the not-yet-read state that
||| the clause forbids. This module models that cache and proves it
||| reads the clock once per fire. The clause's mechanism is different: the clock
||| function runs at a sample point and
||| nowhere else, and a NOW node is a field read. The per-fire cache is kept
||| below as THE REFUSED READING, so that what the clause rules out is
||| computed beside what it requires; the sentinel went with the cache it
||| spelled.
|||
||| WHAT IS PROVED, each for every input. A NOW node is a field read of the
||| held sample (`iret_25_4_1__now_node`). The encounters of one firing all
||| see the held wall value and the clock source is not called
||| (`iret_25_4_1__fire_reads_held`); so do the encounters of every firing of
||| a pump, however many firings and however many encounters each
||| (`iret_25_4_1__one_value_per_pump`): the clause's "every encounter in a
||| pump returns one value", with the call count unchanged, which is
||| [IRET.14.1]'s "neither calls the clock function". And any expression
||| over `now()` and `monotonic_ns()` reads, evaluated anywhere within an
||| activation in either order, is worth what the sample makes it
||| (`ltim_2_1_3__activation_atomic`: TwoClocks.idr's `ltim_2_8_4__held_value`
||| applied, because [LTIM.2.1.3]'s sentence is [LTIM.2.8.4]'s for the
||| activation's reads).
|||
||| WHAT IS REFUTED. Under the refused reading two firings in one pump read
||| two values from a source that moves, where the held sample gives both
||| the one value, and the source is called once per firing
||| (`iret_25_4_1__per_fire_reads_twice`).
|||
||| THE CLOCK SOURCE IS A FUNCTION OF THE CALL COUNT, TwoClocks.idr's device:
||| a second call is visible in a result, so "calls nothing" is a claim the
||| count can falsify. The reads here are served by TwoClocks.idr's held
||| reader, so the clause's "held sample" is the same object the two-clock
||| modules reason about.
module Rete.FireClock

import Data.List
import TwoClocks

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- A NOW node reads the held sample
-- ---------------------------------------------------------------------

--@spec [IRET.25.4.1]
--@spec [IRET.14.1]
||| A NOW node: a field read of the held sample's wall component. No clock
||| function, no cache.
public export
iret_25_4_1__now_node : Ltim_2_8_1__sample -> Nat
iret_25_4_1__now_node s = snd s

--@spec [IRET.25.4.1]
||| What `k` encounters of NOW nodes in one firing see under the held sample:
||| each is `Now` evaluated by TwoClocks.idr's held reader, the count of
||| source calls threaded through as that module threads it. The values, and
||| the count afterwards.
public export
iret_25_4_1__fire_reads : Ltim_2_8_1__sample -> Nat -> Nat -> (List Nat, Nat)
iret_25_4_1__fire_reads s Z n = ([], n)
iret_25_4_1__fire_reads s (S k) n =
  ( fst (ltim_2_8_4__eval Now (ltim_2_8_4__held s) True n)
      :: fst (iret_25_4_1__fire_reads s k (snd (ltim_2_8_4__eval Now (ltim_2_8_4__held s) True n)))
  , snd (iret_25_4_1__fire_reads s k (snd (ltim_2_8_4__eval Now (ltim_2_8_4__held s) True n))) )

--@spec [IRET.25.4.1]
||| A pump: its firings, each with its count of NOW encounters, all under the
||| pump's one held sample ([LTIM.2.8.4]: a pump begins with a sample and
||| takes no other). What every firing's encounters see, and the count after.
public export
iret_25_4_1__pump_reads : Ltim_2_8_1__sample -> List Nat -> Nat -> (List (List Nat), Nat)
iret_25_4_1__pump_reads s [] n = ([], n)
iret_25_4_1__pump_reads s (k :: ks) n =
  ( fst (iret_25_4_1__fire_reads s k n)
      :: fst (iret_25_4_1__pump_reads s ks (snd (iret_25_4_1__fire_reads s k n)))
  , snd (iret_25_4_1__pump_reads s ks (snd (iret_25_4_1__fire_reads s k n))) )

--@derives [IRET.25.4.1]
--@derives [IRET.14.1]
||| ONE FIRING SEES ONE VALUE AND CALLS NOTHING: `k` encounters see `k` copies
||| of the held wall value, and the count of source calls is what it was. For
||| every sample, every count of encounters and every call count.
export
iret_25_4_1__fire_reads_held : (s : Ltim_2_8_1__sample) -> (k, n : Nat) ->
                               iret_25_4_1__fire_reads s k n = (replicate k (snd s), n)
iret_25_4_1__fire_reads_held s Z n = Refl
iret_25_4_1__fire_reads_held s (S k) n =
  cong (\p => (snd s :: fst p, snd p)) (iret_25_4_1__fire_reads_held s k n)

--@derives [IRET.25.4.1]
||| One firing of a pump, unfolded: the pump's first firing's reads, then the
||| rest of the pump from the count the first firing left. By computation.
export
iret_25_4_1__pump_reads_cons : (s : Ltim_2_8_1__sample) -> (k : Nat) -> (ks : List Nat) -> (n : Nat) ->
                               iret_25_4_1__pump_reads s (k :: ks) n
                                 = ( fst (iret_25_4_1__fire_reads s k n)
                                       :: fst (iret_25_4_1__pump_reads s ks (snd (iret_25_4_1__fire_reads s k n)))
                                   , snd (iret_25_4_1__pump_reads s ks (snd (iret_25_4_1__fire_reads s k n))) )
iret_25_4_1__pump_reads_cons s k ks n = Refl

--@derives [IRET.25.4.1]
--@derives [IRET.14.1]
--@derives [LTIM.2.1.3]
||| EVERY ENCOUNTER IN A PUMP RETURNS ONE VALUE: for every sample, every list
||| of firings with any counts of encounters, and every call count, each
||| firing sees copies of the held wall value and the source is called not
||| once. "Nothing is cached": there is nothing to cache, the value being the
||| sample's.
export
iret_25_4_1__one_value_per_pump : (s : Ltim_2_8_1__sample) -> (fires : List Nat) -> (n : Nat) ->
                                  iret_25_4_1__pump_reads s fires n = (map (\k => replicate k (snd s)) fires, n)
iret_25_4_1__one_value_per_pump s [] n = Refl
iret_25_4_1__one_value_per_pump s (k :: ks) n =
  trans (replace {p = \q => iret_25_4_1__pump_reads s (k :: ks) n
                              = (fst q :: fst (iret_25_4_1__pump_reads s ks (snd q)), snd (iret_25_4_1__pump_reads s ks (snd q)))}
                 (iret_25_4_1__fire_reads_held s k n)
                 (iret_25_4_1__pump_reads_cons s k ks n))
        (cong (\p => (replicate k (snd s) :: fst p, snd p)) (iret_25_4_1__one_value_per_pump s ks n))

--@derives [LTIM.2.1.3]
--@derives [LTIM.2.8.4]
||| ACTIVATIONS ARE ATOMIC WITH RESPECT TO THE CLOCK: any expression over
||| `now()` and `monotonic_ns()` reads, evaluated anywhere within an
||| activation -- in either order, from any count of calls made before -- is
||| worth what the held sample makes it. Two calls to `now()` within one
||| activation therefore return the same value, as the clause requires;
||| TwoClocks.idr's `ltim_2_8_4__held_value`, applied, because the activation
||| samples nothing of its own.
export
ltim_2_1_3__activation_atomic : (s : Ltim_2_8_1__sample) -> (e : Ltim_2_8_4__expr) -> (ord : Bool) -> (n : Nat) ->
                                fst (ltim_2_8_4__eval e (ltim_2_8_4__held s) ord n) = ltim_2_8_4__worth s e
ltim_2_1_3__activation_atomic s e ord n = ltim_2_8_4__held_value s e ord n

-- ---------------------------------------------------------------------
-- THE REFUSED READING: a per-fire cache, with a clock read at its first
-- encounter
-- ---------------------------------------------------------------------

--@spec [IRET.25.4.1]
||| What `k` encounters see in one firing under the refused reading: the
||| first calls the clock source and freezes the wall value for the firing,
||| the rest return it. `r` is the count of source calls so far; the frozen
||| value is `Nothing` while no read has been made in this firing.
public export
iret_25_4_1__per_fire_reads : Ltim_2_8_1__source -> Nat -> Nat -> Maybe Nat -> (List Nat, Nat)
iret_25_4_1__per_fire_reads src Z r _ = ([], r)
iret_25_4_1__per_fire_reads src (S k) r (Just v) =
  ( v :: fst (iret_25_4_1__per_fire_reads src k r (Just v))
  , snd (iret_25_4_1__per_fire_reads src k r (Just v)) )
iret_25_4_1__per_fire_reads src (S k) r Nothing =
  ( snd (src r) :: fst (iret_25_4_1__per_fire_reads src k (S r) (Just (snd (src r))))
  , snd (iret_25_4_1__per_fire_reads src k (S r) (Just (snd (src r)))) )

--@spec [IRET.25.4.1]
||| A pump under the refused reading: every firing starts cold and reads the
||| source at its first encounter.
public export
iret_25_4_1__per_fire_pump : Ltim_2_8_1__source -> List Nat -> Nat -> (List (List Nat), Nat)
iret_25_4_1__per_fire_pump src [] r = ([], r)
iret_25_4_1__per_fire_pump src (k :: ks) r =
  ( fst (iret_25_4_1__per_fire_reads src k r Nothing)
      :: fst (iret_25_4_1__per_fire_pump src ks (snd (iret_25_4_1__per_fire_reads src k r Nothing)))
  , snd (iret_25_4_1__per_fire_pump src ks (snd (iret_25_4_1__per_fire_reads src k r Nothing))) )

--@derives [IRET.25.4.1]
--@derives [LTIM.2.8.4]
||| TWO FIRINGS IN ONE PUMP READ TWO VALUES UNDER THE REFUSED READING, from a
||| source that moves at every call: the first firing reads 0, the second 1,
||| and the source is called twice. Under the held sample both read the
||| sample's value and the source is called not once. Computed.
export
iret_25_4_1__per_fire_reads_twice :
  ( iret_25_4_1__per_fire_pump ltim_2_8_1__ticking [1, 1] 0 = ([[0], [1]], 2)
  , iret_25_4_1__pump_reads (ltim_2_8_1__ticking 0) [1, 1] 0 = ([[0], [0]], 0) )
iret_25_4_1__per_fire_reads_twice = (Refl, Refl)

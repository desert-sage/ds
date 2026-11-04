-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE DENSE-ORDER READING, REFUTED BY EXECUTION. [IRET.28.10.1] pins
||| alpha-memory iteration to the dense-vector order -- append on insert,
||| last-into-hole on delete -- and [IRET.28.0.1] and [IRET.28.10] say that
||| order "feeds timetag assignment", so rule-firing order. [IRET.7.7]
||| left-activates a join by iterating the right alpha memory. Read
||| together: the matches one assertion completes are stamped in the
||| memory's dense order. This module executes that reading on the
||| a three-fact history and shows
||| that it violates [LDET.5.9]: a run and its replay by assertion agree on working memory
||| and on the match set and disagree on the order -- so also [LDET.6.1.2]
||| (no dependence on iteration order) and [LCON.2.4.1] (reversing
||| internal iteration must not change output). Under the canonical key
||| of [LDET.5.5] the two histories agree, in this module by computation
||| and in Rete/NetworkOrderKeep.idr for every history.
module Rete.NetworkDenseWitness

import Rete.FireLoop
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkOrderKeep
import Data.List

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The reading: dense memories, counter-stamped activations
-- ---------------------------------------------------------------------

--@spec [IRET.28.10.1]
||| The last entry moved into the hole at the head: what a last-into-hole
||| delete leaves when the head is removed.
public export
iret_28_10_1__last_into : List Lfac_1_7_1__fact -> List Lfac_1_7_1__fact
iret_28_10_1__last_into [] = []
iret_28_10_1__last_into [x] = [x]
iret_28_10_1__last_into (x :: y :: ys) = case iret_28_10_1__last_into (y :: ys) of
  []          => [x]
  (l :: rest) => l :: x :: rest

--@spec [IRET.28.10.1]
||| Dense-vector deletion: the removed entry's position takes the last
||| entry; every other entry keeps its place.
public export
iret_28_10_1__swap_remove : Lfac_1_7_1__fact -> List Lfac_1_7_1__fact -> List Lfac_1_7_1__fact
iret_28_10_1__swap_remove f [] = []
iret_28_10_1__swap_remove f (x :: xs) = if x == f then iret_28_10_1__last_into xs else x :: iret_28_10_1__swap_remove f xs

--@spec [IRET.28.0.1]
--@spec [IRET.7.7]
||| The engine under the reading, for one rule `A a, B b`: working
||| memory, the two alpha memories in dense order, and the rule's
||| activations in the order they were stamped.
public export
record Iret_28_0_1__engine where
  constructor MkDense
  dwm     : List Lfac_1_7_1__fact
  dmemA   : List Lfac_1_7_1__fact
  dmemB   : List Lfac_1_7_1__fact
  dagenda : List Iret_7_1__token

--@spec [IRET.28.0.1]
--@spec [IRET.7.7]
||| An assertion under the reading. An `A` fact left-activates the join,
||| which iterates the `B` memory in its dense order and stamps each match
||| as it is made; a `B` fact right-activates it, iterating the left
||| memory in the order it was appended.
public export
iret_28_0_1__assert : Lfac_1_7_1__fact -> Iret_28_0_1__engine -> Iret_28_0_1__engine
iret_28_0_1__assert f e =
  if fkind f == 0
    then MkDense (dwm e ++ [f]) (dmemA e ++ [f]) (dmemB e) (dagenda e ++ map (\b => [f, b]) (dmemB e))
    else MkDense (dwm e ++ [f]) (dmemA e) (dmemB e ++ [f]) (dagenda e ++ map (\a => [a, f]) (dmemA e))

--@spec [IRET.28.0.1]
--@spec [IRET.28.10.1]
||| A retraction under the reading: the fact leaves working memory, the
||| memories by last-into-hole, and every activation built on it ends.
public export
iret_28_0_1__retract : Lfac_1_7_1__fact -> Iret_28_0_1__engine -> Iret_28_0_1__engine
iret_28_0_1__retract f e =
  MkDense (rarc_5_6_4__remove_exact f (dwm e)) (iret_28_10_1__swap_remove f (dmemA e)) (iret_28_10_1__swap_remove f (dmemB e))
          (filter (\t => not (rarc_5_6_5__elem f t)) (dagenda e))

--@spec [IRET.28.0.1]
public export
iret_28_0_1__empty : Iret_28_0_1__engine
iret_28_0_1__empty = MkDense [] [] [] []

-- ---------------------------------------------------------------------
-- The history
-- ---------------------------------------------------------------------

--@spec [LDET.5.9]
||| The facts: `A` is kind 0, `B` is kind 1; ids as [IRET.4.4] assigns
||| them, never reused, and carried by the recording into the replay.
public export
ldet_5_9__b1 : Lfac_1_7_1__fact
ldet_5_9__b1 = MkFact 1 1 1 0

--@spec [LDET.5.9]
public export
ldet_5_9__b2 : Lfac_1_7_1__fact
ldet_5_9__b2 = MkFact 2 1 2 0

--@spec [LDET.5.9]
public export
ldet_5_9__b3 : Lfac_1_7_1__fact
ldet_5_9__b3 = MkFact 3 1 3 0

--@spec [LDET.5.9]
public export
ldet_5_9__a1 : Lfac_1_7_1__fact
ldet_5_9__a1 = MkFact 4 0 4 0

--@spec [LDET.5.9]
||| THE RUN: assert b1, b2, b3; retract b1; assert a1.
public export
ldet_5_9__run : Iret_28_0_1__engine
ldet_5_9__run =
  iret_28_0_1__assert ldet_5_9__a1
    (iret_28_0_1__retract ldet_5_9__b1
      (iret_28_0_1__assert ldet_5_9__b3
        (iret_28_0_1__assert ldet_5_9__b2
          (iret_28_0_1__assert ldet_5_9__b1 iret_28_0_1__empty))))

--@spec [LDET.5.9]
--@spec [LFST.9.2.1]
||| THE REPLAY BY ASSERTION: the recording carries facts, not the
||| network's history, so working memory is rebuilt as b2, b3, a1.
public export
ldet_5_9__replay : Iret_28_0_1__engine
ldet_5_9__replay =
  iret_28_0_1__assert ldet_5_9__a1
    (iret_28_0_1__assert ldet_5_9__b3
      (iret_28_0_1__assert ldet_5_9__b2 iret_28_0_1__empty))

-- ---------------------------------------------------------------------
-- The refutation
-- ---------------------------------------------------------------------

--@derives [LDET.5.9]
||| The run and its replay agree on working memory.
export
ldet_5_9__same_wm : dwm ldet_5_9__run = dwm ldet_5_9__replay
ldet_5_9__same_wm = Refl

--@derives [LDET.5.9]
--@derives [IRET.28.10.1]
||| Under the reading the run stamps (a1, b3) before (a1, b2): after the
||| delete the `B` memory is [b3, b2].
export
ldet_5_9__run_order : dagenda ldet_5_9__run = [[ldet_5_9__a1, ldet_5_9__b3], [ldet_5_9__a1, ldet_5_9__b2]]
ldet_5_9__run_order = Refl

--@derives [LDET.5.9]
--@derives [IRET.28.10.1]
||| The replay stamps (a1, b2) before (a1, b3): its `B` memory is [b2, b3].
export
ldet_5_9__replay_order : dagenda ldet_5_9__replay = [[ldet_5_9__a1, ldet_5_9__b2], [ldet_5_9__a1, ldet_5_9__b3]]
ldet_5_9__replay_order = Refl

--@derives [LDET.5.9]
||| The two agree on the match set.
export
ldet_5_9__same_matches : (rarc_5_6_5__elem [ldet_5_9__a1, ldet_5_9__b2] (dagenda ldet_5_9__run) && rarc_5_6_5__elem [ldet_5_9__a1, ldet_5_9__b3] (dagenda ldet_5_9__run)) = True
ldet_5_9__same_matches = Refl

--@derives [LDET.5.9]
export
ldet_5_9__orders_differ : (dagenda ldet_5_9__run == dagenda ldet_5_9__replay) = False
ldet_5_9__orders_differ = Refl

--@derives [LDET.5.9]
--@derives [IRET.28.0.1]
--@derives [IRET.28.10]
--@derives [LDET.6.1.2]
--@derives [LCON.2.4.1]
||| THE READING VIOLATES [LDET.5.9]: same working memory, same match set,
||| a different order -- the order depended on how the set was reached.
||| The counterexample to "iteration order feeds timetag assignment".
export
ldet_5_9__dense_refuted : Not (dagenda ldet_5_9__run = dagenda ldet_5_9__replay)
ldet_5_9__dense_refuted eq =
  absurd (trans (sym (replace {p = \z => (dagenda ldet_5_9__run == z) = True} eq ldet_5_9__run_eq_self)) ldet_5_9__orders_differ)
  where
    ldet_5_9__run_eq_self : (dagenda ldet_5_9__run == dagenda ldet_5_9__run) = True
    ldet_5_9__run_eq_self = Refl

--@derives [LDET.5.5]
--@derives [LDET.5.9]
||| UNDER THE CANONICAL KEY the two histories agree: the key sorts each
||| match set over the working memory both share, and both give
||| (a1, b2) then (a1, b3).
export
ldet_5_5__canonical_agrees : ldet_5_5__canonical (dwm ldet_5_9__run) (dagenda ldet_5_9__run) = ldet_5_5__canonical (dwm ldet_5_9__replay) (dagenda ldet_5_9__replay)
ldet_5_5__canonical_agrees = Refl

--@derives [LDET.5.5]
export
ldet_5_5__canonical_order : ldet_5_5__canonical (dwm ldet_5_9__run) (dagenda ldet_5_9__run) = [[ldet_5_9__a1, ldet_5_9__b2], [ldet_5_9__a1, ldet_5_9__b3]]
ldet_5_5__canonical_order = Refl

-- ---------------------------------------------------------------------
-- The same two histories through the network of Rete/Network.idr
-- ---------------------------------------------------------------------

--@derives [LDET.5.9]
--@derives [RDSC.4a.5]
||| The rule `A a, B b` as loaded: alpha 0 admits kind 0, alpha 1 admits
||| kind 1, no join tests, no RHS.
public export
ldet_5_9__net : Iret_19__engine
ldet_5_9__net = rdsc_4a_5__load [(0, \f => True), (1, \f => True)] [([(0, \t, f => True, False), (1, \t, f => True, False)], [])]

--@derives [LDET.5.9]
||| The run's inputs under the model, ids minted by the engine: the
||| three `B` facts keyed 1, 2, 3, the retraction of the first, then `A`.
public export
ldet_5_9__run_events : List Rarc_5_6_1__event
ldet_5_9__run_events = [Assert 1 1 0, Assert 1 2 0, Assert 1 3 0, Retract 0, Assert 0 4 0]

--@derives [LDET.5.9]
public export
ldet_5_9__replay_events : List Rarc_5_6_1__event
ldet_5_9__replay_events = [Assert 1 2 0, Assert 1 3 0, Assert 0 4 0]

--@derives [LDET.5.9]
||| The keys of each activation's facts, per rule.
public export
ldet_5_9__keys_of : Iret_19__engine -> List (List (List Nat))
ldet_5_9__keys_of eng = map (\c => map (map fkey) (iret_8_1__tuples (cacts c))) (nchains (enet eng))

--@derives [LDET.5.9]
--@derives [LDET.5.5]
--@derives [IRET.11.3.3]
||| THROUGH THE MODEL the run and the replay agree: (a1, b2) then
||| (a1, b3) in both, whatever the engine's ids.
export
ldet_5_9__network_agrees : ldet_5_9__keys_of (lfst_9_2_1__replay_net (\k => Explicit) 0 ldet_5_9__run_events ldet_5_9__net)
                           = ldet_5_9__keys_of (lfst_9_2_1__replay_net (\k => Explicit) 0 ldet_5_9__replay_events ldet_5_9__net)
ldet_5_9__network_agrees = Refl

--@derives [LDET.5.9]
export
ldet_5_9__network_order : ldet_5_9__keys_of (lfst_9_2_1__replay_net (\k => Explicit) 0 ldet_5_9__run_events ldet_5_9__net) = [[[4, 2], [4, 3]]]
ldet_5_9__network_order = Refl

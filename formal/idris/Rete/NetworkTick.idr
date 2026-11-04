-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| REFRACTION UNDER TICKS: time-dependent tests on the network, and
||| edge-once as refraction with [LDET.5.8].
|||
||| NORMATIVE COMPANION to Rete/Network.idr and Rete/NetworkRefraction.idr.
|||
||| A `where` that reads `now()` is time-dependent ([LTIM.2.4.1]); in v1 it
||| sits on a rule with a single positive pattern ([LTIM.2.6.1], [LTIM.2.6.2]),
||| so its node is the chain's one positive node, whose join test is a
||| function of the clock (`Ltim_2_4_1__timed`). Every tick re-evaluates it
||| ([LTIM.2.4.2], [IRET.19.5]): `iret_19_5__retime` gives the node the test at
||| the new clock, ENDS the matches the tick makes false, CREATES the ones it
||| makes true as unfired activations, and touches nothing else — the tick is
||| not a change to the LHS ([LDET.5.8]), and refraction is the `fired` flag
||| ([IRET.11.3], [IRET.11.3.2]).
|||
||| PROVED. The tick keeps the view: the terminal holds exactly the matches
||| at the new clock (`iret_19_5__retime_consistent`). An activation whose
||| match holds across the tick is the same record after it, `fired` flag
||| included (`ldet_5_8__tick_keeps_activation`) — Rete/NetworkRefraction.idr's
||| theorem restated under ticks. After a quiescent pump the only unfired
||| activations a tick leaves are the matches it made true, and each of
||| those is there to fire (`ltim_2_4_2__unfired_are_born`,
||| `ltim_2_4_2__born_unfired`). And for a gate that stays true once true —
||| `now() > t`, the shape of every example in the clauses — a match is made
||| true by at most one tick, so it fires at most once
||| (`ltim_2_5_1__edge_once`). [LDET.5.8]'s own example runs on the network
||| and fires exactly once, in the third pump (`ldet_5_8__late_fires_once`);
||| a gate already true at assert fires on that pump (`ltim_2_5_3__true_at_assert`).
|||
||| A CONDITION THAT CLOSES ENDS THE MATCH, AND A REOPENING IS A NEW EDGE
||| ([LTIM.2.5.1]).
||| Under the view, a tick leaves no activation whose
||| match the new test refuses, fired or not (`ltim_2_5_1__closing_ends`);
||| and an activation of a match the tick made is unfired, whatever was fired
||| before the gate shut (`ltim_2_5_1__reopening_is_unfired`): "no memory of
||| the firing outlives the activation". With the theorems above that is the
||| clause for ANY gate, tick by tick: a match that stays true is the same
||| record, flag included; one that goes false has no activation; one that
||| goes true has a new one, unfired; and after a quiescent pump nothing
||| else is unfired. A gate that stays true once true fires once per
||| wrapper; a window that shuts and reopens fires once per opening, which
||| the executed `ltim_2_5_1__second_edge_refires` shows: `[1, 0, 1, 0]`.
||| [LTIM.2.5.2]'s re-arming on a new wrapper is beside this, not instead of
||| it. Which gates can shut and reopen is `Rete/EntryStamp.idr`'s: one on
||| elapsed monotonic time changes at most once for one entry, so only a
||| gate that reads the wall clock reopens ([LTIM.2.8.3]).
module Rete.NetworkTick

import Rete.FireLoop
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.Refcount
import Rete.TmsBridge
import Lcyc.Lemmas
import Data.List
import Data.List.Elem
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- Time-dependent tests, and the tick
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.1]
||| A time-dependent join test: the test at each clock reading.
public export
Ltim_2_4_1__timed : Type
Ltim_2_4_1__timed = Nat -> Iret_7_5__join

--@spec [LTIM.2.4.2]
--@spec [IRET.19.5]
||| The matches a tick ends: the old test admitted them, the new one does not.
public export
iret_19_5__ended : Iret_7_5__join -> Iret_7_5__join -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> List Iret_7_1__token
iret_19_5__ended j j' mem lm = iret_7_7__extend_front (\t, f => j t f && not (j' t f)) mem lm

--@spec [LTIM.2.4.2]
--@spec [IRET.19.5]
||| The matches a tick makes: the old test refused them, the new one admits.
public export
iret_19_5__born : Iret_7_5__join -> Iret_7_5__join -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> List Iret_7_1__token
iret_19_5__born j j' mem lm = iret_7_7__extend_front (\t, f => not (j t f) && j' t f) mem lm

--@spec [LTIM.2.4.2]
--@spec [IRET.19.5]
--@spec [LDET.5.8]
||| RE-EVALUATION AT A TICK of a node whose test reads the clock: the node
||| takes the test at the new clock; the matches the tick ends leave the
||| terminal, the matches it makes become unfired activations; every other
||| activation is left as it is.
public export
iret_19_5__retime : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> Iret_7_5__join -> Iret_7_4__beta -> List Iret_8_1__act -> (Iret_7_4__beta, List Iret_8_1__act)
iret_19_5__retime wm alphas j' b acts =
  ( MkBeta (balpha b) j' (bneg b) (blmem b) (bcounts b)
  , iret_8_1__activate wm (iret_19_5__born (bjoin b) j' (iret_6_6__mem_at alphas (balpha b)) (blmem b))
      (iret_8_1__end (iret_19_5__ended (bjoin b) j' (iret_6_6__mem_at alphas (balpha b)) (blmem b)) acts) )

--@spec [LTIM.2.6.1]
--@spec [IRET.19.5]
||| One chain at a tick: a rule whose single positive pattern carries a
||| time-dependent test is re-timed; any other chain is untouched.
public export
iret_19_5__tick_chain : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> Maybe Ltim_2_4_1__timed -> Nat -> Rlow_4_2_1__chain -> Rlow_4_2_1__chain
iret_19_5__tick_chain wm alphas (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions) =
  let r = iret_19_5__retime wm alphas (tj c) (MkBeta a j False lm cs) acts
  in MkChain [fst r] (snd r) actions
iret_19_5__tick_chain wm alphas _ c ch = ch

--@spec [IRET.19.5]
||| Every chain at a tick, each with its time-dependent test if it has one.
public export
iret_19_5__tick_chains : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> List (Maybe Ltim_2_4_1__timed) -> Nat -> List Rlow_4_2_1__chain -> List Rlow_4_2_1__chain
iret_19_5__tick_chains wm alphas [] c chains = chains
iret_19_5__tick_chains wm alphas (t :: ts) c [] = []
iret_19_5__tick_chains wm alphas (t :: ts) c (ch :: chs) = iret_19_5__tick_chain wm alphas t c ch :: iret_19_5__tick_chains wm alphas ts c chs

--@spec [IRET.19.5]
--@spec [LDET.5.8]
||| THE TICK: working memory untouched ([LDET.5.8]: the tick is not a
||| working-memory fact), every time-dependent test re-evaluated at the new
||| clock.
public export
iret_19_5__tick : List (Maybe Ltim_2_4_1__timed) -> Nat -> Iret_19__engine -> Iret_19__engine
iret_19_5__tick ts c eng =
  MkEngine (ewm eng) (MkNetwork (nalphas (enet eng)) (iret_19_5__tick_chains (ewm eng) (nalphas (enet eng)) ts c (nchains (enet eng))))

--@spec [IRET.19.5]
--@spec [LTIM.2.4.2]
||| A PUMP: the tick, then the run to quiescence ([IRET.19.5] steps 3 and
||| 4); with the number of firings.
public export
iret_19_5__pump : (Nat -> Lscp_1_3__lifecycle) -> List (Maybe Ltim_2_4_1__timed) -> Nat -> Nat -> Iret_19__engine -> (Iret_19__engine, Nat)
iret_19_5__pump life ts fuel c eng =
  let r = iret_11_4__run_net life fuel (iret_19_5__tick ts c eng) in (fst r, snd (snd r))

--@spec [IRET.19.5]
||| The firings of a sequence of pumps, one count per pump.
public export
iret_19_5__counts : (Nat -> Lscp_1_3__lifecycle) -> List (Maybe Ltim_2_4_1__timed) -> Nat -> List Nat -> Iret_19__engine -> List Nat
iret_19_5__counts life ts fuel [] eng = []
iret_19_5__counts life ts fuel (c :: cs) eng =
  let r = iret_19_5__pump life ts fuel c eng in snd r :: iret_19_5__counts life ts fuel cs (fst r)

-- ---------------------------------------------------------------------
-- Activations, record by record
-- ---------------------------------------------------------------------

--@derives [IRET.8.1]
||| The inserted activation is there.
export
iret_8_1__insert_here : (wm : Rarc_5_6_4__wm) -> (a : Iret_8_1__act) -> (acts : List Iret_8_1__act) -> Elem a (ldet_5_5__insert wm a acts)
iret_8_1__insert_here wm a [] = Here
iret_8_1__insert_here wm a (x :: xs) with (ldet_5_5__before wm (atuple a) (atuple x))
  iret_8_1__insert_here wm a (x :: xs) | True = Here
  iret_8_1__insert_here wm a (x :: xs) | False = There (iret_8_1__insert_here wm a xs)

--@derives [IRET.8.1]
||| What inserting yields is the one inserted or an old one.
export
iret_8_1__insert_inv : (wm : Rarc_5_6_4__wm) -> (a : Iret_8_1__act) -> (acts : List Iret_8_1__act) -> (b : Iret_8_1__act) ->
                       Elem b (ldet_5_5__insert wm a acts) -> Either (b = a) (Elem b acts)
iret_8_1__insert_inv wm a [] _ Here = Left Refl
iret_8_1__insert_inv wm a [] b (There e) = absurd e
iret_8_1__insert_inv wm a (x :: xs) b e with (ldet_5_5__before wm (atuple a) (atuple x))
  iret_8_1__insert_inv wm a (x :: xs) _ Here | True = Left Refl
  iret_8_1__insert_inv wm a (x :: xs) b (There e) | True = Right e
  iret_8_1__insert_inv wm a (x :: xs) _ Here | False = Right Here
  iret_8_1__insert_inv wm a (x :: xs) b (There e) | False = case iret_8_1__insert_inv wm a xs b e of
    Left eq => Left eq
    Right r => Right (There r)

--@derives [IRET.8.1]
||| Activating new matches keeps every old activation, as it was.
export
iret_8_1__activate_keeps : (wm : Rarc_5_6_4__wm) -> (new : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> (b : Iret_8_1__act) ->
                           Elem b acts -> Elem b (iret_8_1__activate wm new acts)
iret_8_1__activate_keeps wm [] acts b e = e
iret_8_1__activate_keeps wm (t :: ts) acts b e =
  iret_8_1__activate_keeps wm ts (ldet_5_5__insert wm (MkAct t False) acts) b (iret_8_1__insert_keeps wm (MkAct t False) acts b e)

--@derives [IRET.8.1]
||| Every new match is there, unfired.
export
iret_8_1__activate_new : (wm : Rarc_5_6_4__wm) -> (new : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> (t : Iret_7_1__token) ->
                         Elem t new -> Elem (MkAct t False) (iret_8_1__activate wm new acts)
iret_8_1__activate_new wm (t :: ts) acts t Here =
  iret_8_1__activate_keeps wm ts (ldet_5_5__insert wm (MkAct t False) acts) (MkAct t False) (iret_8_1__insert_here wm (MkAct t False) acts)
iret_8_1__activate_new wm (u :: ts) acts t (There e) =
  iret_8_1__activate_new wm ts (ldet_5_5__insert wm (MkAct u False) acts) t e

--@derives [IRET.8.1]
||| What activating yields is an old activation, or a new match unfired.
export
iret_8_1__activate_inv : (wm : Rarc_5_6_4__wm) -> (new : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> (b : Iret_8_1__act) ->
                         Elem b (iret_8_1__activate wm new acts) -> Either (Elem b acts) (afired b = False, Elem (atuple b) new)
iret_8_1__activate_inv wm [] acts b e = Left e
iret_8_1__activate_inv wm (t :: ts) acts b e =
  case iret_8_1__activate_inv wm ts (ldet_5_5__insert wm (MkAct t False) acts) b e of
    Right (fb, en) => Right (fb, There en)
    Left e1 => case iret_8_1__insert_inv wm (MkAct t False) acts b e1 of
      Left eq => Right (rewrite eq in Refl, rewrite eq in Here)
      Right r => Left r

--@derives [IRET.8.1]
||| Ending matches keeps every activation not among them, as it was.
export
iret_8_1__end_keeps : (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> (b : Iret_8_1__act) ->
                      Elem b acts -> Not (Elem (atuple b) gone) -> Elem b (iret_8_1__end gone acts)
iret_8_1__end_keeps gone acts b e ng =
  lcyc_1_1__elem_filter_fwd (\a => not (rarc_5_6_5__elem (atuple a) gone)) acts e (iret_12__not_false _ (iret_11_3__not_elem_tok (atuple b) gone ng))

--@derives [IRET.8.1]
||| Ending matches adds nothing.
export
iret_8_1__end_sub : (gone : List Iret_7_1__token) -> (acts : List Iret_8_1__act) -> (b : Iret_8_1__act) ->
                    Elem b (iret_8_1__end gone acts) -> Elem b acts
iret_8_1__end_sub gone acts b e = fst (lcyc_1_1__elem_filter_inv (\a => not (rarc_5_6_5__elem (atuple a) gone)) acts e)

-- ---------------------------------------------------------------------
-- What a tick ends and makes
-- ---------------------------------------------------------------------

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| One pair cannot be admitted and refused by one test.
export
iret_19_5__clash : (j : Iret_7_5__join) -> (t, u : Iret_7_1__token) -> (f, g : Lfac_1_7_1__fact) ->
                   t ++ [f] = u ++ [g] -> j t f = True -> j u g = False -> Void
iret_19_5__clash j t u f g eq jt ju =
  let (tu, fg) = iret_7_2__snoc_inj t u f g eq
  in absurd (trans (sym (replace {p = \x => j x g = True} tu (replace {p = \y => j t y = True} fg jt))) ju)

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| A match the tick ended: the old test admitted it, the new one does not.
export
iret_19_5__ended_inv : (j, j' : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (lm : List Iret_7_1__token) -> (y : Iret_7_1__token) ->
                       Elem y (iret_19_5__ended j j' mem lm) ->
                       (t ** (f ** (Elem t lm, Elem f mem, j t f = True, j' t f = False, y = t ++ [f])))
iret_19_5__ended_inv j j' mem lm y e =
  let (t ** (f ** (et, ef, p, eq))) = iret_7_7__extend_elem_inv (\t, f => j t f && not (j' t f)) mem lm y e
  in (t ** (f ** (et, ef, lcyc_1_1__and_true_l _ _ p, lcyc_1_1__not_true_is_false _ (lcyc_1_1__and_true_r _ _ p), eq)))

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| A match the tick made: the old test refused it, the new one admits.
export
iret_19_5__born_inv : (j, j' : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (lm : List Iret_7_1__token) -> (y : Iret_7_1__token) ->
                      Elem y (iret_19_5__born j j' mem lm) ->
                      (t ** (f ** (Elem t lm, Elem f mem, j t f = False, j' t f = True, y = t ++ [f])))
iret_19_5__born_inv j j' mem lm y e =
  let (t ** (f ** (et, ef, p, eq))) = iret_7_7__extend_elem_inv (\t, f => not (j t f) && j' t f) mem lm y e
  in (t ** (f ** (et, ef, lcyc_1_1__not_true_is_false _ (lcyc_1_1__and_true_l _ _ p), lcyc_1_1__and_true_r _ _ p, eq)))

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
--@derives [LDET.5.8]
||| A match the new test admits is not one the tick ended.
export
iret_19_5__not_ended : (j, j' : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (lm : List Iret_7_1__token) ->
                       (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) -> j' t f = True ->
                       Not (Elem (t ++ [f]) (iret_19_5__ended j j' mem lm))
iret_19_5__not_ended j j' mem lm t f jt e =
  let (u ** (g ** (_, _, _, ju, eq))) = iret_19_5__ended_inv j j' mem lm (t ++ [f]) e
  in iret_19_5__clash j' t u f g eq jt ju

-- ---------------------------------------------------------------------
-- The tick keeps the view
-- ---------------------------------------------------------------------

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
--@derives [IRET.7.7]
||| THE TICK KEEPS THE VIEW: a single positive node consistent with its
||| front under the old test is consistent under the new one after the tick
||| — the terminal holds exactly the matches at the new clock, none twice.
||| The tick re-evaluates as [LTIM.2.4.2] requires: nothing is missed and
||| nothing stale survives.
export
iret_19_5__retime_consistent : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas ->
                               (front : List Iret_7_1__token) -> (a : Nat) -> (j, j' : Iret_7_5__join) ->
                               (lm : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) -> (acts : List Iret_8_1__act) ->
                               Iret_7_7__consistent alphas front [MkBeta a j False lm cs] acts ->
                               Iret_7_7__consistent alphas front [fst (iret_19_5__retime wm alphas j' (MkBeta a j False lm cs) acts)]
                                                                 (snd (iret_19_5__retime wm alphas j' (MkBeta a j False lm cs) acts))
iret_19_5__retime_consistent wm alphas dm front a j j' lm cs acts (sl, dl, cnt, (sa, da)) =
  ( sl, dl, \bt, _, _ => absurd bt
  , ( \y => ( \e => case lcyc_1_1__elem_append_inv (iret_8_1__tuples (iret_8_1__end (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts))
                                                   (fst (iret_8_1__activate_same_set wm (iret_19_5__born j j' (iret_6_6__mem_at alphas a) lm)
                                                           (iret_8_1__end (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts)
                                                           (iret_8_1__tuples (iret_8_1__end (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts))
                                                           (iret_7_4__same_set_refl _) y) e) of
                          Right r => let (t ** (f ** (et, ef, _, jt', eq))) = iret_19_5__born_inv j j' (iret_6_6__mem_at alphas a) lm y r
                                     in replace {p = \z => Elem z (iret_7_7__extend_front j' (iret_6_6__mem_at alphas a) front)} (sym eq)
                                          (iret_7_7__extend_elem_fwd j' (iret_6_6__mem_at alphas a) front t f (fst (sl t) et) ef jt')
                          Left l => let (el, ng) = iret_8_1__end_elem_inv (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts y l
                                        (t ** (f ** (et, ef, jt, eq))) = iret_7_7__extend_elem_inv j (iret_6_6__mem_at alphas a) front y (fst (sa y) el)
                                    in case iret_12__bool_split (j' t f) of
                                         Left jt' => replace {p = \z => Elem z (iret_7_7__extend_front j' (iret_6_6__mem_at alphas a) front)} (sym eq)
                                                       (iret_7_7__extend_elem_fwd j' (iret_6_6__mem_at alphas a) front t f et ef jt')
                                         Right jf' => absurd (ng (replace {p = \z => Elem z (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm)} (sym eq)
                                                        (iret_7_7__extend_elem_fwd (\u, g => j u g && not (j' u g)) (iret_6_6__mem_at alphas a) lm t f
                                                           (snd (sl t) et) ef (iret_12__and_both _ _ jt (iret_12__not_false _ jf')))))
            , \e => let (t ** (f ** (et, ef, jt', eq))) = iret_7_7__extend_elem_inv j' (iret_6_6__mem_at alphas a) front y e
                    in snd (iret_8_1__activate_same_set wm (iret_19_5__born j j' (iret_6_6__mem_at alphas a) lm)
                              (iret_8_1__end (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts)
                              (iret_8_1__tuples (iret_8_1__end (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts))
                              (iret_7_4__same_set_refl _) y)
                         (case iret_12__bool_split (j t f) of
                            Left jt => lcyc_1_1__elem_append_left
                                         (iret_8_1__end_elem_fwd (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts y
                                            (snd (sa y) (replace {p = \z => Elem z (iret_7_7__extend_front j (iret_6_6__mem_at alphas a) front)} (sym eq)
                                                           (iret_7_7__extend_elem_fwd j (iret_6_6__mem_at alphas a) front t f et ef jt)))
                                            (replace {p = \z => Not (Elem z (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm))} (sym eq)
                                               (iret_19_5__not_ended j j' (iret_6_6__mem_at alphas a) lm t f jt')))
                            Right jf => lcyc_1_1__elem_append_right (iret_8_1__tuples (iret_8_1__end (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts))
                                          (replace {p = \z => Elem z (iret_19_5__born j j' (iret_6_6__mem_at alphas a) lm)} (sym eq)
                                             (iret_7_7__extend_elem_fwd (\u, g => not (j u g) && j' u g) (iret_6_6__mem_at alphas a) lm t f
                                                (snd (sl t) et) ef (iret_12__and_both _ _ (iret_12__not_false _ jf) jt')))) )
    , iret_8_1__activate_distinct wm (iret_19_5__born j j' (iret_6_6__mem_at alphas a) lm)
        (iret_8_1__end (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts)
        (iret_8_1__end_distinct (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts da)
        (iret_7_7__distinct_extend (\u, g => not (j u g) && j' u g) (iret_6_6__mem_at alphas a) (dm a) lm dl)
        (\y, eb, el => let (t ** (f ** (_, _, jf, _, eq))) = iret_19_5__born_inv j j' (iret_6_6__mem_at alphas a) lm y eb
                           (el', _) = iret_8_1__end_elem_inv (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts y el
                           (u ** (g ** (_, _, ju, eq'))) = iret_7_7__extend_elem_inv j (iret_6_6__mem_at alphas a) front y (fst (sa y) el')
                       in iret_19_5__clash j u t g f (trans (sym eq') eq) ju jf) ) )

-- ---------------------------------------------------------------------
-- Refraction under ticks
-- ---------------------------------------------------------------------

--@derives [LDET.5.8]
--@derives [LDET.5.3]
--@derives [IRET.11.3.2]
--@derives [IDAT.6.2.2]
||| A TICK IS NOT A CHANGE TO THE LHS: an activation whose match the new
||| test still admits is, after the tick, the same record — its `fired` flag
||| included. A fired match stays refracted across every tick that leaves it
||| matching.
export
ldet_5_8__tick_keeps_activation : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (j' : Iret_7_5__join) ->
                                  (b : Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (x : Iret_8_1__act) ->
                                  (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) ->
                                  Elem x acts -> atuple x = t ++ [f] -> j' t f = True ->
                                  Elem x (snd (iret_19_5__retime wm alphas j' b acts))
ldet_5_8__tick_keeps_activation wm alphas j' b acts x t f ex tx jt =
  iret_8_1__activate_keeps wm _ _ x
    (iret_8_1__end_keeps _ acts x ex
       (replace {p = \z => Not (Elem z (iret_19_5__ended (bjoin b) j' (iret_6_6__mem_at alphas (balpha b)) (blmem b)))} (sym tx)
          (iret_19_5__not_ended (bjoin b) j' (iret_6_6__mem_at alphas (balpha b)) (blmem b) t f jt)))

--@spec [LTIM.2.4.2]
||| Quiescent: every activation has fired — what a pump leaves when every
||| RHS has run.
public export
Ltim_2_4_2__quiescent : List Iret_8_1__act -> Type
Ltim_2_4_2__quiescent acts = (x : Iret_8_1__act) -> Elem x acts -> afired x = True

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
--@derives [LTIM.2.5.1]
||| AFTER A QUIESCENT PUMP, A TICK LEAVES UNFIRED ONLY THE MATCHES IT MADE:
||| what the next run fires is exactly what the tick made true.
export
ltim_2_4_2__unfired_are_born : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (j' : Iret_7_5__join) ->
                               (b : Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> Ltim_2_4_2__quiescent acts ->
                               (x : Iret_8_1__act) -> Elem x (snd (iret_19_5__retime wm alphas j' b acts)) -> afired x = False ->
                               Elem (atuple x) (iret_19_5__born (bjoin b) j' (iret_6_6__mem_at alphas (balpha b)) (blmem b))
ltim_2_4_2__unfired_are_born wm alphas j' b acts q x e nf =
  case iret_8_1__activate_inv wm _ _ x e of
    Right (_, en) => en
    Left e1 => absurd (trans (sym (q x (iret_8_1__end_sub _ acts x e1))) nf)

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| AND EVERY MATCH THE TICK MADE IS THERE TO FIRE: "a rule whose only
||| unmet gate is a time-dependent condition must fire once the clock
||| advances to satisfy it".
export
ltim_2_4_2__born_unfired : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (j' : Iret_7_5__join) ->
                           (b : Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (y : Iret_7_1__token) ->
                           Elem y (iret_19_5__born (bjoin b) j' (iret_6_6__mem_at alphas (balpha b)) (blmem b)) ->
                           Elem (MkAct y False) (snd (iret_19_5__retime wm alphas j' b acts))
ltim_2_4_2__born_unfired wm alphas j' b acts y e = iret_8_1__activate_new wm _ _ y e

--@spec [LTIM.2.5.1]
||| A gate that stays true once true: the test at a later clock admits
||| whatever it admitted earlier (`now() > t`, `now() >= t`).
public export
Ltim_2_5_1__rising : Ltim_2_4_1__timed -> Type
Ltim_2_5_1__rising tj = (c, c' : Nat) -> LTE c c' -> (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) -> tj c t f = True -> tj c' t f = True

--@derives [LTIM.2.5.1]
--@derives [LDET.5.8]
||| EDGE-ONCE, for a gate that stays true once true: two ticks, the second
||| starting no earlier than the first ends, never both make the same match.
||| With `ltim_2_4_2__unfired_are_born`, a match fires in at most one pump —
||| on the tick at which its condition goes false to true — however many
||| ticks follow.
export
ltim_2_5_1__edge_once : (tj : Ltim_2_4_1__timed) -> Ltim_2_5_1__rising tj ->
                        (p, q, r, s : Nat) -> LTE q r ->
                        (mem, mem' : List Lfac_1_7_1__fact) -> (lm, lm' : List Iret_7_1__token) -> (y : Iret_7_1__token) ->
                        Elem y (iret_19_5__born (tj p) (tj q) mem lm) -> Elem y (iret_19_5__born (tj r) (tj s) mem' lm') -> Void
ltim_2_5_1__edge_once tj rise p q r s qr mem mem' lm lm' y e1 e2 =
  let (t ** (f ** (_, _, _, jq, eq1))) = iret_19_5__born_inv (tj p) (tj q) mem lm y e1
      (u ** (g ** (_, _, jr, _, eq2))) = iret_19_5__born_inv (tj r) (tj s) mem' lm' y e2
  in iret_19_5__clash (tj r) t u f g (trans (sym eq1) eq2) (rise q r qr t f jq) jr

-- ---------------------------------------------------------------------
-- [LDET.5.8]'s example, on the network
-- ---------------------------------------------------------------------

--@spec [LDET.5.8]
||| `now() > 5`: the gate of `rule late: Ping p where now() > 5000000000`,
||| in small units.
public export
ldet_5_8__late : Nat -> Bool
ldet_5_8__late c = 5 < c

--@spec [LDET.5.8]
public export
ldet_5_8__gate : Ltim_2_4_1__timed
ldet_5_8__gate = \c, t, f => ldet_5_8__late c

--@spec [LDET.5.8]
||| The rule loaded at clock 0: one alpha for `Ping`, one positive node
||| carrying the gate, an RHS that only logs.
public export
ldet_5_8__loaded : Iret_19__engine
ldet_5_8__loaded = rdsc_4a_5__load [(0, \_ => True)] [([(0, ldet_5_8__gate 0, False)], [])]

--@spec [LDET.5.8]
public export
ldet_5_8__ping : Lfac_1_7_1__fact
ldet_5_8__ping = MkFact 1 0 1 0

--@derives [LDET.5.8]
--@derives [LTIM.2.5.1]
||| THE CLAUSE'S OBSERVABLE: assert one `Ping`, pump twice with the gate
||| shut, advance the clock past it, pump twice more — `late` fires exactly
||| once, in the third pump.
export
ldet_5_8__late_fires_once :
  iret_19_5__counts (\_ => Explicit) [Just ldet_5_8__gate] 10 [1, 2, 6, 7] (iret_19_1__insert ldet_5_8__ping ldet_5_8__loaded) = [0, 0, 1, 0]
ldet_5_8__late_fires_once = Refl

--@derives [LTIM.2.5.3]
||| ALREADY TRUE AT ASSERT: with the clock past the gate, a `Ping` asserted
||| between pumps fires on the next pump, and never again. (The tick from 6
||| to 7 makes nothing — the gate was already true — so the firing is the
||| activation the assertion made.)
export
ltim_2_5_3__true_at_assert :
  iret_19_5__counts (\_ => Explicit) [Just ldet_5_8__gate] 10 [7, 8]
    (iret_19_1__insert ldet_5_8__ping (fst (iret_19_5__pump (\_ => Explicit) [Just ldet_5_8__gate] 10 6 ldet_5_8__loaded))) = [1, 0]
ltim_2_5_3__true_at_assert = Refl

-- ---------------------------------------------------------------------
-- A condition that closes ends the match; a reopening is a new edge
-- ---------------------------------------------------------------------

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.7.2]
--@derives [IRET.19.5]
||| A CONDITION THAT CLOSES ENDS THE MATCH: after a tick, under the view, no
||| activation is left whose match the new test refuses, fired or not. The
||| match ends and its activation with it, as a `within` window's does.
export
ltim_2_5_1__closing_ends : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas ->
                           (front : List Iret_7_1__token) -> (a : Nat) -> (j, j' : Iret_7_5__join) ->
                           (lm : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) -> (acts : List Iret_8_1__act) ->
                           Iret_7_7__consistent alphas front [MkBeta a j False lm cs] acts ->
                           (x : Iret_8_1__act) -> Elem x (snd (iret_19_5__retime wm alphas j' (MkBeta a j False lm cs) acts)) ->
                           (u : Iret_7_1__token) -> (g : Lfac_1_7_1__fact) -> atuple x = u ++ [g] -> j' u g = False -> Void
ltim_2_5_1__closing_ends wm alphas dm front a j j' lm cs acts con x ex u g tx jf =
  let (_, _, _, (sa', _)) = iret_19_5__retime_consistent wm alphas dm front a j j' lm cs acts con
      (t ** (f ** (_, _, jt, eq))) = iret_7_7__extend_elem_inv j' (iret_6_6__mem_at alphas a) front (atuple x)
                                       (fst (sa' (atuple x)) (lcyc_1_1__elem_map_fwd atuple ex))
  in iret_19_5__clash j' t u f g (trans (sym eq) tx) jt jf

--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
--@derives [LDET.5.8]
||| A REOPENING IS A NEW EDGE: an activation of a match the tick made is
||| unfired, whatever was fired before the gate shut. Under the view no old
||| activation can carry that match, since the old test refused it; so it
||| is one the tick made, and the tick makes its activations unfired. "No
||| memory of the firing outlives the activation."
export
ltim_2_5_1__reopening_is_unfired : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> Iret_6_5__distinct_mems alphas ->
                                   (front : List Iret_7_1__token) -> (a : Nat) -> (j, j' : Iret_7_5__join) ->
                                   (lm : List Iret_7_1__token) -> (cs : List (Iret_7_1__token, Nat)) -> (acts : List Iret_8_1__act) ->
                                   Iret_7_7__consistent alphas front [MkBeta a j False lm cs] acts ->
                                   (x : Iret_8_1__act) -> Elem x (snd (iret_19_5__retime wm alphas j' (MkBeta a j False lm cs) acts)) ->
                                   Elem (atuple x) (iret_19_5__born j j' (iret_6_6__mem_at alphas a) lm) -> afired x = False
ltim_2_5_1__reopening_is_unfired wm alphas dm front a j j' lm cs acts (_, _, _, (sa, _)) x ex eb =
  case iret_8_1__activate_inv wm (iret_19_5__born j j' (iret_6_6__mem_at alphas a) lm)
                              (iret_8_1__end (iret_19_5__ended j j' (iret_6_6__mem_at alphas a) lm) acts) x ex of
    Right (nf, _) => nf
    Left old =>
      let (t ** (f ** (_, _, jt, eq))) = iret_7_7__extend_elem_inv j (iret_6_6__mem_at alphas a) front (atuple x)
                                           (fst (sa (atuple x)) (lcyc_1_1__elem_map_fwd atuple (iret_8_1__end_sub _ acts x old)))
          (u ** (g ** (_, _, ju, _, eq'))) = iret_19_5__born_inv j j' (iret_6_6__mem_at alphas a) lm (atuple x) eb
      in void (iret_19_5__clash j t u f g (trans (sym eq) eq') jt ju)

-- ---------------------------------------------------------------------
-- A window that shuts and reopens fires once per opening
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
||| `(now() > 0 and now() < 2) or now() > 2`: open at 1, shut at 2, open
||| again from 3 -- the clause's window that shuts and reopens.
public export
ltim_2_5_1__window : Nat -> Bool
ltim_2_5_1__window c = (c == 1) || (2 < c)

--@spec [LTIM.2.5.1]
public export
ltim_2_5_1__window_gate : Ltim_2_4_1__timed
ltim_2_5_1__window_gate = \c, t, f => ltim_2_5_1__window c

--@spec [LTIM.2.5.1]
public export
ltim_2_5_1__window_loaded : Iret_19__engine
ltim_2_5_1__window_loaded = rdsc_4a_5__load [(0, \_ => True)] [([(0, ltim_2_5_1__window_gate 0, False)], [])]

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.8.3]
||| THE SECOND EDGE FIRES AGAIN, as the clause requires: one `Ping`, one
||| wrapper, never retracted; the gate opens at 1, shuts at 2, reopens at
||| 3. The rule fires in the first pump and in the third: once per opening.
export
ltim_2_5_1__second_edge_refires :
  iret_19_5__counts (\_ => Explicit) [Just ltim_2_5_1__window_gate] 10 [1, 2, 3, 4] (iret_19_1__insert ldet_5_8__ping ltim_2_5_1__window_loaded) = [1, 0, 1, 0]
ltim_2_5_1__second_edge_refires = Refl

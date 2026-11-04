-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE EDGE COUNT, ON THE CLOCKED NETWORK: what a pump fires is what the
||| tick made, and the firings of a history of ticks are its rising edges.
||| The clocked-network programme's part B.
|||
||| NORMATIVE COMPANION to Rete/NetworkClocked.idr, which it stands on.
|||
||| WHY. The refraction theorem says what a step SELECTS: the first unfired
||| activation. Nothing in the lane said what a run ACCUMULATES. "A rule
||| whose only unmet gate is a time-dependent condition must fire once the
||| clock advances to satisfy it" ([LTIM.2.4.2]) and "once per false-to-true
||| edge" ([LTIM.2.5.1]) are claims about a run's count, and this module
||| states them as such.
|||
||| THE FRAME. A step fires one activation and then runs its rule's actions,
||| and an action can change every chain's activations through the alphas:
||| an `emit` of a kind a timed chain's alpha admits makes a match the tick
||| did not. A count over a run therefore needs the chains the actions do
||| not touch. The frame taken here is the ACTION-FREE program: every rule's
||| action list is empty (`Ltim_2_5_1__action_free`), which is [LDET.5.8]'s
||| example rule, one that only logs; [LTIM.2.5.1]'s text shows no rule.
||| Under it a step is the marking of one activation and nothing else.
|||
||| PROVED.
|||
|||   * B0, THE RUN IS ONE MARK PER UNFIRED ACTIVATION
|||     (`ltim_2_5_1__run_marks_all`): under `action_free`, a run with fuel
|||     above the number of unfired activations halts `Quiescent`, fires
|||     exactly that many times, and leaves every chain with every activation
|||     marked and nothing else changed. The lane's first run lemma that
|||     counts.
|||   * B1, THE PUMP FIRES THE BORN (`ltim_2_5_1__pump_fires_the_born`): on
|||     the composed engine, from a quiescent action-free state with an empty
|||     dependency table and nothing expiring, the pump at a tick fires
|||     exactly as many times as the tick made matches, over every timed
|||     chain, and leaves every activation fired. Each born activation fires
|||     once and none twice.
|||   * B2, THE COUNTS ARE THE EDGES (`ltim_2_5_1__counts_are_edges`): one
|||     fact, one rule whose single positive node carries ANY gate on the
|||     clock, no actions, no deadline: the pump counts over ANY list of
|||     ticks from ANY starting clock are the gate's rising edges over that
|||     history (`Ltim_2_5_1__edges`). Once per false-to-true edge, for every
|||     gate and every history, as a theorem. Part A's `[1, 0, 1, 0]` is an
|||     instance (`ltim_2_5_1__second_edge_refires_is_an_instance`).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. The frame is
||| syntactic: a program with actions is outside B0 and B1, and the general
||| frame ("no action writes a kind a timed chain's alpha admits") is not
||| proved here. B2 is for a gate that reads the clock alone, one fact, no
||| deadline; a fact that expires while the gate is shut is part A's
||| executed witness and not a theorem of this file. The two clocks and
||| replay are part C.
module Rete.NetworkEdges

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.TmsRun
import Rete.TtlSweep
import Rete.Network
import Rete.NetworkView
import Rete.NetworkTms
import Rete.NetworkTtl
import Rete.NetworkTick
import Rete.NetworkClocked
import Lcyc.Lemmas
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The frame, the count, the marking of everything
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
||| ACTION-FREE: every rule's action list is empty. Rules that only log, as
||| [LDET.5.8]'s example does.
public export
Ltim_2_5_1__action_free : List Rlow_4_2_1__chain -> Type
Ltim_2_5_1__action_free chains = All (\ch => cactions ch = []) chains

--@spec [IRET.11.4]
||| The unfired activations of a terminal.
public export
iret_11_4__unfired : List Iret_8_1__act -> Nat
iret_11_4__unfired acts = length (filter (\a => not (afired a)) acts)

--@spec [IRET.11.4]
||| The unfired activations over every chain: what a run has left to fire.
public export
iret_11_4__unfired_count : List Rlow_4_2_1__chain -> Nat
iret_11_4__unfired_count [] = 0
iret_11_4__unfired_count (ch :: chs) = iret_11_4__unfired (cacts ch) + iret_11_4__unfired_count chs

--@spec [IDAT.6.2.2]
||| Every activation of every chain marked fired; nothing else touched.
public export
idat_6_2_2__mark_all : List Rlow_4_2_1__chain -> List Rlow_4_2_1__chain
idat_6_2_2__mark_all chains = map (\ch => MkChain (cnodes ch) (map idat_6_2_2__mark_act (cacts ch)) (cactions ch)) chains

-- ---------------------------------------------------------------------
-- Small lemmas
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
||| A successor is not zero.
export
iret_11_4__succ_not_zero : (n : Nat) -> S n = 0 -> Void
iret_11_4__succ_not_zero n Refl impossible

--@derives [IRET.11.4]
||| A sum is zero only when both parts are.
export
iret_11_4__plus_zero : (a, b : Nat) -> a + b = 0 -> (a = 0, b = 0)
iret_11_4__plus_zero Z b h = (Refl, h)
iret_11_4__plus_zero (S a) b h = absurd (iret_11_4__succ_not_zero (a + b) h)

--@derives [IRET.11.4]
||| A mapped option that is nothing was nothing.
export
iret_11_4__map_nothing : {a, b : Type} -> (f : a -> b) -> (m : Maybe a) -> map f m = Nothing -> m = Nothing
iret_11_4__map_nothing f Nothing h = Refl
iret_11_4__map_nothing f (Just x) h = absurd h

--@derives [IRET.11.4]
||| A mapped option that is something was something.
export
iret_11_4__map_just : {a, b : Type} -> (f : a -> b) -> (m : Maybe a) -> (y : b) -> map f m = Just y -> (x ** (m = Just x, y = f x))
iret_11_4__map_just f Nothing y h = absurd h
iret_11_4__map_just f (Just x) y h = (x ** (Refl, sym (iret_11_4__just_inj h)))

--@derives [IRET.11.1]
||| The selection's successor map, undone: the tail selected `(r', j)` and
||| the whole selected `(S r', j)`.
export
iret_11_1__select_map_just : (g : (Nat, Nat) -> (Nat, Nat)) -> (m : Maybe (Nat, Nat)) -> (r, j : Nat) -> map g m = Just (r, j) ->
                              ((x, y : Nat) -> g (x, y) = (S x, y)) ->
                              (r' ** (m = Just (r', j), r = S r'))
iret_11_1__select_map_just g Nothing r j h hg = absurd h
iret_11_1__select_map_just g (Just (r0, j0)) r j h hg =
  let pe = the ((S r0, j0) = (r, j)) (trans (sym (hg r0 j0)) (iret_11_4__just_inj h))
  in (r0 ** (rewrite cong snd pe in Refl, sym (cong fst pe)))

--@derives [IRET.11.1]
||| The selection, as the two cases a proof splits on.
export
iret_11_1__select_cases : (chains : List Rlow_4_2_1__chain) ->
                          Either (iret_11_1__select chains = Nothing) (r ** j ** iret_11_1__select chains = Just (r, j))
iret_11_1__select_cases chains with (iret_11_1__select chains)
  iret_11_1__select_cases chains | Nothing = Left Refl
  iret_11_1__select_cases chains | (Just (r, j)) = Right (r ** j ** Refl)

-- ---------------------------------------------------------------------
-- Selection against the count
-- ---------------------------------------------------------------------

--@derives [IRET.11.3.1]
||| A terminal with no first unfired activation has none.
export
iret_11_3_1__first_unfired_nothing : (acts : List Iret_8_1__act) -> iret_11_3_1__first_unfired acts = Nothing -> iret_11_4__unfired acts = 0
iret_11_3_1__first_unfired_nothing [] h = Refl
iret_11_3_1__first_unfired_nothing (MkAct t True :: xs) h =
  iret_11_3_1__first_unfired_nothing xs (iret_11_4__map_nothing S (iret_11_3_1__first_unfired xs) h)
iret_11_3_1__first_unfired_nothing (MkAct t False :: xs) h = absurd h

--@derives [IRET.11.3.1]
||| The first unfired activation is there, and unfired.
export
iret_11_3_1__first_unfired_just : (acts : List Iret_8_1__act) -> (j : Nat) -> iret_11_3_1__first_unfired acts = Just j ->
                                  (a ** (rarc_5_6_5__nth j acts = Just a, afired a = False))
iret_11_3_1__first_unfired_just [] j h = absurd h
iret_11_3_1__first_unfired_just (MkAct t True :: xs) j h =
  let (j' ** (e, eq)) = iret_11_4__map_just S (iret_11_3_1__first_unfired xs) j h
      (a ** (na, fa)) = iret_11_3_1__first_unfired_just xs j' e
  in (a ** (rewrite eq in na, fa))
iret_11_3_1__first_unfired_just (MkAct t False :: xs) j h =
  (MkAct t False ** (rewrite sym (iret_11_4__just_inj h) in Refl, Refl))

--@derives [IRET.11.1]
||| When nothing is selected, nothing is unfired.
export
iret_11_1__select_nothing : (chains : List Rlow_4_2_1__chain) -> iret_11_1__select chains = Nothing -> iret_11_4__unfired_count chains = 0
iret_11_1__select_nothing [] h = Refl
iret_11_1__select_nothing (MkChain n a ac :: cs) h with (iret_11_3_1__first_unfired a) proof fu
  iret_11_1__select_nothing (MkChain n a ac :: cs) h | (Just j) = absurd h
  iret_11_1__select_nothing (MkChain n a ac :: cs) h | Nothing =
    cong2 (+) (iret_11_3_1__first_unfired_nothing a fu)
              (iret_11_1__select_nothing cs (iret_11_4__map_nothing _ (iret_11_1__select cs) h))

--@derives [IRET.11.1]
||| What is selected is there, and unfired.
export
iret_11_1__select_just : (chains : List Rlow_4_2_1__chain) -> (r, j : Nat) -> iret_11_1__select chains = Just (r, j) ->
                         (ch ** a ** (rarc_5_6_5__nth r chains = Just ch, rarc_5_6_5__nth j (cacts ch) = Just a, afired a = False))
iret_11_1__select_just [] r j h = absurd h
iret_11_1__select_just (MkChain n a ac :: cs) r j h with (iret_11_3_1__first_unfired a) proof fu
  iret_11_1__select_just (MkChain n a ac :: cs) r j h | (Just j0) =
    let (x ** (na, fa)) = iret_11_3_1__first_unfired_just a j0 fu
        pe = the ((0, j0) = (r, j)) (iret_11_4__just_inj h)
    in (MkChain n a ac ** x ** (rewrite sym (cong fst pe) in Refl, rewrite sym (cong snd pe) in na, fa))
  iret_11_1__select_just (MkChain n a ac :: cs) r j h | Nothing =
    let (r' ** (e, eq)) = iret_11_1__select_map_just _ (iret_11_1__select cs) r j h (\x, y => Refl)
        (ch ** x ** (nt, nj, fa)) = iret_11_1__select_just cs r' j e
    in (ch ** x ** (rewrite eq in nt, nj, fa))

-- ---------------------------------------------------------------------
-- Marking against the count
-- ---------------------------------------------------------------------

--@derives [IDAT.6.2.2]
--@derives [IRET.11.4]
||| Marking an unfired activation lowers the terminal's unfired count by one.
export
idat_6_2_2__mark_acts_count : (j : Nat) -> (acts : List Iret_8_1__act) -> (a : Iret_8_1__act) ->
                              rarc_5_6_5__nth j acts = Just a -> afired a = False ->
                              S (iret_11_4__unfired (idat_6_2_2__mark_acts j acts)) = iret_11_4__unfired acts
idat_6_2_2__mark_acts_count j [] a nt nf = absurd nt
idat_6_2_2__mark_acts_count Z (MkAct t False :: xs) a nt nf = Refl
idat_6_2_2__mark_acts_count Z (MkAct t True :: xs) a nt nf = absurd (trans (cong afired (iret_11_4__just_inj nt)) nf)
idat_6_2_2__mark_acts_count (S j) (MkAct t True :: xs) a nt nf = idat_6_2_2__mark_acts_count j xs a nt nf
idat_6_2_2__mark_acts_count (S j) (MkAct t False :: xs) a nt nf = cong S (idat_6_2_2__mark_acts_count j xs a nt nf)

--@derives [IDAT.6.2.2]
--@derives [IRET.11.4]
||| And over the chains.
export
idat_6_2_2__mark_net_count : (r, j : Nat) -> (chains : List Rlow_4_2_1__chain) -> (ch : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) ->
                             rarc_5_6_5__nth r chains = Just ch -> rarc_5_6_5__nth j (cacts ch) = Just a -> afired a = False ->
                             S (iret_11_4__unfired_count (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains)) = iret_11_4__unfired_count chains
idat_6_2_2__mark_net_count r j [] ch a nt nj nf = absurd nt
idat_6_2_2__mark_net_count Z j (MkChain n acts ac :: cs) ch a nt nj nf =
  cong (\x => x + iret_11_4__unfired_count cs)
    (idat_6_2_2__mark_acts_count j acts a (replace {p = \z => rarc_5_6_5__nth j (cacts z) = Just a} (sym (iret_11_4__just_inj nt)) nj) nf)
idat_6_2_2__mark_net_count (S r) j (c :: cs) ch a nt nj nf =
  trans (plusSuccRightSucc (iret_11_4__unfired (cacts c)) (iret_11_4__unfired_count (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) cs)))
        (cong (\x => iret_11_4__unfired (cacts c) + x) (idat_6_2_2__mark_net_count r j cs ch a nt nj nf))

--@derives [LTIM.2.5.1]
||| Marking keeps a program action-free.
export
ltim_2_5_1__action_free_mark : (r, j : Nat) -> (chains : List Rlow_4_2_1__chain) -> Ltim_2_5_1__action_free chains ->
                               Ltim_2_5_1__action_free (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains)
ltim_2_5_1__action_free_mark r j [] af = af
ltim_2_5_1__action_free_mark Z j (c :: cs) (p :: ps) = p :: ps
ltim_2_5_1__action_free_mark (S r) j (c :: cs) (p :: ps) = p :: ltim_2_5_1__action_free_mark r j cs ps

--@derives [IDAT.6.2.2]
||| Marking twice is marking once.
export
idat_6_2_2__mark_twice : (a : Iret_8_1__act) -> idat_6_2_2__mark_act (idat_6_2_2__mark_act a) = idat_6_2_2__mark_act a
idat_6_2_2__mark_twice (MkAct t fr) = Refl

--@derives [IDAT.6.2.2]
||| Marking everything after marking one is marking everything.
export
idat_6_2_2__mark_all_acts : (j : Nat) -> (acts : List Iret_8_1__act) ->
                            map idat_6_2_2__mark_act (idat_6_2_2__mark_acts j acts) = map idat_6_2_2__mark_act acts
idat_6_2_2__mark_all_acts j [] = Refl
idat_6_2_2__mark_all_acts Z (a :: as) = cong (\x => x :: map idat_6_2_2__mark_act as) (idat_6_2_2__mark_twice a)
idat_6_2_2__mark_all_acts (S j) (a :: as) = cong (idat_6_2_2__mark_act a ::) (idat_6_2_2__mark_all_acts j as)

--@derives [IDAT.6.2.2]
||| And over the chains.
export
idat_6_2_2__mark_all_set_at : (r, j : Nat) -> (chains : List Rlow_4_2_1__chain) ->
                              idat_6_2_2__mark_all (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains) = idat_6_2_2__mark_all chains
idat_6_2_2__mark_all_set_at r j [] = Refl
idat_6_2_2__mark_all_set_at Z j (c :: cs) =
  cong (\as => MkChain (cnodes c) as (cactions c) :: idat_6_2_2__mark_all cs) (idat_6_2_2__mark_all_acts j (cacts c))
idat_6_2_2__mark_all_set_at (S r) j (c :: cs) =
  cong (MkChain (cnodes c) (map idat_6_2_2__mark_act (cacts c)) (cactions c) ::) (idat_6_2_2__mark_all_set_at r j cs)

--@derives [IDAT.6.2.2]
||| A terminal with nothing unfired is unchanged by marking everything.
export
idat_6_2_2__mark_fired_acts : (acts : List Iret_8_1__act) -> iret_11_4__unfired acts = 0 -> map idat_6_2_2__mark_act acts = acts
idat_6_2_2__mark_fired_acts [] z = Refl
idat_6_2_2__mark_fired_acts (MkAct t True :: xs) z = cong (MkAct t True ::) (idat_6_2_2__mark_fired_acts xs z)
idat_6_2_2__mark_fired_acts (MkAct t False :: xs) z = absurd (iret_11_4__succ_not_zero _ z)

--@derives [IDAT.6.2.2]
||| And so are chains with nothing unfired.
export
idat_6_2_2__mark_all_fired : (chains : List Rlow_4_2_1__chain) -> iret_11_4__unfired_count chains = 0 -> idat_6_2_2__mark_all chains = chains
idat_6_2_2__mark_all_fired [] z = Refl
idat_6_2_2__mark_all_fired (MkChain n a ac :: cs) z =
  let (z1, z2) = iret_11_4__plus_zero (iret_11_4__unfired a) (iret_11_4__unfired_count cs) z
  in cong2 (::) (cong (\as => MkChain n as ac) (idat_6_2_2__mark_fired_acts a z1)) (idat_6_2_2__mark_all_fired cs z2)

-- ---------------------------------------------------------------------
-- B0: the run is one mark per unfired activation
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
--@derives [IRET.11.5]
--@derives [LTIM.2.5.1]
||| B0. THE RUN IS ONE MARK PER UNFIRED ACTIVATION: under an action-free
||| program, with fuel above the number of unfired activations, the run
||| halts `Quiescent`, fires exactly that many times, and leaves every
||| activation of every chain marked -- working memory, the alphas, the
||| nodes, the tuples, the dependency table, the deadlines and the clock as
||| they were.
export
ltim_2_5_1__run_marks_all : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) ->
                            (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                            (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                            Ltim_2_5_1__action_free chains -> LT (iret_11_4__unfired_count chains) fuel ->
                            iret_11_4__run_ttl_net pg ttl fuel (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c)
                              = ( MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al (idat_6_2_2__mark_all chains))) rows) dl c
                                , Quiescent, iret_11_4__unfired_count chains )
ltim_2_5_1__run_marks_all pg ttl Z wm al chains rows dl c af lt = absurd lt
ltim_2_5_1__run_marks_all pg ttl (S k) wm al chains rows dl c af lt = case iret_11_1__select_cases chains of
  Left sel =>
    let z = iret_11_1__select_nothing chains sel
    in trans (iret_11_4__run_ttl_net_nothing pg ttl k (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c)
                (iret_11_4__step_ttl_net_quiet pg ttl (MkEngine wm (MkNetwork al chains)) rows dl c sel))
             (cong2 (\chs, n => (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chs)) rows) dl c, Quiescent, n))
                    (sym (idat_6_2_2__mark_all_fired chains z)) (sym z))
  Right (r ** j ** sel) =>
    let (ch ** a ** (nt, nj, nf)) = iret_11_1__select_just chains r j sel
        ac = the (cactions ch = []) (lcyc_1_1__all_lookup af (lcyc_1_1__nth_elem r chains nt))
        st = the (iret_11_4__step_ttl_net pg ttl (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c)
                    = Just (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains))) rows) dl c))
                 (trans (iret_11_4__step_ttl_net_fires pg ttl (MkEngine wm (MkNetwork al chains)) rows dl c r j ch a sel nt nj)
                        (cong (\acts => Just (rarc_5_6_7__do_actions_ttl_net pg ttl r a acts
                                                (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j (MkEngine wm (MkNetwork al chains))) rows) dl c))) ac))
        dec = the (S (iret_11_4__unfired_count (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains)) = iret_11_4__unfired_count chains)
                  (idat_6_2_2__mark_net_count r j chains ch a nt nj nf)
        lt' = the (LT (iret_11_4__unfired_count (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains)) k)
                  (fromLteSucc (replace {p = \n => LTE (S n) (S k)} (sym dec) lt))
        ih = ltim_2_5_1__run_marks_all pg ttl k wm al (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains) rows dl c
               (ltim_2_5_1__action_free_mark r j chains af) lt'
        rj = iret_11_4__run_ttl_net_just pg ttl k
               (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) rows) dl c)
               (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains))) rows) dl c)
               st _ _ _ ih
    in trans rj (cong2 (\chs, n => (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chs)) rows) dl c, Quiescent, n))
                       (idat_6_2_2__mark_all_set_at r j chains) dec)

-- ---------------------------------------------------------------------
-- B1: the pump fires the born
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.2]
--@spec [IRET.19.5]
||| The matches one chain's re-time at a clock makes: for the single
||| positive node with a timed test, the born tokens; for any other shape,
||| none.
public export
iret_19_5__born_chain : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> Maybe Ltim_2_4_1__timed -> Nat -> Rlow_4_2_1__chain -> Nat
iret_19_5__born_chain wm alphas (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions) =
  length (iret_19_5__born j (tj c) (iret_6_6__mem_at alphas a) lm)
iret_19_5__born_chain wm alphas _ c ch = 0

--@spec [LTIM.2.4.2]
--@spec [IRET.19.5]
||| The matches the tick makes, over every chain.
public export
iret_19_5__born_count : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> List (Maybe Ltim_2_4_1__timed) -> Nat -> List Rlow_4_2_1__chain -> Nat
iret_19_5__born_count wm alphas [] c chains = 0
iret_19_5__born_count wm alphas (t :: ts) c [] = 0
iret_19_5__born_count wm alphas (t :: ts) c (ch :: chs) = iret_19_5__born_chain wm alphas t c ch + iret_19_5__born_count wm alphas ts c chs

--@derives [IRET.8.1]
||| Inserting an unfired activation raises the unfired count by one.
export
iret_8_1__insert_unfired : (wm : Rarc_5_6_4__wm) -> (t : Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                           iret_11_4__unfired (ldet_5_5__insert wm (MkAct t False) acts) = S (iret_11_4__unfired acts)
iret_8_1__insert_unfired wm t [] = Refl
iret_8_1__insert_unfired wm t (MkAct u True :: bs) with (ldet_5_5__before wm t u)
  iret_8_1__insert_unfired wm t (MkAct u True :: bs) | True = Refl
  iret_8_1__insert_unfired wm t (MkAct u True :: bs) | False = iret_8_1__insert_unfired wm t bs
iret_8_1__insert_unfired wm t (MkAct u False :: bs) with (ldet_5_5__before wm t u)
  iret_8_1__insert_unfired wm t (MkAct u False :: bs) | True = Refl
  iret_8_1__insert_unfired wm t (MkAct u False :: bs) | False = cong S (iret_8_1__insert_unfired wm t bs)

--@derives [IRET.8.1]
||| Activating new matches adds one unfired activation per match.
export
iret_8_1__activate_unfired : (wm : Rarc_5_6_4__wm) -> (new : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                             iret_11_4__unfired (iret_8_1__activate wm new acts) = length new + iret_11_4__unfired acts
iret_8_1__activate_unfired wm [] acts = Refl
iret_8_1__activate_unfired wm (t :: ts) acts =
  trans (iret_8_1__activate_unfired wm ts (ldet_5_5__insert wm (MkAct t False) acts))
        (trans (cong (\x => length ts + x) (iret_8_1__insert_unfired wm t acts))
               (sym (plusSuccRightSucc (length ts) (iret_11_4__unfired acts))))

--@derives [IRET.8.1]
||| Dropping activations from a terminal with nothing unfired leaves
||| nothing unfired.
export
iret_8_1__filter_unfired : (q : Iret_8_1__act -> Bool) -> (acts : List Iret_8_1__act) -> iret_11_4__unfired acts = 0 ->
                           iret_11_4__unfired (filter q acts) = 0
iret_8_1__filter_unfired q [] z = Refl
iret_8_1__filter_unfired q (MkAct t True :: xs) z with (q (MkAct t True))
  iret_8_1__filter_unfired q (MkAct t True :: xs) z | True = iret_8_1__filter_unfired q xs z
  iret_8_1__filter_unfired q (MkAct t True :: xs) z | False = iret_8_1__filter_unfired q xs z
iret_8_1__filter_unfired q (MkAct t False :: xs) z = absurd (iret_11_4__succ_not_zero _ z)

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| From a quiescent chain, the tick leaves unfired exactly the matches it
||| made, counted.
export
iret_19_5__tick_chain_unfired : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (t : Maybe Ltim_2_4_1__timed) -> (c : Nat) ->
                                (ch : Rlow_4_2_1__chain) -> iret_11_4__unfired (cacts ch) = 0 ->
                                iret_11_4__unfired (cacts (iret_19_5__tick_chain wm alphas t c ch)) = iret_19_5__born_chain wm alphas t c ch
iret_19_5__tick_chain_unfired wm alphas Nothing c ch q = q
iret_19_5__tick_chain_unfired wm alphas (Just tj) c (MkChain [] acts actions) q = q
iret_19_5__tick_chain_unfired wm alphas (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions) q =
  trans (iret_8_1__activate_unfired wm (iret_19_5__born j (tj c) (iret_6_6__mem_at alphas a) lm)
           (iret_8_1__end (iret_19_5__ended j (tj c) (iret_6_6__mem_at alphas a) lm) acts))
        (trans (cong (\x => length (iret_19_5__born j (tj c) (iret_6_6__mem_at alphas a) lm) + x)
                  (iret_8_1__filter_unfired _ acts q))
               (plusZeroRightNeutral _))
iret_19_5__tick_chain_unfired wm alphas (Just tj) c (MkChain [MkBeta a j True lm cs] acts actions) q = q
iret_19_5__tick_chain_unfired wm alphas (Just tj) c (MkChain (MkBeta a j False lm cs :: b2 :: rest) acts actions) q = q
iret_19_5__tick_chain_unfired wm alphas (Just tj) c (MkChain (MkBeta a j True lm cs :: b2 :: rest) acts actions) q = q

--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| And over the chains: from a quiescent state the tick leaves unfired
||| exactly what it made.
export
iret_19_5__tick_chains_unfired : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) ->
                                 (chains : List Rlow_4_2_1__chain) -> iret_11_4__unfired_count chains = 0 ->
                                 iret_11_4__unfired_count (iret_19_5__tick_chains wm alphas ts c chains) = iret_19_5__born_count wm alphas ts c chains
iret_19_5__tick_chains_unfired wm alphas [] c chains q = q
iret_19_5__tick_chains_unfired wm alphas (t :: ts) c [] q = Refl
iret_19_5__tick_chains_unfired wm alphas (t :: ts) c (ch :: chs) q =
  let (q1, q2) = iret_11_4__plus_zero (iret_11_4__unfired (cacts ch)) (iret_11_4__unfired_count chs) q
  in cong2 (+) (iret_19_5__tick_chain_unfired wm alphas t c ch q1) (iret_19_5__tick_chains_unfired wm alphas ts c chs q2)

--@derives [IRET.19.5]
||| The re-time changes a chain's test and activations, never its actions.
export
iret_19_5__tick_chain_actions : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (t : Maybe Ltim_2_4_1__timed) -> (c : Nat) ->
                                (ch : Rlow_4_2_1__chain) -> cactions (iret_19_5__tick_chain wm alphas t c ch) = cactions ch
iret_19_5__tick_chain_actions wm alphas Nothing c ch = Refl
iret_19_5__tick_chain_actions wm alphas (Just tj) c (MkChain [] acts actions) = Refl
iret_19_5__tick_chain_actions wm alphas (Just tj) c (MkChain [MkBeta a j False lm cs] acts actions) = Refl
iret_19_5__tick_chain_actions wm alphas (Just tj) c (MkChain [MkBeta a j True lm cs] acts actions) = Refl
iret_19_5__tick_chain_actions wm alphas (Just tj) c (MkChain (MkBeta a j False lm cs :: b2 :: rest) acts actions) = Refl
iret_19_5__tick_chain_actions wm alphas (Just tj) c (MkChain (MkBeta a j True lm cs :: b2 :: rest) acts actions) = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| So the tick keeps a program action-free.
export
ltim_2_5_1__action_free_tick : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (c : Nat) ->
                               (chains : List Rlow_4_2_1__chain) -> Ltim_2_5_1__action_free chains ->
                               Ltim_2_5_1__action_free (iret_19_5__tick_chains wm alphas ts c chains)
ltim_2_5_1__action_free_tick wm alphas [] c chains af = af
ltim_2_5_1__action_free_tick wm alphas (t :: ts) c [] af = af
ltim_2_5_1__action_free_tick wm alphas (t :: ts) c (ch :: chs) (p :: ps) =
  trans (iret_19_5__tick_chain_actions wm alphas t c ch) p :: ltim_2_5_1__action_free_tick wm alphas ts c chs ps

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| B1. THE PUMP FIRES THE BORN, on the composed engine: from a quiescent
||| action-free state with an empty dependency table and nothing expiring
||| at the new clock, the pump at a tick fires exactly as many times as the
||| tick made matches over every timed chain, halts `Quiescent`, and leaves
||| the state the tick made with every activation marked. Each born
||| activation fires once and none twice: "a rule whose only unmet gate is
||| a time-dependent condition must fire once the clock advances to
||| satisfy it", counted.
export
ltim_2_5_1__pump_fires_the_born : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (fuel : Nat) -> (t : Nat) ->
                                  (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                  (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                                  Ltim_2_5_1__action_free chains -> iret_11_4__unfired_count chains = 0 ->
                                  iret_19_3__expired (rarc_5_6_3__next_clock c t) dl = [] ->
                                  LT (iret_19_5__born_count wm al ts (rarc_5_6_3__next_clock c t) chains) fuel ->
                                  iret_19_5__pump_clocked pg ttl ts fuel (Tick t) (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) []) dl c)
                                    = ( MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al (idat_6_2_2__mark_all (iret_19_5__tick_chains wm al ts (rarc_5_6_3__next_clock c t) chains)))) []) dl (rarc_5_6_3__next_clock c t)
                                      , Quiescent, iret_19_5__born_count wm al ts (rarc_5_6_3__next_clock c t) chains )
ltim_2_5_1__pump_fires_the_born pg ttl ts fuel t wm al chains dl c af q noExp lt =
  let tk = the (iret_19_5__tick_clocked pg ttl ts t (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al chains)) []) dl c)
                  = MkClockedNet (MkTmsNet (iret_19_5__tick ts (rarc_5_6_3__next_clock c t) (MkEngine wm (MkNetwork al chains))) []) dl (rarc_5_6_3__next_clock c t))
               (trans (cong (iret_19_5__retime_clocked pg ts) (ldet_5_8__quiet_tick_net pg ttl t wm (MkNetwork al chains) [] dl c Refl noExp))
                      (ltim_2_7_2__no_cascade_is_the_retime pg ts (MkEngine wm (MkNetwork al chains)) [] dl (rarc_5_6_3__next_clock c t) Refl))
      ub = the (iret_11_4__unfired_count (iret_19_5__tick_chains wm al ts (rarc_5_6_3__next_clock c t) chains) = iret_19_5__born_count wm al ts (rarc_5_6_3__next_clock c t) chains)
               (iret_19_5__tick_chains_unfired wm al ts (rarc_5_6_3__next_clock c t) chains q)
      run = ltim_2_5_1__run_marks_all pg ttl fuel wm al (iret_19_5__tick_chains wm al ts (rarc_5_6_3__next_clock c t) chains) [] dl (rarc_5_6_3__next_clock c t)
              (ltim_2_5_1__action_free_tick wm al ts (rarc_5_6_3__next_clock c t) chains af)
              (replace {p = \n => LT n fuel} (sym ub) lt)
  in replace {p = \x => iret_11_4__run_ttl_net pg ttl fuel x
                          = ( MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al (idat_6_2_2__mark_all (iret_19_5__tick_chains wm al ts (rarc_5_6_3__next_clock c t) chains)))) []) dl (rarc_5_6_3__next_clock c t)
                            , Quiescent, iret_19_5__born_count wm al ts (rarc_5_6_3__next_clock c t) chains )}
       (sym tk)
       (replace {p = \n => iret_11_4__run_ttl_net pg ttl fuel (MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al (iret_19_5__tick_chains wm al ts (rarc_5_6_3__next_clock c t) chains))) []) dl (rarc_5_6_3__next_clock c t))
                              = ( MkClockedNet (MkTmsNet (MkEngine wm (MkNetwork al (idat_6_2_2__mark_all (iret_19_5__tick_chains wm al ts (rarc_5_6_3__next_clock c t) chains)))) []) dl (rarc_5_6_3__next_clock c t)
                                , Quiescent, n )}
          ub run)

-- ---------------------------------------------------------------------
-- B2: the counts are the edges
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
||| A gate on the clock alone, as a timed test: `now() > t`, a window, any
||| predicate of the clock.
public export
ltim_2_5_1__gate : (Nat -> Bool) -> Ltim_2_4_1__timed
ltim_2_5_1__gate g = \c, t, f => g c

--@spec [LTIM.2.5.1]
||| The one rule's activations when quiescent: the `Ping` match, fired, if
||| the gate is true; nothing if it is false.
public export
ltim_2_5_1__held_at : Bool -> List Iret_8_1__act
ltim_2_5_1__held_at True = [MkAct [ldet_5_8__ping] True]
ltim_2_5_1__held_at False = []

--@spec [LTIM.2.5.1]
||| ONE FACT, ONE RULE, ANY GATE: the clocked network holding one `Ping`,
||| one alpha admitting it, one chain whose single positive node carries
||| the gate at the clock, no actions, no dependency row, no deadline;
||| quiescent at clock `c`.
public export
ltim_2_5_1__one_rule : (Nat -> Bool) -> Nat -> Iret_19_3__clocked_net
ltim_2_5_1__one_rule g c =
  MkClockedNet (MkTmsNet (MkEngine [ldet_5_8__ping]
                                   (MkNetwork [MkAlpha 0 (\_ => True) [ldet_5_8__ping]]
                                              [MkChain [MkBeta 0 (ltim_2_5_1__gate g c) False [[]] []] (ltim_2_5_1__held_at (g c)) []]))
                         [])
               [] c

--@spec [LTIM.2.5.1]
||| ONE TICK'S EDGE: 1 where the gate is false at the clock before the tick
||| and true at the clock after it, else 0.
public export
ltim_2_5_1__edge_at : (Nat -> Bool) -> Nat -> Nat -> Nat
ltim_2_5_1__edge_at g c t = if not (g c) && g (rarc_5_6_3__next_clock c t) then 1 else 0

--@spec [LTIM.2.5.1]
||| THE RISING EDGES of a gate over a history of ticks from a starting
||| clock, one per tick.
public export
Ltim_2_5_1__edges : (Nat -> Bool) -> Nat -> List Nat -> List Nat
Ltim_2_5_1__edges g c [] = []
Ltim_2_5_1__edges g c (t :: ts) = ltim_2_5_1__edge_at g c t :: Ltim_2_5_1__edges g (rarc_5_6_3__next_clock c t) ts

--@derives [LTIM.2.5.1]
||| The one rule is quiescent at either value of the gate.
export
ltim_2_5_1__one_rule_quiescent : (nodes : List Iret_7_4__beta) -> (b : Bool) ->
                                 iret_11_4__unfired_count [MkChain nodes (ltim_2_5_1__held_at b) []] = 0
ltim_2_5_1__one_rule_quiescent nodes True = Refl
ltim_2_5_1__one_rule_quiescent nodes False = Refl

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.4.2]
||| What a tick makes of one fact and the nil token: one match if the gate
||| was false and is true, none otherwise.
export
ltim_2_5_1__born_edge : (b1, b2 : Bool) ->
                        length (iret_7_7__extend_front (\t, f => not b1 && b2) [ldet_5_8__ping] [[]]) = (if not b1 && b2 then 1 else 0)
ltim_2_5_1__born_edge True True = Refl
ltim_2_5_1__born_edge True False = Refl
ltim_2_5_1__born_edge False True = Refl
ltim_2_5_1__born_edge False False = Refl

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| What the tick and the run leave of the one rule's activations, from
||| quiescence at the old gate value: quiescence at the new one. A gate
||| that stays true keeps the fired match; one that closes ends it; one
||| that opens makes a new match, which the run fires.
export
ltim_2_5_1__one_rule_after : (b1, b2 : Bool) ->
                             map idat_6_2_2__mark_act
                               (iret_8_1__activate [ldet_5_8__ping]
                                  (iret_7_7__extend_front (\t, f => not b1 && b2) [ldet_5_8__ping] [[]])
                                  (iret_8_1__end (iret_7_7__extend_front (\t, f => b1 && not b2) [ldet_5_8__ping] [[]]) (ltim_2_5_1__held_at b1)))
                               = ltim_2_5_1__held_at b2
ltim_2_5_1__one_rule_after True True = Refl
ltim_2_5_1__one_rule_after True False = Refl
ltim_2_5_1__one_rule_after False True = Refl
ltim_2_5_1__one_rule_after False False = Refl

--@derives [LTIM.2.5.1]
||| An edge count is below any fuel of two or more.
export
ltim_2_5_1__edge_lt : (b : Bool) -> (k : Nat) -> LT (if b then 1 else 0) (S (S k))
ltim_2_5_1__edge_lt True k = LTESucc (LTESucc LTEZero)
ltim_2_5_1__edge_lt False k = LTESucc LTEZero

--@derives [IRET.19.5]
||| One pump of a sequence, unfolded: its count, then the counts from the
||| state it left. The second component of Rete/NetworkClocked.idr's
||| `iret_19_5__run_clocked_cons`.
export
iret_19_5__counts_clocked_cons : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (fuel : Nat) ->
                                 (inp : Rarc_5_6_2__input) -> (inps : List Rarc_5_6_2__input) -> (cs, cs' : Iret_19_3__clocked_net) ->
                                 (h : Iret_11_4__halt) -> (n : Nat) ->
                                 iret_19_5__pump_clocked pg ttl ts fuel inp cs = (cs', h, n) ->
                                 iret_19_5__counts_clocked pg ttl ts fuel (inp :: inps) cs = n :: iret_19_5__counts_clocked pg ttl ts fuel inps cs'
iret_19_5__counts_clocked_cons pg ttl ts fuel inp inps cs cs' h n eq = cong snd (iret_19_5__run_clocked_cons pg ttl ts fuel inp inps cs cs' h n eq)

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.4.2]
||| The matches the tick makes of the one rule are its edge.
export
ltim_2_5_1__one_rule_born : (g : Nat -> Bool) -> (c, t : Nat) ->
                            iret_19_5__born_count [ldet_5_8__ping] [MkAlpha 0 (\_ => True) [ldet_5_8__ping]] [Just (ltim_2_5_1__gate g)] (rarc_5_6_3__next_clock c t)
                              [MkChain [MkBeta 0 (ltim_2_5_1__gate g c) False [[]] []] (ltim_2_5_1__held_at (g c)) []]
                              = ltim_2_5_1__edge_at g c t
ltim_2_5_1__one_rule_born g c t = trans (plusZeroRightNeutral _) (ltim_2_5_1__born_edge (g c) (g (rarc_5_6_3__next_clock c t)))

--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| The one rule after the tick and the run: the one rule at the new clock.
export
ltim_2_5_1__one_rule_tick : (g : Nat -> Bool) -> (c, t : Nat) ->
                            idat_6_2_2__mark_all (iret_19_5__tick_chains [ldet_5_8__ping] [MkAlpha 0 (\_ => True) [ldet_5_8__ping]] [Just (ltim_2_5_1__gate g)] (rarc_5_6_3__next_clock c t)
                                                    [MkChain [MkBeta 0 (ltim_2_5_1__gate g c) False [[]] []] (ltim_2_5_1__held_at (g c)) []])
                              = [MkChain [MkBeta 0 (ltim_2_5_1__gate g (rarc_5_6_3__next_clock c t)) False [[]] []] (ltim_2_5_1__held_at (g (rarc_5_6_3__next_clock c t))) []]
ltim_2_5_1__one_rule_tick g c t =
  cong (\as => [MkChain [MkBeta 0 (ltim_2_5_1__gate g (rarc_5_6_3__next_clock c t)) False [[]] []] as []])
       (ltim_2_5_1__one_rule_after (g c) (g (rarc_5_6_3__next_clock c t)))

--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| ONE PUMP OF THE ONE RULE: from the quiescent state at a clock, the pump
||| at a tick fires the edge and leaves the quiescent state at the new
||| clock.
export
ltim_2_5_1__one_rule_pump : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (g : Nat -> Bool) -> (k : Nat) -> (c, t : Nat) ->
                            iret_19_5__pump_clocked pg ttl [Just (ltim_2_5_1__gate g)] (S (S k)) (Tick t) (ltim_2_5_1__one_rule g c)
                              = (ltim_2_5_1__one_rule g (rarc_5_6_3__next_clock c t), Quiescent, ltim_2_5_1__edge_at g c t)
ltim_2_5_1__one_rule_pump pg ttl g k c t =
  trans (ltim_2_5_1__pump_fires_the_born pg ttl [Just (ltim_2_5_1__gate g)] (S (S k)) t
           [ldet_5_8__ping] [MkAlpha 0 (\_ => True) [ldet_5_8__ping]]
           [MkChain [MkBeta 0 (ltim_2_5_1__gate g c) False [[]] []] (ltim_2_5_1__held_at (g c)) []] [] c
           (Refl :: Nil) (ltim_2_5_1__one_rule_quiescent [MkBeta 0 (ltim_2_5_1__gate g c) False [[]] []] (g c)) Refl
           (replace {p = \n => LT n (S (S k))} (sym (ltim_2_5_1__one_rule_born g c t))
                    (ltim_2_5_1__edge_lt (not (g c) && g (rarc_5_6_3__next_clock c t)) k)))
        (cong2 (\chs, n => (MkClockedNet (MkTmsNet (MkEngine [ldet_5_8__ping] (MkNetwork [MkAlpha 0 (\_ => True) [ldet_5_8__ping]] chs)) []) [] (rarc_5_6_3__next_clock c t), Quiescent, n))
               (ltim_2_5_1__one_rule_tick g c t) (ltim_2_5_1__one_rule_born g c t))

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.4.2]
--@derives [IRET.19.5]
||| B2. THE COUNTS ARE THE EDGES: for one fact and one rule under any gate
||| on the clock, with no actions and no deadline, the firings of ANY
||| sequence of ticks from ANY starting clock are the gate's rising edges
||| over that history, one count per pump. "Once per false-to-true edge",
||| for every gate and every history. A gate that stays true once true
||| fires once; a window that shuts and reopens fires once per opening.
export
ltim_2_5_1__counts_are_edges : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (g : Nat -> Bool) -> (k : Nat) -> (c : Nat) -> (ticks : List Nat) ->
                               iret_19_5__counts_clocked pg ttl [Just (ltim_2_5_1__gate g)] (S (S k)) (map Tick ticks) (ltim_2_5_1__one_rule g c)
                                 = Ltim_2_5_1__edges g c ticks
ltim_2_5_1__counts_are_edges pg ttl g k c [] = Refl
ltim_2_5_1__counts_are_edges pg ttl g k c (t :: ts) =
  trans (iret_19_5__counts_clocked_cons pg ttl [Just (ltim_2_5_1__gate g)] (S (S k)) (Tick t) (map Tick ts)
           (ltim_2_5_1__one_rule g c) (ltim_2_5_1__one_rule g (rarc_5_6_3__next_clock c t)) Quiescent
           (ltim_2_5_1__edge_at g c t) (ltim_2_5_1__one_rule_pump pg ttl g k c t))
        (cong (ltim_2_5_1__edge_at g c t ::) (ltim_2_5_1__counts_are_edges pg ttl g k (rarc_5_6_3__next_clock c t) ts))

-- ---------------------------------------------------------------------
-- Part A's witness, as an instance
-- ---------------------------------------------------------------------

--@derives [LTIM.2.5.1]
||| The window of Rete/NetworkClocked.idr, loaded and holding its `Ping` at
||| clock 0, is the one-rule state under the window gate.
export
ltim_2_5_1__window_start_is_one_rule : ltim_2_5_1__window_start = ltim_2_5_1__one_rule ltim_2_5_1__window 0
ltim_2_5_1__window_start_is_one_rule = Refl

--@derives [LTIM.2.5.1]
||| The window's edges over ticks to 1, 2, 3, 4 are `[1, 0, 1, 0]`.
export
ltim_2_5_1__window_edges : Ltim_2_5_1__edges ltim_2_5_1__window 0 [1, 2, 3, 4] = [1, 0, 1, 0]
ltim_2_5_1__window_edges = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| PART A'S `[1, 0, 1, 0]` IS AN INSTANCE OF B2: the executed witness of
||| Rete/NetworkClocked.idr is the edge theorem at the window gate, from
||| clock 0, over the ticks 1, 2, 3, 4.
export
ltim_2_5_1__second_edge_refires_is_an_instance :
  iret_19_5__counts_clocked ltim_2_5_1__window_program (\_ => 0) [Just ltim_2_5_1__window_gate] 10 [Tick 1, Tick 2, Tick 3, Tick 4] ltim_2_5_1__window_start
    = Ltim_2_5_1__edges ltim_2_5_1__window 0 [1, 2, 3, 4]
ltim_2_5_1__second_edge_refires_is_an_instance = ltim_2_5_1__counts_are_edges ltim_2_5_1__window_program (\_ => 0) ltim_2_5_1__window 8 0 [1, 2, 3, 4]

-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| ONCE PER MATCH: a pump fires each match of each rule exactly once,
||| whatever the shape of the rule and however its facts arrived.
|||
||| NORMATIVE COMPANION to Rete/NetworkEdges.idr, which it stands on.
|||
||| WHY. A duplicate firing of one activation has been reported of libds: a
||| six-pattern self-join over one schema (a word square, every fact both a row
||| and a column) firing 29909 times on a hundred facts where there are 29908
||| matches, the extra firing repeating a match whose single facts fill two
||| patterns each. The corpus forbids it three times over. [IRET.7.7]'s
||| join algorithm builds each match once, and [IRET.11.1] says why no two
||| activations of one rule can share a timetag: a timetag is assigned per
||| token and a token reaches exactly one terminal. [IRET.11.3] keys
||| refraction by the tuple of participating fact ids, so even a second
||| record of one match is the same identity and is filtered at selection
||| ([IRET.11.3.1], [LDET.5.3]). And RARC.5.4.9 makes two activations with
||| one ordinal and one timetag an unrecoverable fault. The lane proved the
||| first already: after any history every terminal holds exactly the
||| recompute over working memory, none twice (Rete/NetworkDispatch.idr's
||| view theorem), for a chain of any shape -- six nodes fed by one alpha
||| included, since `iret_7_7__right_activate` activates the nodes an alpha
||| feeds deepest first so that a token the shallower activation creates
||| never meets its own fact twice. What that leaves unstated is that a pump
||| FIRES once per match. This module states it as the composition of the
||| view theorem with Rete/NetworkEdges.idr's run lemma.
|||
||| PROVED.
|||
|||   * EVERY ACTIVATION IS UNFIRED UNTIL A PUMP (`Iret_11_3__unfired_all`
|||     kept by `rarc_5_6_4__applied`): from the loaded network, inputs
|||     applied with no pump between them -- asserts under any lifecycle,
|||     retractions -- create activations unfired and fire none. From the
|||     flag lemmas of Rete/NetworkTransferFlags.idr.
|||   * THE RUN IS ONE MARK PER UNFIRED ACTIVATION, on the plain network
|||     (`iret_11_4__run_net_marks_all`): Rete/NetworkEdges.idr's B0, restated
|||     on `iret_11_4__run_net`. The same forty-line induction; the clocked
|||     copy stays, since each unfolds a different run.
|||   * THE THEOREM (`iret_11_3__pump_fires_once_per_match`): for an
|||     action-free program, from the loaded network, after any inputs with
|||     no pump between them, a pump with fuel enough halts `Quiescent`,
|||     fires exactly as many times as there are activations, leaves every
|||     activation fired with its tuple, and every chain's tuples are
|||     exactly its recompute over working memory, none twice. And the
|||     COUNT (`iret_11_3__fires_the_match_count`): the firings are the
|||     number of distinct matches, summed over the rules -- two distinct
|||     lists with the same members have one length
|||     (`iret_11_3__distinct_same_set_length`).
|||   * EXECUTED: the symmetric square. Three `Word` facts whose letters
|||     make each a row and the matching column, with a fourth that
|||     completes nothing, under the six-pattern rule in two
|||     pattern orders, rows first and interleaved. One match, one firing,
|||     the one tuple, in both (`iret_7_7__word_square_fires_once`,
|||     `iret_7_7__word_square_interleaved_fires_once`). The hundred-fact
|||     stream is beyond a `Refl`; the theorem covers it.
|||   * EXECUTED, THE OTHER WAYS IN: the square asserts four `Explicit`
|||     facts, so the lifecycle cases of `iret_11_3__assert_unfired` and
|||     the retraction cases of `iret_11_3__apply_unfired` are run on a
|||     one-row rule: a relation asserted twice, an entity asserted twice
|||     with one payload, an entity asserted twice with a changed payload
|||     (the replace of [LFAC.2.5.3], its fresh wrapper's activation unfired
|||     before the pump), and a retraction between asserts with a retraction
|||     of nothing after it. One firing each.
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. The program is
||| action-free (every rule only logs): a step with actions
||| changes other chains through the alphas, and the general frame is
||| the clocked-network programme's part B'. The inputs arrive with no pump between them;
||| the canonical cadence (an input, then a pump) is
||| the view theorem's and B1's. The join tests of the executed square
||| are a transcription: letters are a table on
||| the fact's payload, since the model's fact carries one payload. Nothing
||| here says what libds does.
module Rete.NetworkOnce

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.NetworkOrderKeep
import Rete.NetworkRefraction
import Rete.NetworkTransfer
import Rete.NetworkTransferFlags
import Rete.TmsBridge
import Rete.RunFold
import Rete.NetworkEdges
import Lcyc.Lemmas
import Lcyc.Termination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- Inputs with no pump between them; the activations, counted
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.4]
||| INPUTS APPLIED WITH NO PUMP BETWEEN THEM: a hundred
||| asserts then one pump. The canonical cadence pumps after each; this one
||| lets the activations accumulate.
public export
rarc_5_6_4__applied : (Nat -> Lscp_1_3__lifecycle) -> List Rarc_5_6_1__event -> Iret_19__engine -> Iret_19__engine
rarc_5_6_4__applied life [] eng = eng
rarc_5_6_4__applied life (ev :: evs) eng = rarc_5_6_4__applied life evs (rarc_5_6_4__apply_net life ev eng)

--@spec [IRET.11.3]
||| EVERY ACTIVATION UNFIRED, over every chain: what the agenda holds
||| before any pump has run.
public export
Iret_11_3__unfired_all : List Rlow_4_2_1__chain -> Type
Iret_11_3__unfired_all chains = All (\c => (a : Iret_8_1__act) -> Elem a (cacts c) -> afired a = False) chains

--@spec [IRET.11.1]
||| THE ACTIVATIONS, counted over every chain.
public export
iret_11_1__act_count : List Rlow_4_2_1__chain -> Nat
iret_11_1__act_count [] = 0
iret_11_1__act_count (c :: cs) = length (cacts c) + iret_11_1__act_count cs

--@spec [RARC.5.6.5]
||| THE MATCHES, counted: the recompute of every chain over working memory.
public export
rarc_5_6_5__match_count : List Iret_6_1__alpha -> Rarc_5_6_4__wm -> List Rlow_4_2_1__chain -> Nat
rarc_5_6_5__match_count al wm [] = 0
rarc_5_6_5__match_count al wm (c :: cs) = length (iret_7_7__view al wm (cnodes c) [[]]) + rarc_5_6_5__match_count al wm cs

-- ---------------------------------------------------------------------
-- Small lemmas
-- ---------------------------------------------------------------------

--@derives [IRET.11.3]
||| A property of every indexed member is a property of every member.
export
iret_11_3__all_of_nth : {a : Type} -> {p : a -> Type} -> (xs : List a) ->
                        ((i : Nat) -> (x : a) -> rarc_5_6_5__nth i xs = Just x -> p x) -> All p xs
iret_11_3__all_of_nth [] f = []
iret_11_3__all_of_nth (x :: xs) f = f Z x Refl :: iret_11_3__all_of_nth xs (\i, y, e => f (S i) y e)

--@derives [IRET.11.4]
||| A run from a state with nothing selected: the state, quiescent, no
||| firing. Rete/RunFold.idr's `iret_11_4__run_by_nothing` through
||| Rete/NetworkRefraction.idr's bridge `iret_11_4__run_net_by`;
||| Rete/NetworkTransfer.idr's `iret_11_4__run_net_quiet` is the same fact
||| read on the engine alone, from the same two.
export
iret_11_4__run_net_nothing : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) ->
                             iret_11_4__step_net life eng = Nothing -> iret_11_4__run_net life (S fuel) eng = (eng, Quiescent, 0)
iret_11_4__run_net_nothing life fuel eng eq =
  trans (iret_11_4__run_net_by life (S fuel) eng) (iret_11_4__run_by_nothing (iret_11_4__step_net life) fuel eng eq)

--@derives [IRET.11.4]
||| A run that fires is the firing then the rest, one more firing counted.
||| RunFold's `iret_11_4__run_by_just` through the bridge.
export
iret_11_4__run_net_just : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng, eng' : Iret_19__engine) ->
                          iret_11_4__step_net life eng = Just eng' ->
                          (t : Iret_19__engine) -> (h : Iret_11_4__halt) -> (n : Nat) -> iret_11_4__run_net life fuel eng' = (t, h, n) ->
                          iret_11_4__run_net life (S fuel) eng = (t, h, S n)
iret_11_4__run_net_just life fuel eng eng' eq t h n rr =
  trans (iret_11_4__run_net_by life (S fuel) eng)
        (iret_11_4__run_by_just (iret_11_4__step_net life) fuel eng eng' eq t h n (trans (sym (iret_11_4__run_net_by life fuel eng')) rr))

-- ---------------------------------------------------------------------
-- Every activation is unfired until a pump
-- ---------------------------------------------------------------------

--@derives [IRET.11.3]
--@derives [IRET.19.1]
||| INSERTING A FRESH FACT keeps every activation unfired: what it creates
||| is unfired, what it keeps was.
export
iret_11_3__insert_unfired : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Not (Elem f (ewm eng)) -> Iret_19__view eng ->
                            Iret_11_3__unfired_all (nchains (enet eng)) -> Iret_11_3__unfired_all (nchains (enet (iret_19_1__insert f eng)))
iret_11_3__insert_unfired f eng nf v u =
  iret_11_3__all_of_nth (nchains (enet (iret_19_1__insert f eng))) (\i, c', n', a', ea' =>
    let (c ** n) = lcyc_1_1__nth_length i (nchains (enet eng)) (nchains (enet (iret_19_1__insert f eng)))
                     (iret_6_4__dispatch_assert_length (ewm eng ++ [f]) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)) n'
    in case fst (iret_19_1__insert_flags f eng nf v i c c' n n') a' ea' of
         Left old => lcyc_1_1__all_lookup u (lcyc_1_1__nth_elem i (nchains (enet eng)) n) a' old
         Right (_, nf') => nf')

--@derives [IRET.11.3]
--@derives [IRET.19.2]
||| RETRACTING A LIVE FACT keeps every activation unfired: a retraction
||| creates nothing fired and keeps what survives as it was.
export
iret_11_3__retract_unfired : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Elem f (ewm eng) -> Iret_19__view eng ->
                             Iret_11_3__unfired_all (nchains (enet eng)) -> Iret_11_3__unfired_all (nchains (enet (iret_19_2__retract f eng)))
iret_11_3__retract_unfired f eng ef v u =
  iret_11_3__all_of_nth (nchains (enet (iret_19_2__retract f eng))) (\i, c', n', a', ea' =>
    let (c ** n) = lcyc_1_1__nth_length i (nchains (enet eng)) (nchains (enet (iret_19_2__retract f eng)))
                     (iret_19_2__dispatch_retract_length (ewm eng) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)) n'
    in case fst (iret_19_2__retract_flags f eng ef v i c c' n n') a' ea' of
         Left old => lcyc_1_1__all_lookup u (lcyc_1_1__nth_elem i (nchains (enet eng)) n) a' old
         Right nf' => nf')

--@derives [IRET.11.3]
--@derives [IRET.19.1]
--@derives [LFAC.2.5.1]
--@derives [LFAC.2.5.3]
||| ASSERT UNDER THE LIFECYCLE keeps every activation unfired: a no-op
||| changes nothing, an insert is of a fresh fact, a replace retracts a live
||| fact then inserts a fresh one. The cases of Rete/NetworkDispatch.idr's
||| `iret_19_1__assert_view`.
export
iret_11_3__assert_unfired : (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) ->
                            Iret_19__view eng -> Iret_11_3__unfired_all (nchains (enet eng)) ->
                            Iret_11_3__unfired_all (nchains (enet (iret_19_1__assert life avoid k key pay eng)))
iret_11_3__assert_unfired life avoid k key pay eng v u with (life k)
  iret_11_3__assert_unfired life avoid k key pay eng v u | Explicit =
    iret_11_3__insert_unfired _ eng (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) v u
  iret_11_3__assert_unfired life avoid k key pay eng v u | Relation with (iret_19_1__find_relation k key pay (ewm eng))
    iret_11_3__assert_unfired life avoid k key pay eng v u | Relation | (Just old) = u
    iret_11_3__assert_unfired life avoid k key pay eng v u | Relation | Nothing =
      iret_11_3__insert_unfired _ eng (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) v u
  iret_11_3__assert_unfired life avoid k key pay eng v u | Entity with (iret_19_1__find_entity k key (ewm eng)) proof fe
    iret_11_3__assert_unfired life avoid k key pay eng v u | Entity | Nothing =
      iret_11_3__insert_unfired _ eng (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) v u
    iret_11_3__assert_unfired life avoid k key pay eng v u | Entity | (Just old) with (fpay old == pay)
      iret_11_3__assert_unfired life avoid k key pay eng v u | Entity | (Just old) | True = u
      iret_11_3__assert_unfired life avoid k key pay eng v u | Entity | (Just old) | False =
        iret_11_3__insert_unfired _ (iret_19_2__retract old eng)
          (\e => lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay (fst (rarc_5_6_4__remove_exact_elem_inv old (ewm eng) _ e)))
          (iret_19_2__retract_view old eng (snd (lcyc_1_1__find_just _ (ewm eng) fe)) v)
          (iret_11_3__retract_unfired old eng (snd (lcyc_1_1__find_just _ (ewm eng) fe)) v u)

--@derives [IRET.11.3]
--@derives [RARC.5.6.4]
||| AN INPUT keeps every activation unfired.
export
iret_11_3__apply_unfired : (life : Nat -> Lscp_1_3__lifecycle) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                           Iret_19__view eng -> Iret_11_3__unfired_all (nchains (enet eng)) ->
                           Iret_11_3__unfired_all (nchains (enet (rarc_5_6_4__apply_net life ev eng)))
iret_11_3__apply_unfired life (Assert k key pay) eng v u = iret_11_3__assert_unfired life [] k key pay eng v u
iret_11_3__apply_unfired life (Retract i) eng v u with (rarc_5_6_4__lookup_fact i (ewm eng)) proof lk
  iret_11_3__apply_unfired life (Retract i) eng v u | Nothing = u
  iret_11_3__apply_unfired life (Retract i) eng v u | (Just f) =
    iret_11_3__retract_unfired f eng (fst (rarc_5_6_4__lookup_elem i (ewm eng) f lk)) v u

--@derives [RARC.5.6.4]
||| Inputs with no pump between them keep the view.
export
rarc_5_6_4__applied_view : (life : Nat -> Lscp_1_3__lifecycle) -> (evs : List Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                           Iret_19__view eng -> Iret_19__view (rarc_5_6_4__applied life evs eng)
rarc_5_6_4__applied_view life [] eng v = v
rarc_5_6_4__applied_view life (ev :: evs) eng v =
  rarc_5_6_4__applied_view life evs (rarc_5_6_4__apply_net life ev eng) (rarc_5_6_4__apply_net_view life ev eng v)

--@derives [IRET.11.3]
--@derives [RARC.5.6.4]
||| And keep every activation unfired.
export
iret_11_3__applied_unfired : (life : Nat -> Lscp_1_3__lifecycle) -> (evs : List Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                             Iret_19__view eng -> Iret_11_3__unfired_all (nchains (enet eng)) ->
                             Iret_11_3__unfired_all (nchains (enet (rarc_5_6_4__applied life evs eng)))
iret_11_3__applied_unfired life [] eng v u = u
iret_11_3__applied_unfired life (ev :: evs) eng v u =
  iret_11_3__applied_unfired life evs (rarc_5_6_4__apply_net life ev eng) (rarc_5_6_4__apply_net_view life ev eng v) (iret_11_3__apply_unfired life ev eng v u)

--@derives [RDSC.4a.5]
--@derives [IRET.11.3]
||| THE LOADED NETWORK holds unfired activations only: each root's seeding
||| wave creates, and what it creates is unfired.
export
rdsc_4a_5__load_unfired_from : (al : List Iret_6_1__alpha) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                               Iret_11_3__unfired_all (map (rdsc_4a_5__seed al) (map iret_16_6__terminal rules))
rdsc_4a_5__load_unfired_from al [] = []
rdsc_4a_5__load_unfired_from al (r :: rs) = (\a, e => rdsc_4a_5__seed_unfired al r a e) :: rdsc_4a_5__load_unfired_from al rs

--@derives [RDSC.4a.5]
--@derives [IRET.11.3]
export
rdsc_4a_5__load_unfired : (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                          Iret_11_3__unfired_all (nchains (enet (rdsc_4a_5__load alphas rules)))
rdsc_4a_5__load_unfired alphas rules = rdsc_4a_5__load_unfired_from (iret_16_4__alpha_nodes alphas) rules

-- ---------------------------------------------------------------------
-- The unfired count is the activation count, when all are unfired
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
||| A terminal of unfired activations has as many unfired as activations.
export
iret_11_4__unfired_is_length : (acts : List Iret_8_1__act) -> ((a : Iret_8_1__act) -> Elem a acts -> afired a = False) ->
                               iret_11_4__unfired acts = length acts
iret_11_4__unfired_is_length [] u = Refl
iret_11_4__unfired_is_length (MkAct t True :: as) u = absurd (u (MkAct t True) Here)
iret_11_4__unfired_is_length (MkAct t False :: as) u = cong S (iret_11_4__unfired_is_length as (\a, e => u a (There e)))

--@derives [IRET.11.4]
--@derives [IRET.11.1]
||| And over the chains.
export
iret_11_4__unfired_count_is_act_count : (chains : List Rlow_4_2_1__chain) -> Iret_11_3__unfired_all chains ->
                                        iret_11_4__unfired_count chains = iret_11_1__act_count chains
iret_11_4__unfired_count_is_act_count [] u = Refl
iret_11_4__unfired_count_is_act_count (c :: cs) (uc :: ucs) =
  cong2 (+) (iret_11_4__unfired_is_length (cacts c) uc) (iret_11_4__unfired_count_is_act_count cs ucs)

-- ---------------------------------------------------------------------
-- The run is one mark per unfired activation, on the plain network
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
--@derives [IRET.11.5]
--@derives [LDET.5.3]
||| THE RUN IS ONE MARK PER UNFIRED ACTIVATION, on the plain network: under
||| an action-free program, with fuel above the number of unfired
||| activations, the run halts `Quiescent`, fires exactly that many times,
||| and leaves every activation of every chain marked -- working memory,
||| the alphas, the nodes and the tuples as they were. Rete/NetworkEdges.idr's
||| B0, on `iret_11_4__run_net`.
export
iret_11_4__run_net_marks_all : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) ->
                               (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                               Ltim_2_5_1__action_free chains -> LT (iret_11_4__unfired_count chains) fuel ->
                               iret_11_4__run_net life fuel (MkEngine wm (MkNetwork al chains))
                                 = (MkEngine wm (MkNetwork al (idat_6_2_2__mark_all chains)), Quiescent, iret_11_4__unfired_count chains)
iret_11_4__run_net_marks_all life Z wm al chains af lt = absurd lt
iret_11_4__run_net_marks_all life (S k) wm al chains af lt = case iret_11_1__select_cases chains of
  Left sel =>
    let z = iret_11_1__select_nothing chains sel
    in trans (iret_11_4__run_net_nothing life k (MkEngine wm (MkNetwork al chains))
                (iret_11_4__step_net_quiet life (MkEngine wm (MkNetwork al chains)) sel))
             (cong2 (\chs, n => (MkEngine wm (MkNetwork al chs), Quiescent, n))
                    (sym (idat_6_2_2__mark_all_fired chains z)) (sym z))
  Right (r ** j ** sel) =>
    let (ch ** a ** (nt, nj, nf)) = iret_11_1__select_just chains r j sel
        ac = the (cactions ch = []) (lcyc_1_1__all_lookup af (lcyc_1_1__nth_elem r chains nt))
        st = the (iret_11_4__step_net life (MkEngine wm (MkNetwork al chains))
                    = Just (MkEngine wm (MkNetwork al (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains))))
                 (trans (iret_11_4__step_net_fires life (MkEngine wm (MkNetwork al chains)) r j ch a sel nt nj)
                        (cong (\acts => Just (rarc_5_6_7__do_actions_net life (atuple a) acts
                                                (idat_6_2_2__mark_net r j (MkEngine wm (MkNetwork al chains))))) ac))
        dec = the (S (iret_11_4__unfired_count (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains)) = iret_11_4__unfired_count chains)
                  (idat_6_2_2__mark_net_count r j chains ch a nt nj nf)
        lt' = the (LT (iret_11_4__unfired_count (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains)) k)
                  (fromLteSucc (replace {p = \n => LTE (S n) (S k)} (sym dec) lt))
        ih = iret_11_4__run_net_marks_all life k wm al (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains)
               (ltim_2_5_1__action_free_mark r j chains af) lt'
        rj = iret_11_4__run_net_just life k
               (MkEngine wm (MkNetwork al chains))
               (MkEngine wm (MkNetwork al (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains)))
               st _ _ _ ih
    in trans rj (cong2 (\chs, n => (MkEngine wm (MkNetwork al chs), Quiescent, n))
                       (idat_6_2_2__mark_all_set_at r j chains) dec)

-- ---------------------------------------------------------------------
-- Two distinct lists with the same members have one length
-- ---------------------------------------------------------------------

--@derives [IRET.11.3]
||| A token taken out of a list.
export
iret_11_3__drop : Iret_7_1__token -> List Iret_7_1__token -> List Iret_7_1__token
iret_11_3__drop t ys = filter (\u => not (u == t)) ys

--@derives [IRET.11.3]
||| Taking out a token that is not there changes nothing.
export
iret_11_3__drop_none : (t : Iret_7_1__token) -> (ys : List Iret_7_1__token) -> Not (Elem t ys) -> iret_11_3__drop t ys = ys
iret_11_3__drop_none t [] ne = Refl
iret_11_3__drop_none t (y :: ys) ne with (y == t) proof ey
  iret_11_3__drop_none t (y :: ys) ne | True = absurd (ne (rewrite sym (iret_11_3__tok_eq y t ey) in Here))
  iret_11_3__drop_none t (y :: ys) ne | False = cong (y ::) (iret_11_3__drop_none t ys (\e => ne (There e)))

--@derives [IRET.11.3]
||| A member of a list whose head tests unequal to it is in the tail.
export
iret_11_3__elem_cons_neq : (y, t : Iret_7_1__token) -> (ys : List Iret_7_1__token) -> (y == t) = False -> Elem t (y :: ys) -> Elem t ys
iret_11_3__elem_cons_neq y _ ys ne Here = absurd (trans (sym ne) (iret_11_3__tok_eq_refl y))
iret_11_3__elem_cons_neq y t ys ne (There e) = e

--@derives [IRET.11.3]
||| Two equal tokens test equal.
export
iret_11_3__tok_eq_of : (x, t : Iret_7_1__token) -> x = t -> (x == t) = True
iret_11_3__tok_eq_of x _ Refl = iret_11_3__tok_eq_refl x

--@derives [IRET.11.3]
||| Taking out a member of a distinct list shortens it by one.
export
iret_11_3__drop_length : (t : Iret_7_1__token) -> (ys : List Iret_7_1__token) -> Iret_11_3__distinct ys -> Elem t ys ->
                         S (length (iret_11_3__drop t ys)) = length ys
iret_11_3__drop_length t (y :: ys) (DCons ny dys) e with (y == t) proof ey
  iret_11_3__drop_length t (y :: ys) (DCons ny dys) e | True =
    cong S (cong length (iret_11_3__drop_none t ys (\e' => ny (rewrite iret_11_3__tok_eq y t ey in e'))))
  iret_11_3__drop_length t (y :: ys) (DCons ny dys) e | False =
    cong S (iret_11_3__drop_length t ys dys (iret_11_3__elem_cons_neq y t ys ey e))

--@derives [IRET.11.3]
||| A member other than the one taken out is still there.
export
iret_11_3__drop_elem_fwd : (t, x : Iret_7_1__token) -> (ys : List Iret_7_1__token) -> Elem x ys -> Not (x = t) -> Elem x (iret_11_3__drop t ys)
iret_11_3__drop_elem_fwd t x (y :: ys) e nx with (y == t) proof ey
  iret_11_3__drop_elem_fwd t x (y :: ys) e nx | True = case iret_11_3__elem_cons e of
    Left xy => absurd (nx (trans xy (iret_11_3__tok_eq y t ey)))
    Right e' => iret_11_3__drop_elem_fwd t x ys e' nx
  iret_11_3__drop_elem_fwd t x (y :: ys) e nx | False = case iret_11_3__elem_cons e of
    Left xy => rewrite xy in Here
    Right e' => There (iret_11_3__drop_elem_fwd t x ys e' nx)

--@derives [IRET.11.3]
||| What is left was there, and is not the one taken out.
export
iret_11_3__drop_elem_inv : (t, x : Iret_7_1__token) -> (ys : List Iret_7_1__token) -> Elem x (iret_11_3__drop t ys) -> (Elem x ys, Not (x = t))
iret_11_3__drop_elem_inv t x [] e = absurd e
iret_11_3__drop_elem_inv t x (y :: ys) e with (y == t) proof ey
  iret_11_3__drop_elem_inv t x (y :: ys) e | True =
    let (e', nx) = iret_11_3__drop_elem_inv t x ys e in (There e', nx)
  iret_11_3__drop_elem_inv t x (y :: ys) e | False = case iret_11_3__elem_cons e of
    Left xy => (rewrite xy in Here, \xt => absurd (trans (sym ey) (iret_11_3__tok_eq_of y t (trans (sym xy) xt))))
    Right e' => let (e'', nx) = iret_11_3__drop_elem_inv t x ys e' in (There e'', nx)

--@derives [IRET.11.3]
||| Taking a token out of a distinct list leaves a distinct list.
export
iret_11_3__drop_distinct : (t : Iret_7_1__token) -> (ys : List Iret_7_1__token) -> Iret_11_3__distinct ys -> Iret_11_3__distinct (iret_11_3__drop t ys)
iret_11_3__drop_distinct t [] d = d
iret_11_3__drop_distinct t (y :: ys) (DCons ny dys) with (y == t)
  iret_11_3__drop_distinct t (y :: ys) (DCons ny dys) | True = iret_11_3__drop_distinct t ys dys
  iret_11_3__drop_distinct t (y :: ys) (DCons ny dys) | False =
    DCons (\e => ny (fst (iret_11_3__drop_elem_inv t y ys e))) (iret_11_3__drop_distinct t ys dys)

--@derives [IRET.11.3]
--@derives [IRET.11.1]
||| TWO DISTINCT LISTS WITH THE SAME MEMBERS HAVE ONE LENGTH: a terminal
||| that holds each match once holds as many activations as there are
||| matches.
export
iret_11_3__distinct_same_set_length : (xs, ys : List Iret_7_1__token) -> Iret_11_3__distinct xs -> Iret_11_3__distinct ys ->
                                      Iret_7_4__same_set xs ys -> length xs = length ys
iret_11_3__distinct_same_set_length [] [] dx dy ss = Refl
iret_11_3__distinct_same_set_length [] (y :: ys) dx dy ss = absurd (snd (ss y) Here)
iret_11_3__distinct_same_set_length (x :: xs) ys (DCons nx dxs) dy ss =
  let ex = the (Elem x ys) (fst (ss x) Here)
      ss' = the (Iret_7_4__same_set xs (iret_11_3__drop x ys)) (\z =>
              ( \ez => iret_11_3__drop_elem_fwd x z ys (fst (ss z) (There ez)) (\zx => nx (rewrite sym zx in ez))
              , \ez => let (ey, nz) = iret_11_3__drop_elem_inv x z ys ez
                       in case iret_11_3__elem_cons (snd (ss z) ey) of
                            Left zx => absurd (nz zx)
                            Right ez' => ez' ))
      ih = iret_11_3__distinct_same_set_length xs (iret_11_3__drop x ys) dxs (iret_11_3__drop_distinct x ys dy) ss'
  in trans (cong S ih) (iret_11_3__drop_length x ys dy ex)

-- ---------------------------------------------------------------------
-- THE THEOREM
-- ---------------------------------------------------------------------

--@derives [IRET.11.3]
--@derives [IRET.7.7]
--@derives [LDET.5.3]
--@derives [IRET.11.1]
||| ONCE PER MATCH, from any state where every activation is unfired and
||| the view holds: a pump with fuel above the activation count halts
||| `Quiescent`, fires exactly as many times as there are activations, and
||| leaves every activation fired with its tuple; and every chain's tuples
||| are exactly its recompute over working memory, none twice. The
||| activations ARE the matches, each once, and each fires once.
export
iret_11_3__pump_fires_once_per_match_from : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) ->
                                            Iret_19__view eng -> Iret_11_3__unfired_all (nchains (enet eng)) ->
                                            Ltim_2_5_1__action_free (nchains (enet eng)) -> LT (iret_11_1__act_count (nchains (enet eng))) fuel ->
                                            ( iret_11_4__run_net life fuel eng
                                                = (MkEngine (ewm eng) (MkNetwork (nalphas (enet eng)) (idat_6_2_2__mark_all (nchains (enet eng)))), Quiescent, iret_11_1__act_count (nchains (enet eng)))
                                            , Rarc_5_6_5__recomputed eng )
iret_11_3__pump_fires_once_per_match_from life fuel (MkEngine wm (MkNetwork al chains)) v u af lt =
  let cnt = iret_11_4__unfired_count_is_act_count chains u
  in ( trans (iret_11_4__run_net_marks_all life fuel wm al chains af (replace {p = \n => LT n fuel} (sym cnt) lt))
             (cong (\n => (MkEngine wm (MkNetwork al (idat_6_2_2__mark_all chains)), Quiescent, n)) cnt)
     , rarc_5_6_5__view_recomputed (MkEngine wm (MkNetwork al chains)) v )

--@derives [IRET.11.3]
--@derives [IRET.7.7]
--@derives [LDET.5.3]
--@derives [IRET.11.1]
--@derives [RDSC.4a.5]
||| THE THEOREM. For an action-free program, from the loaded network, after
||| any inputs applied with no pump between them, a pump with fuel enough
||| fires once per activation and the activations are the matches, each
||| once: the clauses a duplicate firing breaks, held together. [IRET.7.7] and
||| [IRET.11.1] in the view; [IRET.11.3] and [LDET.5.3] in the run.
export
iret_11_3__pump_fires_once_per_match : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                       (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                       Ltim_2_5_1__action_free (nchains (enet (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)))) ->
                                       LT (iret_11_1__act_count (nchains (enet (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules))))) fuel ->
                                       ( iret_11_4__run_net life fuel (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules))
                                           = ( MkEngine (ewm (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)))
                                                        (MkNetwork (nalphas (enet (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules))))
                                                                   (idat_6_2_2__mark_all (nchains (enet (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules))))))
                                             , Quiescent, iret_11_1__act_count (nchains (enet (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)))) )
                                       , Rarc_5_6_5__recomputed (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules)) )
iret_11_3__pump_fires_once_per_match life fuel evs alphas rules af lt =
  iret_11_3__pump_fires_once_per_match_from life fuel (rarc_5_6_4__applied life evs (rdsc_4a_5__load alphas rules))
    (rarc_5_6_4__applied_view life evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_view alphas rules))
    (iret_11_3__applied_unfired life evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_view alphas rules) (rdsc_4a_5__load_unfired alphas rules))
    af lt

--@derives [IRET.11.3]
--@derives [RARC.5.6.5]
||| Chain by chain: a terminal that holds its recompute once holds as many
||| activations as matches.
export
iret_11_3__match_count_from : (al : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> Iret_11_3__distinct wm -> (cs : List Rlow_4_2_1__chain) ->
                              ((c : Rlow_4_2_1__chain) -> Elem c cs ->
                                 ( Iret_7_4__same_set (iret_8_1__tuples (cacts c)) (iret_7_7__view al wm (cnodes c) [[]])
                                 , Iret_11_3__distinct (iret_8_1__tuples (cacts c)) )) ->
                              iret_11_1__act_count cs = rarc_5_6_5__match_count al wm cs
iret_11_3__match_count_from al wm dw [] rec = Refl
iret_11_3__match_count_from al wm dw (c :: cs) rec =
  let (ss, dt) = rec c Here
      lm = the (length (map atuple (cacts c)) = length (cacts c)) (lengthMap (cacts c))
      one = the (length (cacts c) = length (iret_7_7__view al wm (cnodes c) [[]]))
                (trans (sym lm)
                       (iret_11_3__distinct_same_set_length (iret_8_1__tuples (cacts c)) (iret_7_7__view al wm (cnodes c) [[]]) dt
                          (rarc_5_6_5__view_distinct al wm dw (cnodes c) [[]] (DCons (\e => absurd e) DNil)) ss))
  in cong2 (+) one (iret_11_3__match_count_from al wm dw cs (\c', e => rec c' (There e)))

--@derives [IRET.11.3]
--@derives [IRET.7.7]
--@derives [RARC.5.6.5]
||| THE COUNT: under the view, the activations of every chain are as many as
||| its matches, so the pump's firings are the number of distinct matches,
||| summed over the rules.
export
iret_11_3__fires_the_match_count : (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (chains : List Rlow_4_2_1__chain) ->
                                   Iret_19__view (MkEngine wm (MkNetwork al chains)) ->
                                   iret_11_1__act_count chains = rarc_5_6_5__match_count al wm chains
iret_11_3__fires_the_match_count wm al chains v =
  iret_11_3__match_count_from al wm (fst v) chains (snd (rarc_5_6_5__view_recomputed (MkEngine wm (MkNetwork al chains)) v))

-- ---------------------------------------------------------------------
-- Executed: a symmetric word square, in both pattern orders
-- ---------------------------------------------------------------------

--@spec [IRET.7.7]
||| THE WORDS of the square, letter by position, indexed by the fact's
||| payload: word 0 is fact 50's `4 0 6`, word 1 is fact 1's `0 4 3`, word 2
||| is fact 12's `6 3 2` -- a symmetric grid, each a row and the matching
||| column. Word 3, `1 2 3`, completes no square with them: a word is its
||| own square only when constant, and no other word has a `1` for its
||| column to stand on. (A first draft gave word 3 as `1 1 1`; the model
||| found the second square it makes and fired twice, rightly.)
public export
iret_7_7__letter : Nat -> Nat -> Nat
iret_7_7__letter 0 0 = 4
iret_7_7__letter 0 1 = 0
iret_7_7__letter 0 2 = 6
iret_7_7__letter 1 0 = 0
iret_7_7__letter 1 1 = 4
iret_7_7__letter 1 2 = 3
iret_7_7__letter 2 0 = 6
iret_7_7__letter 2 1 = 3
iret_7_7__letter 2 2 = 2
iret_7_7__letter 3 0 = 1
iret_7_7__letter 3 1 = 2
iret_7_7__letter 3 2 = 3
iret_7_7__letter _ _ = 9

--@spec [IRET.7.7]
||| A letter of a fact's word; 9 for no fact.
public export
iret_7_7__letter_of : Nat -> Maybe Lfac_1_7_1__fact -> Nat
iret_7_7__letter_of i Nothing = 9
iret_7_7__letter_of i (Just f) = iret_7_7__letter (fpay f) i

--@spec [IRET.7.7]
||| Letter `i` of the fact bound at position `p` of the token.
public export
iret_7_7__tok_letter : Nat -> Nat -> Iret_7_1__token -> Nat
iret_7_7__tok_letter p i t = iret_7_7__letter_of i (rarc_5_6_5__nth p t)

--@spec [IRET.7.7]
||| A row pattern: any `Word`.
public export
iret_7_7__row : Iret_7_5__join
iret_7_7__row = \t, f => True

--@spec [IRET.7.7]
||| Column `j` after the three rows: `f.c0 == f0.cj and f.c1 == f1.cj and
||| f.c2 == f2.cj`, the issue's `where` on `f3`, `f4`, `f5`.
public export
iret_7_7__column : Nat -> Iret_7_5__join
iret_7_7__column j = \t, f => (iret_7_7__letter (fpay f) 0 == iret_7_7__tok_letter 0 j t)
                           && (iret_7_7__letter (fpay f) 1 == iret_7_7__tok_letter 1 j t)
                           && (iret_7_7__letter (fpay f) 2 == iret_7_7__tok_letter 2 j t)

--@spec [IRET.7.7]
||| THE RULE, rows first: `Word f0, Word f1, Word f2`, then the three
||| columns. Six positive nodes on one alpha, the issue's `square`.
public export
iret_7_7__square_rows_first : Iret_19__engine
iret_7_7__square_rows_first =
  rdsc_4a_5__load [(0, \_ => True)]
    [( [ (0, iret_7_7__row, False), (0, iret_7_7__row, False), (0, iret_7_7__row, False)
       , (0, iret_7_7__column 0, False), (0, iret_7_7__column 1, False), (0, iret_7_7__column 2, False) ], [])]

--@spec [IRET.7.7]
||| THE RULE, interleaved: row 0, column 0, row 1, column 1, row 2, column 2,
||| each `where` on the facts bound before it (positions 0 and 1 are `f0`
||| and `f3`, 2 and 3 are `f1` and `f4`, 4 and 5 are `f2` and `f5`).
public export
iret_7_7__square_interleaved : Iret_19__engine
iret_7_7__square_interleaved =
  rdsc_4a_5__load [(0, \_ => True)]
    [( [ (0, iret_7_7__row, False)
       , (0, (\t, f => iret_7_7__letter (fpay f) 0 == iret_7_7__tok_letter 0 0 t), False)
       , (0, (\t, f => iret_7_7__letter (fpay f) 0 == iret_7_7__tok_letter 1 1 t), False)
       , (0, (\t, f => (iret_7_7__letter (fpay f) 0 == iret_7_7__tok_letter 0 1 t) && (iret_7_7__letter (fpay f) 1 == iret_7_7__tok_letter 2 1 t)), False)
       , (0, (\t, f => (iret_7_7__letter (fpay f) 0 == iret_7_7__tok_letter 1 2 t) && (iret_7_7__letter (fpay f) 1 == iret_7_7__tok_letter 3 2 t)), False)
       , (0, (\t, f => (iret_7_7__letter (fpay f) 0 == iret_7_7__tok_letter 0 2 t) && (iret_7_7__letter (fpay f) 1 == iret_7_7__tok_letter 2 2 t)
                    && (iret_7_7__letter (fpay f) 2 == iret_7_7__tok_letter 4 2 t)), False) ], [])]

--@spec [IRET.7.7]
||| THE STREAM: the three words of the square and the fourth, asserted with
||| no pump between them, keys as the issue's fact ids. The engine mints
||| ids 0 to 3.
public export
iret_7_7__square_inputs : List Rarc_5_6_1__event
iret_7_7__square_inputs = [Assert 0 50 0, Assert 0 1 1, Assert 0 12 2, Assert 0 7 3]

--@spec [IRET.11.4]
||| What a pump's result shows: its firing count, its halt, and every
||| chain's tuples.
public export
iret_11_4__observed : (Iret_19__engine, Iret_11_4__halt, Nat) -> (Nat, Iret_11_4__halt, List (List Iret_7_1__token))
iret_11_4__observed (e, h, n) = (n, h, map (\c => iret_8_1__tuples (cacts c)) (nchains (enet e)))

--@derives [IRET.7.7]
--@derives [IRET.11.3]
--@derives [IRET.11.1]
||| THE DUPLICATE DOES NOT HAPPEN, rows first: the pump fires once, and
||| the one chain holds the one match, `50 1 12 50 1 12` by key, each fact
||| filling a row and its column. Executed.
export
iret_7_7__word_square_fires_once :
  iret_11_4__observed (iret_11_4__run_net (\_ => Explicit) 10 (rarc_5_6_4__applied (\_ => Explicit) iret_7_7__square_inputs iret_7_7__square_rows_first))
    = ( 1, Quiescent
      , [[[MkFact 0 0 50 0, MkFact 1 0 1 1, MkFact 2 0 12 2, MkFact 0 0 50 0, MkFact 1 0 1 1, MkFact 2 0 12 2]]] )
iret_7_7__word_square_fires_once = Refl

--@derives [IRET.7.7]
--@derives [IRET.11.3]
--@derives [IRET.11.1]
||| AND INTERLEAVED, the issue's second order: once, the one match with the
||| columns beside their rows. Executed.
export
iret_7_7__word_square_interleaved_fires_once :
  iret_11_4__observed (iret_11_4__run_net (\_ => Explicit) 10 (rarc_5_6_4__applied (\_ => Explicit) iret_7_7__square_inputs iret_7_7__square_interleaved))
    = ( 1, Quiescent
      , [[[MkFact 0 0 50 0, MkFact 0 0 50 0, MkFact 1 0 1 1, MkFact 1 0 1 1, MkFact 2 0 12 2, MkFact 2 0 12 2]]] )
iret_7_7__word_square_interleaved_fires_once = Refl

-- ---------------------------------------------------------------------
-- Executed: the lifecycle and retraction cases, on a one-row rule
-- ---------------------------------------------------------------------

--@spec [IRET.19.1]
||| ONE ROW RULE: one alpha admitting every fact of kind 0, one rule of one
||| positive pattern and no actions. What the lifecycle witnesses load.
public export
iret_19_1__one_row_rule : Iret_19__engine
iret_19_1__one_row_rule = rdsc_4a_5__load [(0, \_ => True)] [([(0, iret_7_7__row, False)], [])]

--@spec [IRET.11.3]
||| The `fired` flags of every chain's activations: the agenda before a pump,
||| as flags.
public export
iret_11_3__flags : Iret_19__engine -> List (List Bool)
iret_11_3__flags e = map (\c => map afired (cacts c)) (nchains (enet e))

--@derives [LFAC.2.5.1]
--@derives [IRET.11.3]
||| A RELATION ASSERTED TWICE is one fact and one activation: the second
||| assert is [LFAC.2.5.1]'s no-op, `iret_11_3__assert_unfired`'s Relation
||| case with the fact found. One firing. Executed.
export
lfac_2_5_1__relation_noop_fires_once :
  iret_11_4__observed (iret_11_4__run_net (\_ => Relation) 10 (rarc_5_6_4__applied (\_ => Relation) [Assert 0 5 1, Assert 0 5 1] iret_19_1__one_row_rule))
    = (1, Quiescent, [[[MkFact 0 0 5 1]]])
lfac_2_5_1__relation_noop_fires_once = Refl

--@derives [LFAC.2.5.1]
--@derives [IRET.11.3]
||| AN ENTITY ASSERTED TWICE WITH ONE PAYLOAD is the no-op too: the Entity
||| case with the payload equal. One firing. Executed.
export
lfac_2_5_1__entity_noop_fires_once :
  iret_11_4__observed (iret_11_4__run_net (\_ => Entity) 10 (rarc_5_6_4__applied (\_ => Entity) [Assert 0 5 1, Assert 0 5 1] iret_19_1__one_row_rule))
    = (1, Quiescent, [[[MkFact 0 0 5 1]]])
lfac_2_5_1__entity_noop_fires_once = Refl

--@derives [LFAC.2.5.3]
--@derives [IRET.11.3]
||| AN ENTITY ASSERTED TWICE WITH A CHANGED PAYLOAD is [LFAC.2.5.3]'s
||| retract-and-replace: the first wrapper's activation ends and the fresh
||| wrapper's is created unfired (the Entity case with the payload changed,
||| through `iret_11_3__retract_unfired`). Before the pump the one
||| activation is unfired. Executed.
export
lfac_2_5_3__replaced_is_unfired :
  iret_11_3__flags (rarc_5_6_4__applied (\_ => Entity) [Assert 0 5 1, Assert 0 5 2] iret_19_1__one_row_rule) = [[False]]
lfac_2_5_3__replaced_is_unfired = Refl

--@derives [LFAC.2.5.3]
--@derives [IRET.11.3]
||| AND THE PUMP FIRES ONCE, on the fresh wrapper, id 1: `iret_19_1__assert`
||| mints the fresh id against the memory the old wrapper is still in, so
||| the replace does not reuse the hole its retraction leaves, and
||| [LFAC.2.5.3]'s "a fresh wrapper with a new `fact_id`" holds literally.
||| (A first draft said id 0; the model's mismatch, 0 against 1, said
||| otherwise.) Executed.
export
lfac_2_5_3__entity_replace_fires_once :
  iret_11_4__observed (iret_11_4__run_net (\_ => Entity) 10 (rarc_5_6_4__applied (\_ => Entity) [Assert 0 5 1, Assert 0 5 2] iret_19_1__one_row_rule))
    = (1, Quiescent, [[[MkFact 1 0 5 2]]])
lfac_2_5_3__entity_replace_fires_once = Refl

--@derives [IRET.19.2]
--@derives [IRET.11.3]
||| A RETRACTION BETWEEN ASSERTS, AND ONE OF NOTHING: two facts asserted, the
||| first retracted by its id, then an id no fact carries
||| (`iret_11_3__apply_unfired`'s two Retract cases). The survivor's
||| activation fires once. Executed.
export
iret_19_2__retract_between_fires_once :
  iret_11_4__observed (iret_11_4__run_net (\_ => Explicit) 10 (rarc_5_6_4__applied (\_ => Explicit) [Assert 0 5 1, Assert 0 6 2, Retract 0, Retract 9] iret_19_1__one_row_rule))
    = (1, Quiescent, [[[MkFact 1 0 6 2]]])
iret_19_2__retract_between_fires_once = Refl

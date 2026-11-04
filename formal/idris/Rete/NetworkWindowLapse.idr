-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE LAPSED JUSTIFICATION IS RETRACTED: on the engine Rete/NetworkClocked.idr
||| pumps, a logical fact every one of whose justifying activations the tick
||| ended is gone from working memory when the tick's re-time stage ends, for
||| any program, any dependency table and any clock: the general theorem of
||| [LTIM.2.7.2].
|||
||| NORMATIVE COMPANION to Rete/NetworkClocked.idr, whose re-time stage it is
||| about, and Rete/NetworkFrameRetime.idr, at whose fixture it applies the
||| theorem.
|||
||| WHY. [LTIM.2.7.2]: when a `within`-windowed positive pattern justifies a
||| `logical` fact and the window expires, the pattern no longer matches and the
||| engine must retract the fact, by the justification-linkage principle of
||| [LLOG.15.1]. The lane had the clause in pieces: the re-time stage with its
||| cascade as the DEFINITION of the retraction (`iret_19_5__retime_clocked`);
||| "the pattern no longer matches" as a theorem
||| (`ltim_2_5_1__closing_ends_clocked`); the cascade after the re-time keeping
||| the frame invariant (`iret_19_5__retime_clocked_inv`); and one executed
||| instance (`ltim_2_5_1__ended_fired_cascade`). What no theorem stated is the
||| clause's consequence itself, for every program: that the justified fact IS
||| retracted. This file states it.
|||
||| WHAT IS MODELLED. "The justification lapses": a row of the dependency table
||| ([IRET.12.4]) whose activation is not live on the re-timed chains --
||| `iret_7_8__activation_live_net` reads False, the terminal holding no fired
||| activation of the row's identity after the re-time. "Justifies a logical
||| fact": a row targeting the fact's id. The clause's case is one `within`
||| pattern justifying the fact; the theorem takes the premise [LLOG.15.1] and
||| [IRET.12.2] give it in general -- EVERY row targeting the id has lapsed --
||| because a fact some other live activation still justifies keeps that
||| justification and stays, which is the refcount's contract and not the
||| clause's case. A fact no row ever targeted is outside both.
|||
||| PROVED.
|||
|||   * THE THEOREM (`ltim_2_7_2__lapsed_justification_retracted`): for every
|||     program, every list of timed tests and every clocked state with unique
|||     fact ids, for every id some row targets, if every row targeting it has
|||     lapsed on the re-timed chains, then no fact carrying that id is in
|||     working memory after the re-time stage. The cascade's first phase ends
|||     every such row (`ltim_2_7_2__dead_row_is_ended`), so the id is among the
|||     zeroed (`ltim_2_7_2__zeroed_holds_it`: its count against the kept rows
|||     is 0, `ltim_2_7_2__kept_count_zero`, because a kept row's activation is
|||     live); retracting the zeroed ids removes every fact with that id under
|||     unique ids (Rete/NetworkTms.idr's `iret_12_2__retract_ids_net_wm`,
|||     wrapped for an engine given whole); and the later phases only remove
|||     facts (`iret_12_2__phase_n_net_wm_sub`). The cascade's fuel plays no
|||     part (`ltim_2_7_2__cascade_drops` is stated for any number of phases
|||     after the first): the fact is gone after one phase and nothing puts a
|||     fact back.
|||   * EXECUTED (`ltim_2_7_2__retracted_at_the_fixture`): the theorem applied
|||     at Rete/NetworkFrameRetime.idr's fixture of a re-time that ends a fired
|||     logical activation, B under the gate that shuts at 1. Every hypothesis
|||     is discharged by computation on the state the re-time stage starts
|||     from (`ltim_2_7_2__lapse_state`): its working memory and its one row as
|||     literals (`ltim_2_7_2__lapse_wm`, `ltim_2_7_2__lapse_rows`), the row
|||     lapsed on the re-timed chains (`ltim_2_7_2__lapse_row_dead`, hence
|||     `ltim_2_7_2__lapse_only_dead`), unique ids on the literal
|||     (`ltim_2_7_2__lapse_ids_unique`, from a decided check of fresh ids,
|||     `iret_4_4__fresh_ids`, through `iret_4_4__unique_of_fresh`; a proof by
|||     cases on the memberships of a three-element literal is what Idris 2's
|||     coverage checker refuses). The conclusion is the one
|||     `ltim_2_5_1__ended_fired_cascade` computed -- the kind-2 fact is gone --
|||     reached here through the theorem rather than by evaluating the tick.
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. Which ticks end a
||| `within` activation: that a window which shuts leaves no activation of the
||| match is `ltim_2_5_1__closing_ends_clocked` (Rete/NetworkClocked.idr),
||| which discharges this theorem's premise for the clause's pattern; here the
||| premise is taken as given, so the theorem covers any lapse, a window's or
||| another gate's. The `fact_retract` event the clause names: the trace is
||| Rete/NetworkTraced.idr's, and this file speaks of working memory. Unique
||| fact ids ([IRET.4.4]) are a premise, carried by the frame invariant on every
||| reachable state (Rete/NetworkFrameClocked.idr's `Ltim_2_5_1__tms_inv`) and
||| proved on the fixture's literal here. The re-time stage is
||| Rete/NetworkClocked.idr's definition, a data input re-timing nothing, as
||| there.
module Rete.NetworkWindowLapse

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.TtlSweep
import Rete.Network
import Rete.NetworkView
import Rete.NetworkDispatch
import Rete.NetworkOrderKeep
import Rete.NetworkTransferAgree
import Rete.NetworkTms
import Rete.NetworkTmsTransfer
import Rete.NetworkTtl
import Rete.NetworkTick
import Rete.NetworkClocked
import Rete.NetworkEdges
import Rete.NetworkOnce
import Rete.NetworkFrame
import Rete.NetworkFrameClocked
import Rete.NetworkFrameRetime
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The lapsed justification
-- ---------------------------------------------------------------------

--@spec [LTIM.2.7.2]
--@spec [IRET.12.2]
||| JUSTIFIED ONLY BY ENDED ACTIVATIONS: every row of the table targeting the
||| id has an activation that is not live on the engine's chains. "The
||| justification lapses", for every justification of the fact at once.
public export
Ltim_2_7_2__justified_only_by_ended : Iret_19__engine -> Iret_12_4__table -> Nat -> Type
Ltim_2_7_2__justified_only_by_ended eng rows i =
  (row : Iret_12_4__row) -> Elem row rows -> rtarget row = i -> iret_7_8__activation_live_net (nchains (enet eng)) row = False

--@derives [LTIM.2.7.2]
--@derives [IRET.12.2]
||| A row whose activation is not live is among the rows the phase ends.
export
ltim_2_7_2__dead_row_is_ended : (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (row : Iret_12_4__row) -> Elem row rows ->
                                iret_7_8__activation_live_net (nchains (enet eng)) row = False ->
                                Elem row (iret_12_2__ended_net eng rows)
ltim_2_7_2__dead_row_is_ended eng rows row er dead =
  lcyc_1_1__elem_filter_fwd (\r => not (iret_7_8__activation_live_net (nchains (enet eng)) r && rarc_5_6_4__is_live (rtarget r) (ewm eng))) rows er
    (cong (\b => not (b && rarc_5_6_4__is_live (rtarget row) (ewm eng))) dead)

-- ---------------------------------------------------------------------
-- The cascade, phase by phase: what it leaves, and that it only removes
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| ONE PHASE, BY CASES: it ends nothing and is the identity, or it ends rows
||| and the engine it leaves is the retraction of the zeroed ids from the
||| engine it started with. Rete/NetworkFrameClocked.idr's
||| `iret_12_2__phase_step_net_shape` with the engine named rather than
||| existential, which the working-memory argument below needs.
export
iret_12_2__phase_step_net_split : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
  Either ( iret_12_2__ended_net eng rows = []
         , iret_12_2__phase_step_net pg (MkTmsNet eng rows) = MkTmsNet eng rows )
         (x : Iret_12_4__row ** (xs : Iret_12_4__table **
            ( iret_12_2__ended_net eng rows = x :: xs
            , iret_12_2__phase_step_net pg (MkTmsNet eng rows)
                = MkTmsNet (iret_12_2__retract_ids_net (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng) (iret_12_2__kept_net eng rows) )))
iret_12_2__phase_step_net_split pg eng rows with (iret_12_2__ended_net eng rows)
  iret_12_2__phase_step_net_split pg eng rows | [] = Left (Refl, Refl)
  iret_12_2__phase_step_net_split pg eng rows | (x :: xs) = Right (x ** (xs ** (Refl, Refl)))

--@derives [IRET.12.2]
||| A CASCADE ONLY REMOVES FACTS: a fact in working memory after any number of
||| phases was in it before. An ending phase is a retraction of ids
||| (`iret_12_2__retract_ids_net_sub`); a quiet phase changes nothing.
export
iret_12_2__phase_n_net_wm_sub : (n : Nat) -> (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) -> (g : Lfac_1_7_1__fact) ->
                                Elem g (ewm (ncore (iret_12_2__phase_n_net n pg s))) -> Elem g (ewm (ncore s))
iret_12_2__phase_n_net_wm_sub Z pg s g e = e
iret_12_2__phase_n_net_wm_sub (S m) pg (MkTmsNet eng rows) g e = case iret_12_2__phase_step_net_split pg eng rows of
  Left (_, eq) =>
    iret_12_2__phase_n_net_wm_sub m pg (MkTmsNet eng rows) g
      (replace {p = \t => Elem g (ewm (ncore t))} (iret_12_2__phase_n_net_succ m pg (MkTmsNet eng rows) eng rows eq) e)
  Right (x ** (xs ** (_, eq))) =>
    iret_12_2__retract_ids_net_sub (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng g
      (iret_12_2__phase_n_net_wm_sub m pg
         (MkTmsNet (iret_12_2__retract_ids_net (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng) (iret_12_2__kept_net eng rows)) g
         (replace {p = \t => Elem g (ewm (ncore t))}
                  (iret_12_2__phase_n_net_succ m pg (MkTmsNet eng rows)
                     (iret_12_2__retract_ids_net (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng) (iret_12_2__kept_net eng rows) eq)
                  e))

--@derives [IRET.12.2]
--@derives [IRET.4.4]
||| Retracting ids one at a time leaves the batch's working memory under
||| unique ids, for an engine given whole: Rete/NetworkTms.idr's
||| `iret_12_2__retract_ids_net_wm` on the engine's two fields.
export
iret_12_2__retract_ids_net_wm_eng : (ids : List Nat) -> (eng : Iret_19__engine) -> Iret_4_4__unique (ewm eng) ->
                                    ewm (iret_12_2__retract_ids_net ids eng) = iret_12_2__retract_ids ids (ewm eng)
iret_12_2__retract_ids_net_wm_eng ids (MkEngine wm net) uq = iret_12_2__retract_ids_net_wm ids wm uq net

-- ---------------------------------------------------------------------
-- The lapsed id is zeroed
-- ---------------------------------------------------------------------

--@derives [LTIM.2.7.2]
--@derives [IRET.12.2]
--@derives [IRET.12.1]
||| A KEPT ROW TARGETS NO LAPSED ID: the id's count against the rows the phase
||| keeps is zero, because a kept row's activation is live and every row
||| targeting the id has one that is not.
export
ltim_2_7_2__kept_count_zero : (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (i : Nat) ->
                              Ltim_2_7_2__justified_only_by_ended eng rows i ->
                              iret_12_1__count (iret_12_2__kept_net eng rows) i = 0
ltim_2_7_2__kept_count_zero eng rows i dead =
  cong length (lcyc_1_1__filter_all_false (\row => rtarget row == i) (iret_12_2__kept_net eng rows)
                 (lcyc_1_1__all_from_elem (iret_12_2__kept_net eng rows) notTarget))
  where
    notTarget : (row : Iret_12_4__row) -> Elem row (iret_12_2__kept_net eng rows) -> (rtarget row == i) = False
    notTarget row ek = case iret_12__bool_split (rtarget row == i) of
      Right isFalse => isFalse
      Left isTrue =>
        let (erows, kp) = lcyc_1_1__elem_filter_inv (\r => iret_7_8__activation_live_net (nchains (enet eng)) r && rarc_5_6_4__is_live (rtarget r) (ewm eng)) rows ek
        in void (lcyc_1_1__bool_not_both (iret_7_8__activation_live_net (nchains (enet eng)) row)
                   (lcyc_1_1__and_true_l (iret_7_8__activation_live_net (nchains (enet eng)) row) (rarc_5_6_4__is_live (rtarget row) (ewm eng)) kp)
                   (dead row erows (lcyc_1_1__nat_eq_true (rtarget row) i isTrue)))

--@derives [LTIM.2.7.2]
--@derives [IRET.12.2]
||| THE LAPSED ID IS ZEROED: when the phase ends rows, an id some row targets
||| and every row of which has lapsed is among the ids the phase retracts.
export
ltim_2_7_2__zeroed_holds_it : (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (x : Iret_12_4__row) -> (xs : Iret_12_4__table) ->
                              iret_12_2__ended_net eng rows = x :: xs ->
                              (i : Nat) -> (r0 : Iret_12_4__row) -> Elem r0 rows -> rtarget r0 = i ->
                              Ltim_2_7_2__justified_only_by_ended eng rows i ->
                              Elem i (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows))
ltim_2_7_2__zeroed_holds_it eng rows x xs en i r0 er rt dead =
  lcyc_1_1__elem_filter_fwd (\g => iret_12_1__count (iret_12_2__kept_net eng rows) g == 0) (map rtarget (x :: xs))
    (replace {p = \t => Elem t (map rtarget (x :: xs))} rt
       (lcyc_1_1__elem_map_fwd rtarget (replace {p = \l => Elem r0 l} en (ltim_2_7_2__dead_row_is_ended eng rows r0 er (dead r0 er rt)))))
    (cong (\k => k == 0) (ltim_2_7_2__kept_count_zero eng rows i dead))

-- ---------------------------------------------------------------------
-- The theorem
-- ---------------------------------------------------------------------

--@derives [LTIM.2.7.2]
--@derives [IRET.12.2]
--@derives [LLOG.15.1]
||| THE CASCADE RETRACTS A FACT EVERY JUSTIFICATION OF WHICH HAS LAPSED, with
||| any number of phases after the first: the first phase ends the fact's
||| rows and retracts its id, and no later phase puts a fact back. Under
||| unique ids, so that retracting the id retracts the fact and no other.
export
ltim_2_7_2__cascade_drops : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (n : Nat) ->
                            Iret_4_4__unique (ewm eng) ->
                            (i : Nat) -> (r0 : Iret_12_4__row) -> Elem r0 rows -> rtarget r0 = i ->
                            Ltim_2_7_2__justified_only_by_ended eng rows i ->
                            (f : Lfac_1_7_1__fact) -> fid f = i ->
                            Not (Elem f (ewm (ncore (iret_12_2__phase_n_net (S n) pg (MkTmsNet eng rows)))))
ltim_2_7_2__cascade_drops pg eng rows n uq i r0 er rt dead f fi e = case iret_12_2__phase_step_net_split pg eng rows of
  Left (en, _) => absurd (replace {p = \l => Elem r0 l} en (ltim_2_7_2__dead_row_is_ended eng rows r0 er (dead r0 er rt)))
  Right (x ** (xs ** (en, eq))) =>
    let (_, notIn) = lcyc_1_1__elem_filter_inv (\g => not (rarc_5_6_5__elem (fid g) (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)))) (ewm eng)
                       (replace {p = \w => Elem f w}
                                (iret_12_2__retract_ids_net_wm_eng (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng uq)
                                (iret_12_2__phase_n_net_wm_sub n pg
                                   (MkTmsNet (iret_12_2__retract_ids_net (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng) (iret_12_2__kept_net eng rows)) f
                                   (replace {p = \t => Elem f (ewm (ncore t))}
                                            (iret_12_2__phase_n_net_succ n pg (MkTmsNet eng rows)
                                               (iret_12_2__retract_ids_net (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng) (iret_12_2__kept_net eng rows) eq)
                                            e)))
    in lcyc_1_1__bool_not_both (rarc_5_6_5__elem i (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)))
         (lcyc_1_1__elem_l_true i (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) (ltim_2_7_2__zeroed_holds_it eng rows x xs en i r0 er rt dead))
         (replace {p = \j => rarc_5_6_5__elem j (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) = False} fi
                  (lcyc_1_1__not_true_is_false (rarc_5_6_5__elem (fid f) (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows))) notIn))

--@derives [LTIM.2.7.2]
--@derives [IRET.12.2]
--@derives [LLOG.15.1]
--@derives [IRET.19.5]
||| THE THEOREM. For every program, every list of timed tests and every
||| clocked state with unique fact ids: an id some row targets, every row
||| targeting which has lapsed on the chains the tick re-times at the state's
||| clock, carries no fact in working memory after the re-time stage. The
||| clause's "the engine must retract the justified logical fact", for any
||| program and any justifier the tick ends; the clause's "the pattern no
||| longer matches" is the premise, which `ltim_2_5_1__closing_ends_clocked`
||| discharges for a window that shuts.
export
ltim_2_7_2__lapsed_justification_retracted : (pg : Lcyc_3_2_1__program) -> (ts : List (Maybe Ltim_2_4_1__timed)) -> (cs : Iret_19_3__clocked_net) ->
                                             Iret_4_4__unique (ewm (ncore (nengine cs))) ->
                                             (i : Nat) -> (r0 : Iret_12_4__row) -> Elem r0 (ndeps (nengine cs)) -> rtarget r0 = i ->
                                             Ltim_2_7_2__justified_only_by_ended (iret_19_5__tick ts (nclock cs) (ncore (nengine cs))) (ndeps (nengine cs)) i ->
                                             (f : Lfac_1_7_1__fact) -> fid f = i ->
                                             Not (Elem f (ewm (ncore (nengine (iret_19_5__retime_clocked pg ts cs)))))
ltim_2_7_2__lapsed_justification_retracted pg ts (MkClockedNet (MkTmsNet eng rows) dl c) uq i r0 er rt dead f fi =
  ltim_2_7_2__cascade_drops pg (iret_19_5__tick ts c eng) rows (length rows) uq i r0 er rt dead f fi

-- ---------------------------------------------------------------------
-- Executed: the theorem at the fixture of a re-time that ends a fired
-- logical activation (Rete/NetworkFrameRetime.idr)
-- ---------------------------------------------------------------------

--@spec [LTIM.2.7.2]
--@spec [LTIM.2.5.1]
||| THE STATE THE RE-TIME STAGE STARTS FROM at Rete/NetworkFrameRetime.idr's
||| fixture: after the run in which B's logical emit recorded its row, the
||| tick to 1 has advanced the clock and swept (nothing: no TTL) and has not
||| yet re-timed. `ltim_2_5_1__fired_then_tick` is the re-time stage applied
||| to it, by Rete/NetworkClocked.idr's definition of a prepared tick.
public export
ltim_2_7_2__lapse_state : Iret_19_3__clocked_net
ltim_2_7_2__lapse_state =
  rarc_5_6_3__prepare_net ltim_2_5_1__two_rules_b_shutting ltim_2_5_1__no_ttl (Tick 1) (fst ltim_2_5_1__fired_run)

--@derives [LTIM.2.7.2]
--@derives [LTIM.2.5.1]
||| ITS WORKING MEMORY, as a literal: the kind-0 input, A's kind-1 fact, B's
||| kind-2 fact, in assertion order. Computed.
export
ltim_2_7_2__lapse_wm : ewm (ncore (nengine ltim_2_7_2__lapse_state)) = [MkFact 0 0 1 0, MkFact 1 1 0 0, MkFact 2 2 0 0]
ltim_2_7_2__lapse_wm = Refl

--@derives [LTIM.2.7.2]
--@derives [IRET.12.4]
||| ITS TABLE, as a literal: B's one row, the activation (rule 0 over the
||| kind-1 fact) justifying the kind-2 fact. Computed.
export
ltim_2_7_2__lapse_rows : ndeps (nengine ltim_2_7_2__lapse_state) = [MkRow 0 [1] 2]
ltim_2_7_2__lapse_rows = Refl

--@derives [LTIM.2.7.2]
--@derives [LTIM.2.5.1]
--@derives [IRET.19.5]
||| THE ROW HAS LAPSED on the re-timed chains: B's gate shuts at 1, so after
||| the re-time at the state's clock the terminal holds no fired activation of
||| the row's identity. Computed.
export
ltim_2_7_2__lapse_row_dead :
  iret_7_8__activation_live_net (nchains (enet (iret_19_5__tick ltim_2_5_1__b_shutters (nclock ltim_2_7_2__lapse_state) (ncore (nengine ltim_2_7_2__lapse_state)))))
                                (MkRow 0 [1] 2) = False
ltim_2_7_2__lapse_row_dead = Refl

--@derives [LTIM.2.7.2]
--@derives [IRET.12.2]
||| EVERY ROW TARGETING THE KIND-2 FACT HAS LAPSED: there is one, and it has.
export
ltim_2_7_2__lapse_only_dead : Ltim_2_7_2__justified_only_by_ended
                                (iret_19_5__tick ltim_2_5_1__b_shutters (nclock ltim_2_7_2__lapse_state) (ncore (nengine ltim_2_7_2__lapse_state)))
                                (ndeps (nengine ltim_2_7_2__lapse_state)) 2
ltim_2_7_2__lapse_only_dead row e rt = theOne row (replace {p = \l => Elem row l} ltim_2_7_2__lapse_rows e)
  where
    theOne : (r : Iret_12_4__row) -> Elem r [MkRow 0 [1] 2] ->
             iret_7_8__activation_live_net (nchains (enet (iret_19_5__tick ltim_2_5_1__b_shutters (nclock ltim_2_7_2__lapse_state) (ncore (nengine ltim_2_7_2__lapse_state))))) r = False
    theOne _ Here = ltim_2_7_2__lapse_row_dead
    theOne _ (There later) = absurd later

--@spec [IRET.4.4]
||| FRESH IDS, decided: each fact's id is carried by no fact after it. What a
||| literal working memory can be checked for by computation, where
||| `Iret_4_4__unique`, a statement over every pair of memberships, cannot.
public export
iret_4_4__fresh_ids : Rarc_5_6_4__wm -> Bool
iret_4_4__fresh_ids [] = True
iret_4_4__fresh_ids (f :: fs) = not (rarc_5_6_5__elem (fid f) (map fid fs)) && iret_4_4__fresh_ids fs

--@derives [IRET.4.4]
||| FRESH IDS ARE UNIQUE IDS: two members with one id are one member. By
||| induction on the memory; two members at different positions put the
||| later one's id among the ids after the earlier one, which fresh ids
||| forbid.
export
iret_4_4__unique_of_fresh : (wm : Rarc_5_6_4__wm) -> iret_4_4__fresh_ids wm = True -> Iret_4_4__unique wm
iret_4_4__unique_of_fresh [] ok _ _ ef _ _ = absurd ef
iret_4_4__unique_of_fresh (x :: xs) ok _ _ Here Here _ = Refl
iret_4_4__unique_of_fresh (x :: xs) ok _ g Here (There e) eq =
  void (lcyc_1_1__bool_not_both (rarc_5_6_5__elem (fid x) (map fid xs))
          (replace {p = \j => rarc_5_6_5__elem j (map fid xs) = True} (sym eq) (lcyc_1_1__elem_l_true (fid g) (map fid xs) (lcyc_1_1__elem_map_fwd fid e)))
          (lcyc_1_1__not_true_is_false (rarc_5_6_5__elem (fid x) (map fid xs)) (lcyc_1_1__and_true_l (not (rarc_5_6_5__elem (fid x) (map fid xs))) (iret_4_4__fresh_ids xs) ok)))
iret_4_4__unique_of_fresh (x :: xs) ok f _ (There e) Here eq =
  void (lcyc_1_1__bool_not_both (rarc_5_6_5__elem (fid x) (map fid xs))
          (replace {p = \j => rarc_5_6_5__elem j (map fid xs) = True} eq (lcyc_1_1__elem_l_true (fid f) (map fid xs) (lcyc_1_1__elem_map_fwd fid e)))
          (lcyc_1_1__not_true_is_false (rarc_5_6_5__elem (fid x) (map fid xs)) (lcyc_1_1__and_true_l (not (rarc_5_6_5__elem (fid x) (map fid xs))) (iret_4_4__fresh_ids xs) ok)))
iret_4_4__unique_of_fresh (x :: xs) ok f g (There e) (There e') eq =
  iret_4_4__unique_of_fresh xs (lcyc_1_1__and_true_r (not (rarc_5_6_5__elem (fid x) (map fid xs))) (iret_4_4__fresh_ids xs) ok) f g e e' eq

--@derives [IRET.4.4]
--@derives [LTIM.2.7.2]
||| THE LITERAL'S IDS ARE UNIQUE: its ids are fresh by computation. [IRET.4.4]
||| on the fixture's state, which the theorem takes as a premise.
export
ltim_2_7_2__lapse_ids_unique : Iret_4_4__unique [MkFact 0 0 1 0, MkFact 1 1 0 0, MkFact 2 2 0 0]
ltim_2_7_2__lapse_ids_unique = iret_4_4__unique_of_fresh [MkFact 0 0 1 0, MkFact 1 1 0 0, MkFact 2 2 0 0] Refl

--@derives [LTIM.2.7.2]
--@derives [IRET.12.2]
--@derives [LLOG.15.1]
||| THE THEOREM AT THE FIXTURE: the kind-2 fact is not in working memory after
||| the tick that shut B's gate -- the conclusion `ltim_2_5_1__ended_fired_cascade`
||| computed, reached here through the theorem with every hypothesis
||| discharged on the literals.
export
ltim_2_7_2__retracted_at_the_fixture : Not (Elem (MkFact 2 2 0 0) (ewm (ncore (nengine ltim_2_5_1__fired_then_tick))))
ltim_2_7_2__retracted_at_the_fixture =
  ltim_2_7_2__lapsed_justification_retracted ltim_2_5_1__two_rules_b_shutting ltim_2_5_1__b_shutters ltim_2_7_2__lapse_state
    (replace {p = \w => Iret_4_4__unique w} (sym ltim_2_7_2__lapse_wm) ltim_2_7_2__lapse_ids_unique)
    2 (MkRow 0 [1] 2) (replace {p = \l => Elem (MkRow 0 [1] 2) l} (sym ltim_2_7_2__lapse_rows) Here) Refl
    ltim_2_7_2__lapse_only_dead (MkFact 2 2 0 0) Refl

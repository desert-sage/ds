-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE FIXTURE'S STEPS. A conformance fixture drives an engine with a
||| sequence of inputs and pumps in whatever cadence it wrote --
||| `assert, assert, pump` as well as [LFST.9.2.1]'s canonical
||| input-then-pump, which that clause calls a live optimisation outside
||| verify-replay. This module names such a sequence over the network
||| engine with truth maintenance and over Rete/FireLoopTms.idr's
||| (RARC.5.6.1: every event enters through the consumption loop),
||| proves that any sequence keeps the agreement of
||| Rete/NetworkTmsTransfer.idr, and gives the pump a traced form -- each
||| firing's terminal ordinal and fired match, [IRET.11.4] step 1a --
||| whose engine, halt and count are the pump's own. The same twice over
||| for the CLOCKED engine of Rete/NetworkTtl.idr: a fixture's inputs are
||| then [RARC.5.6.2]'s -- a data event or a clock tick, each through the
||| loop's steps before firing -- and the traced pump names each firing's
||| facts, not only their ids, so a runner can evaluate what the firing's
||| effects read. Fixture.idr, not a model module, runs exactly the clocked
||| forms on a lowered fixture and prints what they hold; what it prints is
||| therefore the proved machine's.
module Rete.NetworkTraced

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.TtlSweep
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.NetworkOrder
import Rete.NetworkOrderKeep
import Rete.NetworkRefraction
import Rete.NetworkCorollaries
import Rete.NetworkAgree
import Rete.NetworkTransferTable
import Rete.NetworkTransferAgree
import Rete.NetworkTransfer
import Rete.NetworkTmsCascade
import Rete.NetworkTms
import Rete.NetworkTmsTransfer
import Rete.NetworkTtl
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.List.Elem
import Data.List.Quantifiers

%default total

-- ---------------------------------------------------------------------
-- Inputs and pumps in a fixture's cadence
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.1]
--@spec [LFST.9.2.1]
||| What a fixture issues: an input applied, or a pump under a fuel.
public export
data Rarc_5_6_1__step : Type where
  SApply : Rarc_5_6_1__event -> Rarc_5_6_1__step
  SPump  : Nat -> Rarc_5_6_1__step

--@spec [RARC.5.6.1]
||| The steps, in order, on the network engine with truth maintenance.
public export
rarc_5_6_1__run_steps_net : Lcyc_3_2_1__program -> List Rarc_5_6_1__step -> Iret_12__net_state -> Iret_12__net_state
rarc_5_6_1__run_steps_net pg [] s = s
rarc_5_6_1__run_steps_net pg (SApply ev :: ss) s = rarc_5_6_1__run_steps_net pg ss (rarc_5_6_4__apply_tms_net pg ev s)
rarc_5_6_1__run_steps_net pg (SPump fuel :: ss) s = rarc_5_6_1__run_steps_net pg ss (fst (rarc_5_6_6__pump_tms_net pg fuel s))

--@spec [RARC.5.6.1]
||| The steps, in order, on FireLoopTms's engine.
public export
rarc_5_6_1__run_steps_tms : Lcyc_3_2_1__program -> List Rarc_5_6_1__step -> Iret_12__state -> Iret_12__state
rarc_5_6_1__run_steps_tms pg [] s = s
rarc_5_6_1__run_steps_tms pg (SApply ev :: ss) s = rarc_5_6_1__run_steps_tms pg ss (rarc_5_6_4__apply pg ev s)
rarc_5_6_1__run_steps_tms pg (SPump fuel :: ss) s = rarc_5_6_1__run_steps_tms pg ss (fst (rarc_5_6_6__pump_tms pg fuel s))

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.1]
||| ANY SEQUENCE OF INPUTS AND PUMPS keeps the agreement, whatever the
||| cadence: each input agrees, each pump agrees.
export
rlow_4_2_1__steps_agree : (pg : Lcyc_3_2_1__program) -> (steps : List Rarc_5_6_1__step) ->
                          (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                          Rlow_4_2_1__agree pg wm net toks ->
                          (wm' ** net' ** toks' ** rows' ** ( rarc_5_6_1__run_steps_net pg steps (MkTmsNet (MkEngine wm net) rows) = MkTmsNet (MkEngine wm' net') rows'
                                                            , rarc_5_6_1__run_steps_tms pg steps (MkTms (MkState wm toks) rows) = MkTms (MkState wm' toks') rows'
                                                            , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__steps_agree pg [] wm net toks rows ag = (wm ** net ** toks ** rows ** (Refl, Refl, ag))
rlow_4_2_1__steps_agree pg (SApply ev :: ss) wm net toks rows ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** (aN, aF, ag1)) = rlow_4_2_1__apply_tms_agree pg ev wm net toks rows ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** (rN, rF, ag2)) = rlow_4_2_1__steps_agree pg ss wm1 net1 toks1 rows1 ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** ( trans (cong (rarc_5_6_1__run_steps_net pg ss) aN) rN
                                          , trans (cong (rarc_5_6_1__run_steps_tms pg ss) aF) rF
                                          , ag2 ))
rlow_4_2_1__steps_agree pg (SPump fuel :: ss) wm net toks rows ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** h ** n ** (pN, pF, ag1)) = rlow_4_2_1__run_tms_agree pg fuel wm net toks rows ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** (rN, rF, ag2)) = rlow_4_2_1__steps_agree pg ss wm1 net1 toks1 rows1 ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** ( trans (cong (\t => rarc_5_6_1__run_steps_net pg ss (fst t)) pN) rN
                                          , trans (cong (\t => rarc_5_6_1__run_steps_tms pg ss (fst t)) pF) rF
                                          , ag2 ))

-- ---------------------------------------------------------------------
-- The pump, traced
-- ---------------------------------------------------------------------

--@spec [IRET.11.4]
||| One firing, naming what fired: the terminal ordinal and the fired
||| match's fact ids, with the engine after it.
public export
iret_11_4__fire_tms_net : Lcyc_3_2_1__program -> Iret_12__net_state -> Maybe (Nat, List Nat, Iret_12__net_state)
iret_11_4__fire_tms_net pg (MkTmsNet eng rows) = case iret_11_1__select (nchains (enet eng)) of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (nchains (enet eng)) of
    Nothing => Nothing
    Just c => case rarc_5_6_5__nth j (cacts c) of
      Nothing => Nothing
      Just a  => Just (r, iret_11_3__fact_ids (atuple a), rarc_5_6_7__do_actions_tms_net pg r a (cactions c) (MkTmsNet (idat_6_2_2__mark_net r j eng) rows))

--@derives [IRET.11.4]
||| The named firing is the firing.
export
iret_11_4__fire_tms_net_step : (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) ->
                               map (\t => snd (snd t)) (iret_11_4__fire_tms_net pg s) = iret_11_4__step_tms_net pg s
iret_11_4__fire_tms_net_step pg (MkTmsNet eng rows) with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__fire_tms_net_step pg (MkTmsNet eng rows) | Nothing = Refl
  iret_11_4__fire_tms_net_step pg (MkTmsNet eng rows) | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng)))
    iret_11_4__fire_tms_net_step pg (MkTmsNet eng rows) | (Just (r, j)) | Nothing = Refl
    iret_11_4__fire_tms_net_step pg (MkTmsNet eng rows) | (Just (r, j)) | (Just c) with (rarc_5_6_5__nth j (cacts c))
      iret_11_4__fire_tms_net_step pg (MkTmsNet eng rows) | (Just (r, j)) | (Just c) | Nothing = Refl
      iret_11_4__fire_tms_net_step pg (MkTmsNet eng rows) | (Just (r, j)) | (Just c) | (Just a) = Refl

--@spec [IRET.11.4]
--@spec [IRET.11.5]
||| The pump, traced: the firings in order, the engine, and the halt.
public export
iret_11_4__run_tms_net_traced : Lcyc_3_2_1__program -> Nat -> Iret_12__net_state -> (Iret_12__net_state, Iret_11_4__halt, List (Nat, List Nat))
iret_11_4__run_tms_net_traced pg Z s = (s, FuelOut, [])
iret_11_4__run_tms_net_traced pg (S fuel) s = case iret_11_4__fire_tms_net pg s of
  Nothing => (s, Quiescent, [])
  Just (r, ids, s') => let (t, h, tr) = iret_11_4__run_tms_net_traced pg fuel s' in (t, h, (r, ids) :: tr)

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE TRACE IS THE PUMP'S: the same engine, the same halt, and as many
||| firings as the pump counted. Proved by its own induction, not through
||| Rete/RunFold.idr's traced fold: this firing names two things (the ordinal
||| and the fact ids) where the fold's names one, and the regrouping lemma
||| the bridge needs -- `snd` at two pair types over one triple -- is one the
||| checker leaves as an unsolved constraint. The fold's unfoldings of the pump's run,
||| `iret_11_4__run_tms_net_nothing` / `_just`, are RunFold's through
||| Rete/NetworkTmsTransfer.idr's bridge, as before.
export
iret_11_4__run_tms_net_traced_core : (pg : Lcyc_3_2_1__program) -> (fuel : Nat) -> (s : Iret_12__net_state) ->
                                     (t ** h ** tr ** ( iret_11_4__run_tms_net_traced pg fuel s = (t, h, tr)
                                                      , iret_11_4__run_tms_net pg fuel s = (t, h, length tr) ))
iret_11_4__run_tms_net_traced_core pg Z s = (s ** FuelOut ** [] ** (Refl, Refl))
iret_11_4__run_tms_net_traced_core pg (S fuel) s with (iret_11_4__fire_tms_net pg s) proof e
  iret_11_4__run_tms_net_traced_core pg (S fuel) s | Nothing =
    let stepNothing : (iret_11_4__step_tms_net pg s = Nothing)
        stepNothing = trans (sym (iret_11_4__fire_tms_net_step pg s)) (cong (map (\t => snd (snd t))) e)
    in (s ** Quiescent ** [] ** (Refl, iret_11_4__run_tms_net_nothing pg fuel s stepNothing))
  iret_11_4__run_tms_net_traced_core pg (S fuel) s | (Just (r, ids, s')) =
    let stepJust : (iret_11_4__step_tms_net pg s = Just s')
        stepJust = trans (sym (iret_11_4__fire_tms_net_step pg s)) (cong (map (\t => snd (snd t))) e)
    in let (t ** h ** tr ** (tE, rE)) = iret_11_4__run_tms_net_traced_core pg fuel s'
       in (t ** h ** ((r, ids) :: tr) ** ( rewrite tE in Refl
                                         , iret_11_4__run_tms_net_just pg fuel s s' stepJust t h (length tr) rE ))

-- ---------------------------------------------------------------------
-- Inputs with ticks, in a fixture's cadence, on the clocked engine
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.2]
--@spec [RARC.5.6.1]
||| What a fixture issues to the clocked loop: an input of
||| Rete/TtlSweep.idr -- a data event or a clock tick -- or a pump under a
||| fuel.
public export
data Rarc_5_6_2__step : Type where
  SInput : Rarc_5_6_2__input -> Rarc_5_6_2__step
  SPumpT : Nat -> Rarc_5_6_2__step

--@spec [RARC.5.6.2]
--@spec [RARC.5.6.1]
||| The steps, in order, on the clocked network engine: an input through
||| the loop's steps before firing (the sweep, then the data event or the
||| tick), a pump through its run.
public export
rarc_5_6_2__run_steps_ttl_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Rarc_5_6_2__step -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_2__run_steps_ttl_net pg ttl [] cs = cs
rarc_5_6_2__run_steps_ttl_net pg ttl (SInput inp :: ss) cs = rarc_5_6_2__run_steps_ttl_net pg ttl ss (rarc_5_6_3__prepare_net pg ttl inp cs)
rarc_5_6_2__run_steps_ttl_net pg ttl (SPumpT fuel :: ss) cs = rarc_5_6_2__run_steps_ttl_net pg ttl ss (fst (iret_11_4__run_ttl_net pg ttl fuel cs))

--@spec [RARC.5.6.2]
--@spec [RARC.5.6.1]
||| The steps, in order, on Rete/TtlSweep.idr's clocked engine.
public export
rarc_5_6_2__run_steps_ttl : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Rarc_5_6_2__step -> Iret_19_3__clocked -> Iret_19_3__clocked
rarc_5_6_2__run_steps_ttl pg ttl [] cs = cs
rarc_5_6_2__run_steps_ttl pg ttl (SInput inp :: ss) cs = rarc_5_6_2__run_steps_ttl pg ttl ss (rarc_5_6_3__prepare pg ttl inp cs)
rarc_5_6_2__run_steps_ttl pg ttl (SPumpT fuel :: ss) cs = rarc_5_6_2__run_steps_ttl pg ttl ss (fst (iret_11_4__run_ttl pg ttl fuel cs))

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.2]
||| ANY SEQUENCE OF INPUTS, TICKS AND PUMPS keeps the agreement, with one
||| deadline table and one clock on both sides: each input agrees
||| (Rete/NetworkTtl.idr's `rlow_4_2_1__prepare_agree`), each pump agrees
||| (`rlow_4_2_1__run_ttl_agree`).
export
rlow_4_2_1__steps_ttl_agree : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (steps : List Rarc_5_6_2__step) ->
                              (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              (dl : Iret_4_3__deadlines) -> (c : Nat) -> Rlow_4_2_1__agree pg wm net toks ->
                              (wm' ** net' ** toks' ** rows' ** dl' ** c' **
                                ( rarc_5_6_2__run_steps_ttl_net pg ttl steps (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) = MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl' c'
                                , rarc_5_6_2__run_steps_ttl pg ttl steps (MkClocked (MkTms (MkState wm toks) rows) dl c) = MkClocked (MkTms (MkState wm' toks') rows') dl' c'
                                , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__steps_ttl_agree pg ttl [] wm net toks rows dl c ag = (wm ** net ** toks ** rows ** dl ** c ** (Refl, Refl, ag))
rlow_4_2_1__steps_ttl_agree pg ttl (SInput inp :: ss) wm net toks rows dl c ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** dl1 ** c1 ** (pN, pF, ag1)) = rlow_4_2_1__prepare_agree pg ttl inp wm net toks rows dl c ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** c2 ** (rN, rF, ag2)) = rlow_4_2_1__steps_ttl_agree pg ttl ss wm1 net1 toks1 rows1 dl1 c1 ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** c2 **
          ( trans (cong (rarc_5_6_2__run_steps_ttl_net pg ttl ss) pN) rN
          , trans (cong (rarc_5_6_2__run_steps_ttl pg ttl ss) pF) rF
          , ag2 ))
rlow_4_2_1__steps_ttl_agree pg ttl (SPumpT fuel :: ss) wm net toks rows dl c ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** dl1 ** h ** n ** (pN, pF, ag1)) = rlow_4_2_1__run_ttl_agree pg ttl fuel wm net toks rows dl c ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** c2 ** (rN, rF, ag2)) = rlow_4_2_1__steps_ttl_agree pg ttl ss wm1 net1 toks1 rows1 dl1 c ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** c2 **
          ( trans (cong (\t => rarc_5_6_2__run_steps_ttl_net pg ttl ss (fst t)) pN) rN
          , trans (cong (\t => rarc_5_6_2__run_steps_ttl pg ttl ss (fst t)) pF) rF
          , ag2 ))

-- ---------------------------------------------------------------------
-- The clocked pump, traced
-- ---------------------------------------------------------------------

--@spec [IRET.11.4]
||| One firing on the clocked engine, naming what fired: the terminal
||| ordinal and the fired match's facts -- the facts, not only their ids,
||| so a runner can evaluate what the firing's effects read -- with the
||| engine after it.
public export
iret_11_4__fire_ttl_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Iret_19_3__clocked_net -> Maybe (Nat, Iret_7_1__token, Iret_19_3__clocked_net)
iret_11_4__fire_ttl_net pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) = case iret_11_1__select (nchains (enet eng)) of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (nchains (enet eng)) of
    Nothing => Nothing
    Just ch => case rarc_5_6_5__nth j (cacts ch) of
      Nothing => Nothing
      Just a  => Just (r, atuple a, rarc_5_6_7__do_actions_ttl_net pg ttl r a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c))

--@derives [IRET.11.4]
||| The named firing is the firing.
export
iret_11_4__fire_ttl_net_step : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (s : Iret_19_3__clocked_net) ->
                               map (\t => snd (snd t)) (iret_11_4__fire_ttl_net pg ttl s) = iret_11_4__step_ttl_net pg ttl s
iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | Nothing = Refl
  iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng)))
    iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | (Just (r, j)) | Nothing = Refl
    iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | (Just (r, j)) | (Just ch) with (rarc_5_6_5__nth j (cacts ch))
      iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | (Just (r, j)) | (Just ch) | Nothing = Refl
      iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | (Just (r, j)) | (Just ch) | (Just a) = Refl

--@spec [IRET.11.4]
--@spec [IRET.11.5]
||| The clocked pump, traced: the firings in order, each with its facts,
||| the engine, and the halt.
public export
iret_11_4__run_ttl_net_traced : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_19_3__clocked_net -> (Iret_19_3__clocked_net, Iret_11_4__halt, List (Nat, Iret_7_1__token))
iret_11_4__run_ttl_net_traced pg ttl Z s = (s, FuelOut, [])
iret_11_4__run_ttl_net_traced pg ttl (S fuel) s = case iret_11_4__fire_ttl_net pg ttl s of
  Nothing => (s, Quiescent, [])
  Just (r, fs, s') => let (t, h, tr) = iret_11_4__run_ttl_net_traced pg ttl fuel s' in (t, h, (r, fs) :: tr)

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE TRACE IS THE CLOCKED PUMP'S: the same engine, the same halt, and
||| as many firings as the pump counted.
export
iret_11_4__run_ttl_net_traced_core : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (s : Iret_19_3__clocked_net) ->
                                     (t ** h ** tr ** ( iret_11_4__run_ttl_net_traced pg ttl fuel s = (t, h, tr)
                                                      , iret_11_4__run_ttl_net pg ttl fuel s = (t, h, length tr) ))
iret_11_4__run_ttl_net_traced_core pg ttl Z s = (s ** FuelOut ** [] ** (Refl, Refl))
iret_11_4__run_ttl_net_traced_core pg ttl (S fuel) s with (iret_11_4__fire_ttl_net pg ttl s) proof e
  iret_11_4__run_ttl_net_traced_core pg ttl (S fuel) s | Nothing =
    let stepNothing : (iret_11_4__step_ttl_net pg ttl s = Nothing)
        stepNothing = trans (sym (iret_11_4__fire_ttl_net_step pg ttl s)) (cong (map (\t => snd (snd t))) e)
    in (s ** Quiescent ** [] ** (Refl, iret_11_4__run_ttl_net_nothing pg ttl fuel s stepNothing))
  iret_11_4__run_ttl_net_traced_core pg ttl (S fuel) s | (Just (r, fs, s')) =
    let stepJust : (iret_11_4__step_ttl_net pg ttl s = Just s')
        stepJust = trans (sym (iret_11_4__fire_ttl_net_step pg ttl s)) (cong (map (\t => snd (snd t))) e)
    in let (t ** h ** tr ** (tE, rE)) = iret_11_4__run_ttl_net_traced_core pg ttl fuel s'
       in (t ** h ** ((r, fs) :: tr) ** ( rewrite tE in Refl
                                        , iret_11_4__run_ttl_net_just pg ttl fuel s s' stepJust t h (length tr) rE ))

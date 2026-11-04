-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE ONE RUN: the bounded fire loop of [IRET.11.4] / [IRET.11.5] as a fold
||| over any step function, with its one-firing unfoldings proved once; the
||| traced form of it over any firing that names what fired; and a simulation
||| lemma for a run shadowed by another through a projection. The per-engine
||| unfoldings are instances.
|||
||| NORMATIVE COMPANION to the six engines that define the loop by hand --
||| Rete/FireLoop.idr, Rete/FireLoopTms.idr, Rete/TtlSweep.idr,
||| Rete/Network.idr, Rete/NetworkTmsTransfer.idr, Rete/NetworkTtl.idr -- to
||| two traced runs (Rete/NetworkFrame.idr, Rete/NetworkFrameClocked.idr) and
||| to the ghost run (Rete/NetworkRefraction.idr). Rete/NetworkTraced.idr's
||| traced pump is not bridged: its firing names two things (the ordinal and
||| the fact ids) where the traced fold's names one, and the regrouping lemma
||| the bridge needs -- `snd` at two pair types over one triple -- is a
||| constraint Idris 2's checker leaves unsolved; its trace-is-the-pump keeps
||| its own induction and says so.
|||
||| WHY. Every engine of the lane runs the same loop: with fuel, fire once if
||| something is pending, else halt `Quiescent`; with no fuel, halt `FuelOut`;
||| count the firings. Each wrote the loop out, and each proved, by the same
||| `with` on its step, that a run from a quiescent state is the state and
||| that a run which fires is the firing then the rest -- eighteen proofs of
||| three facts across units M2 and N, seventeen of them derived here (the open finding of
||| the review's split note). This file proves the facts once, of
||| the fold. Each engine proves, by induction on the fuel, that its loop IS
||| the fold at its step -- the BRIDGE, beside its unfoldings -- and its
||| unfoldings are the generic ones through the bridge. No engine's
||| definition changes and no theorem's statement changes.
|||
||| PROVED.
|||
|||   * THE FOLD (`iret_11_4__run_by`) and its unfoldings: a run from a state
|||     the step refuses is that state, `Quiescent`, no firing
|||     (`iret_11_4__run_by_nothing`); a run from a state the step fires is the
|||     firing then the run from the state it leaves, one more firing counted
|||     (`iret_11_4__run_by_just`); and the two read on the state alone
|||     (`iret_11_4__run_by_fst_nothing`, `iret_11_4__run_by_fst_just`).
|||   * THE TRACED FOLD (`iret_11_4__trace_by`) over a firing that names what
|||     fired, and that its trace is the fold's run: given that the named
|||     firing's state is the step's, the same state, the same halt, as many
|||     firings as the run counted (`iret_11_4__trace_by_core`); unfolded one
|||     named firing at a time (`iret_11_4__trace_by_cons`,
|||     `iret_11_4__trace_by_end`).
|||   * SIMULATION (`iret_11_4__run_by_sim`): a step shadowed by another
|||     through a projection -- the projection of the one step's result is the
|||     other step at the projection -- runs shadowed by it, for any fuel: the
|||     projection of the one run's state is the other run's state.
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. Nothing of any engine.
||| It imports Rete/FireLoop.idr for the halt type and Rete/FireLoopTms.idr
||| for `Just`'s injectivity, and states nothing of a step. That an engine's
||| loop is this fold is that engine's bridge, proved where its loop is
||| defined or unfolded (`iret_11_4__run_by_fl`, `iret_11_4__run_tms_by`,
||| `iret_11_4__run_ttl_by`, `iret_11_4__run_net_by`, `iret_11_4__run_tms_net_by`,
||| `iret_11_4__run_ttl_net_by`; `iret_11_4__run_net_traced_by`,
||| `iret_11_4__run_ttl_net_traced_by`; `iret_11_4__run_g_by`). The bridges
||| carry the content; this file carries the shape.
module Rete.RunFold

import Rete.FireLoop
import Rete.FireLoopTms
import Data.List

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The fold
-- ---------------------------------------------------------------------

--@spec [IRET.11.4]
--@spec [IRET.11.5]
||| THE BOUNDED RUN over any step: fire while the step fires and the fuel
||| lasts; the state, which halt, how many firings.
public export
iret_11_4__run_by : {s : Type} -> (s -> Maybe s) -> Nat -> s -> (s, Iret_11_4__halt, Nat)
iret_11_4__run_by step Z x = (x, FuelOut, 0)
iret_11_4__run_by step (S fuel) x = case step x of
  Nothing => (x, Quiescent, 0)
  Just x' => let (t, h, n) = iret_11_4__run_by step fuel x' in (t, h, S n)

--@derives [IRET.11.4]
||| A run from a state the step refuses: the state, quiescent, no firing.
export
iret_11_4__run_by_nothing : {s : Type} -> (step : s -> Maybe s) -> (fuel : Nat) -> (x : s) -> step x = Nothing ->
                            iret_11_4__run_by step (S fuel) x = (x, Quiescent, 0)
iret_11_4__run_by_nothing step fuel x eq with (step x)
  iret_11_4__run_by_nothing step fuel x eq | Nothing = Refl
  iret_11_4__run_by_nothing step fuel x eq | (Just _) = absurd eq

--@derives [IRET.11.4]
||| A run from a state the step fires: the firing, then the run from the
||| state it leaves, one more firing counted.
export
iret_11_4__run_by_just : {s : Type} -> (step : s -> Maybe s) -> (fuel : Nat) -> (x, x' : s) -> step x = Just x' ->
                         (t : s) -> (h : Iret_11_4__halt) -> (n : Nat) -> iret_11_4__run_by step fuel x' = (t, h, n) ->
                         iret_11_4__run_by step (S fuel) x = (t, h, S n)
iret_11_4__run_by_just step fuel x x' eq t h n rr with (step x)
  iret_11_4__run_by_just step fuel x x' eq t h n rr | Nothing = absurd (sym eq)
  iret_11_4__run_by_just step fuel x x' eq t h n rr | (Just x'') = rewrite iret_11_4__just_inj eq in rewrite rr in Refl

--@derives [IRET.11.4]
||| The state alone: a run that cannot fire returns its state.
export
iret_11_4__run_by_fst_nothing : {s : Type} -> (step : s -> Maybe s) -> (fuel : Nat) -> (x : s) -> step x = Nothing ->
                                fst (iret_11_4__run_by step (S fuel) x) = x
iret_11_4__run_by_fst_nothing step fuel x eq = cong fst (iret_11_4__run_by_nothing step fuel x eq)

--@derives [IRET.11.4]
||| The state alone: a run that fires continues from the fired state with
||| one less fuel.
export
iret_11_4__run_by_fst_just : {s : Type} -> (step : s -> Maybe s) -> (fuel : Nat) -> (x, x' : s) -> step x = Just x' ->
                             fst (iret_11_4__run_by step (S fuel) x) = fst (iret_11_4__run_by step fuel x')
iret_11_4__run_by_fst_just step fuel x x' eq with (iret_11_4__run_by step fuel x') proof rr
  iret_11_4__run_by_fst_just step fuel x x' eq | (t, h, n) = cong fst (iret_11_4__run_by_just step fuel x x' eq t h n rr)

-- ---------------------------------------------------------------------
-- The traced fold
-- ---------------------------------------------------------------------

--@spec [IRET.11.4]
--@spec [IRET.11.5]
||| THE BOUNDED RUN, TRACED, over any firing that names what fired: what
||| fired, in order, with the state and the halt.
public export
iret_11_4__trace_by : {s, a : Type} -> (s -> Maybe (a, s)) -> Nat -> s -> (s, Iret_11_4__halt, List a)
iret_11_4__trace_by fire Z x = (x, FuelOut, [])
iret_11_4__trace_by fire (S fuel) x = case fire x of
  Nothing => (x, Quiescent, [])
  Just (r, x') => let (t, h, tr) = iret_11_4__trace_by fire fuel x' in (t, h, r :: tr)

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE TRACE IS THE RUN'S: when the named firing's state is the step's, the
||| traced fold and the fold reach the same state with the same halt, and the
||| run counts as many firings as the trace names.
export
iret_11_4__trace_by_core : {s, a : Type} -> (fire : s -> Maybe (a, s)) -> (step : s -> Maybe s) ->
                           ((y : s) -> map snd (fire y) = step y) -> (fuel : Nat) -> (x : s) ->
                           (t : s ** (h : Iret_11_4__halt ** (tr : List a **
                              ( iret_11_4__trace_by fire fuel x = (t, h, tr)
                              , iret_11_4__run_by step fuel x = (t, h, length tr) ))))
iret_11_4__trace_by_core fire step fs Z x = (x ** (FuelOut ** ([] ** (Refl, Refl))))
iret_11_4__trace_by_core fire step fs (S fuel) x with (fire x) proof e
  iret_11_4__trace_by_core fire step fs (S fuel) x | Nothing =
    (x ** (Quiescent ** ([] ** (Refl, iret_11_4__run_by_nothing step fuel x (trans (sym (fs x)) (cong (map snd) e))))))
  iret_11_4__trace_by_core fire step fs (S fuel) x | (Just (r, x')) =
    let (t ** (h ** (tr ** (tE, rE)))) = iret_11_4__trace_by_core fire step fs fuel x'
    in (t ** (h ** ((r :: tr) ** ( rewrite tE in Refl
                                 , iret_11_4__run_by_just step fuel x x' (trans (sym (fs x)) (cong (map snd) e)) t h (length tr) rE ))))

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE TRACED FOLD UNFOLDS ONE NAMED FIRING AT A TIME: a firing that resolves
||| prepends what it named to the trace of the run from the state it leaves.
export
iret_11_4__trace_by_cons : {s, a : Type} -> (fire : s -> Maybe (a, s)) -> (n : Nat) -> (x, x' : s) -> (r : a) ->
                           (t : s) -> (h : Iret_11_4__halt) -> (tr : List a) ->
                           fire x = Just (r, x') -> iret_11_4__trace_by fire n x' = (t, h, tr) ->
                           iret_11_4__trace_by fire (S n) x = (t, h, r :: tr)
iret_11_4__trace_by_cons fire n x x' r t h tr fe rest = rewrite fe in rewrite rest in Refl

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| A firing that resolves to nothing ends the traced fold `Quiescent`,
||| whatever fuel is left.
export
iret_11_4__trace_by_end : {s, a : Type} -> (fire : s -> Maybe (a, s)) -> (n : Nat) -> (x : s) ->
                          fire x = Nothing -> iret_11_4__trace_by fire (S n) x = (x, Quiescent, [])
iret_11_4__trace_by_end fire n x fe = rewrite fe in Refl

-- ---------------------------------------------------------------------
-- Simulation
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
||| A STEP SHADOWED THROUGH A PROJECTION RUNS SHADOWED: if the projection of
||| the one step's result is the other step at the projection, then for any
||| fuel the projection of the one run's state is the other run's state.
export
iret_11_4__run_by_sim : {s, s' : Type} -> (f : s -> s') -> (step : s -> Maybe s) -> (step' : s' -> Maybe s') ->
                        ((x : s) -> map f (step x) = step' (f x)) -> (fuel : Nat) -> (x : s) ->
                        f (fst (iret_11_4__run_by step fuel x)) = fst (iret_11_4__run_by step' fuel (f x))
iret_11_4__run_by_sim f step step' sim Z x = Refl
iret_11_4__run_by_sim f step step' sim (S fuel) x with (step x) proof sx
  iret_11_4__run_by_sim f step step' sim (S fuel) x | Nothing =
    sym (iret_11_4__run_by_fst_nothing step' fuel (f x) (trans (sym (sim x)) (cong (map f) sx)))
  iret_11_4__run_by_sim f step step' sim (S fuel) x | (Just x1) with (iret_11_4__run_by step fuel x1) proof rr
    iret_11_4__run_by_sim f step step' sim (S fuel) x | (Just x1) | (t, h, n) =
      trans (replace {p = \z => f (fst z) = fst (iret_11_4__run_by step' fuel (f x1))} rr (iret_11_4__run_by_sim f step step' sim fuel x1))
            (sym (iret_11_4__run_by_fst_just step' fuel (f x) (f x1) (trans (sym (sim x)) (cong (map f) sx))))

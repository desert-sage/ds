-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| `after` TIMERS, THE READING THE FIXTURE LOWERING WRITES: the timer fact a
||| parent's firing mints is stamped with the held sample, so [LTAC.3.3]'s
||| `fire_at` is the entry stamp plus the duration and the follow-up's guard
||| `monotonic_ns() >= t.fire_at` ([LTAC.3.4], [LTAC.5.3]) is the `dwell`
||| gate `t.dwell >= dur` ([LEXP.9.5.1]) that Rete/NetworkTimed.idr re-times
||| at every pump's entry; and the parent's captured bindings ride on the
||| timer's payload ([LTAC.3.5], [LCCO.5.4]): [LTAC.3.2] to [LTAC.3.6],
||| [LTAC.4.1], [LTAC.5.1], [LTAC.5.3], [LTAC.6.2.1], [LTAC.7.1],
||| [LTIM.2.8.2], [LTIM.2.8.4], [LTIM.2.8.6], [IRET.19.1].
|||
||| NORMATIVE COMPANION to Rete/NetworkTimed.idr, whose stamped RHS and
||| timed tests the statements here are over. This file holds no engine and
||| no lowering of its own: the fixture lowering writes an `after` clause
||| in this reading, and the runner executes what it writes on
||| Rete/NetworkTimed.idr's engine.
|||
||| THE READING. [LTAC.3.1] to [LTAC.3.4] say what the compiler does: the
||| parent's RHS gains an assertion of a timer fact with `fire_at:
||| monotonic_ns() + dur` ([LTAC.3.3]), and a follow-up rule
||| `$<rule>_after_<N>` ([LTAC.8.1]) matches that timer under
||| `monotonic_ns() >= t.fire_at` and ends its RHS by retracting it. THE
||| TIMER CARRIES NO `fire_at` SLOT HERE: a fact a pump mints is stamped
||| with the held monotonic sample (Rete/NetworkTimed.idr's stamped RHS,
||| [IRET.19.1] step 4, [LTIM.2.8.6]), and `monotonic_ns()` read in the same
||| firing is that same sample ([LTIM.2.8.4]), so `fire_at` is the stamp
||| plus the duration by construction, and the guard is `t.dwell >= dur`:
||| the leaf Rete/NetworkTimed.idr substitutes and re-times, on a single
||| positive pattern ([LTIM.2.6.1]). An emit whose payload reads the clock,
||| which this model's action type does not have, is not needed: the stamp
||| reads it. THE CAPTURES RIDE ON THE TIMER: where
||| [LTAC.3.5] carries the parent's bindings in a separate capture fact
||| joined on a correlation, the lowering folds them into the timer's
||| payload, one slot per read, snapshot at the parent's firing
||| ([LCCO.5.4]); both facts are compiler-owned and on no stream
||| ([RFCS.6a.5]), so the two are one at every pump boundary, and the fold
||| keeps the follow-up a single-positive-pattern chain. The compiler's
||| `$ClockTick` beta under the timer is the engine's pump-entry re-time,
||| as Rete/NetworkTimed.idr reads the fire guard.
|||
||| PROVED.
|||
|||   * THE GUARD IS THE GATE (`ltac_3_4__guard_is_due`): for every stamp
|||     `s`, every positive duration `S d` ([LTAC.7.1]: a zero delay is no
|||     timer) and every sample `m`, `t.dwell >= S d` from the stamp is
|||     `monotonic_ns() >= fire_at` with `fire_at = s + S d`
|||     (`ltac_3_4__due_b`). A Nat lemma; the `>=` against an absolute
|||     instant carried through ([LTAC.5.3]).
|||   * THE STAMP IS `fire_at` LESS THE DURATION (`ltac_3_3__stamp_is_fire_at`):
|||     an `Emit` into an explicit kind at the net's clock `m` stamps the
|||     fact it mints with `m` (Rete/EntryStamp.idr's assert for the explicit
|||     lifecycle always enters), and from that stamp the gate opens at
|||     `m + S d`: [LTAC.3.3]'s `monotonic_ns() + dur` under [LTIM.2.8.4].
|||   * THE GATE READS NO WALL CLOCK (`ltac_3_4__due_stamped_monotonic`): the
|||     gate form is a monotonic gate at every stamp table ([LTIM.2.8.2]); a
|||     transcription of Rete/NetworkTwoClocks.idr's, said so.
|||   * THE SNAPSHOT ([LTAC.3.5], [LCCO.5.4]; `ltac_3_5__capture_snapshot`):
|||     for every body expression of the fragment whose reads are all
|||     captured, its value over the timer at the follow-up's firing is its
|||     value over the parent's match at the parent's firing, given that the
|||     timer's payload slot at each capture's index holds what the parent's
|||     read gave. By induction on the expression.
|||   * EXECUTED, on literals: the runner's expression and the gate form
|||     decide alike on one timer at two samples
|||     (`ltac_3_4__guard_forms_agree`).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. How often a pump fires
||| the follow-up: nothing here runs an engine, and that a timer fires once,
||| on the first tick at or after `fire_at`, is held by the engine
||| comparison, which runs the `after` fixtures on the Idris model and on
||| libds. The value of the lowered guard on Integer literals: the runner
||| evaluates `dwell >= d` by Rete/Eval.idr's Integer order and the theorem
||| takes the gate form (`ltac_3_4__due_stamped`,
||| Rete/NetworkTwoClocks.idr's `dwell` gate); the two decide alike on the
||| executed point, as Rete/NetworkTimed.idr's `within` does, and are not
||| proved equal on variables. The value code's round trip through the
||| timer's payload (the snapshot's hypothesis), run as every code is. The
||| `as` key and its supersedure ([LTAC.2.2.1]), a nested clause
||| ([LTAC.6.2.2]), a `call` in a body, the capture fact as its own fact
||| ([LTAC.3.5]'s mechanism), `every`, [LTAC.4.4]'s persistence and the
||| sweep's placement are outside.
module Rete.NetworkTimer

-- The imports are Rete/NetworkWall.idr's whole: the executed point below
-- unfolds only through modules the file imports.
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
import Rete.NetworkTraced
import Rete.NetworkTick
import Rete.NetworkClocked
import Rete.NetworkEdges
import Rete.NetworkTwoClocks
import Rete.NetworkCooldown
import Rete.NetworkTimed
import Rete.EntryStamp
import Rete.Eval
import Rete.RunFold
import Rete.RateGate
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import TwoClocks
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.Maybe
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The timer and the guard [LTAC.3.2], [LTAC.3.4]
-- ---------------------------------------------------------------------

--@spec [LTAC.3.2]
--@spec [LTAC.4.1]
||| A TIMER FACT ON THE IDRIS MODEL'S ENGINE: kind 0 in the executed point's
||| kind order, key 1 (the empty tuple's code: the schema declares no `key`),
||| its payload the captured values coded -- what the parent's `emitx`
||| computes -- or 1 for a body that reads nothing ([LTAC.3.6]). No
||| `fire_at` slot: the entry stamp carries it (the header's reading); no
||| `corr`. An author writes no pattern on it ([LTAC.4.1]): the lowering
||| alone names the kind.
public export
ltac_3_2__capture_timer : Nat -> Lfac_1_7_1__fact
ltac_3_2__capture_timer p = MkFact 0 0 1 p

--@spec [LTAC.3.4]
--@spec [LTAC.5.3]
--@spec [LEXP.9.5.1]
||| THE FOLLOW-UP'S GUARD AS THE LOWERING WRITES IT: `t.dwell >= dur` on the
||| chain's one positive pattern, in the executed point's units (the
||| lowering scales the leaf to nanoseconds, as for every `dwell`):
||| [LTAC.3.4]'s `monotonic_ns() >= t.fire_at` with `fire_at` the stamp plus
||| the duration. `>=` against the absolute instant, as [LTAC.5.3] requires.
public export
ltac_3_4__guard_expr : Nat -> Iret_7_5__expr
ltac_3_4__guard_expr d = ECmp OpGe (EClock (ReadDwell 0)) (ELit (VInt (cast d)))

--@spec [LTAC.3.4]
--@spec [LTIM.2.8.2]
||| THE GUARD AS THE RUNNER BUILDS IT: Rete/NetworkTimed.idr's monotonic
||| timed test of the expression, which reads no `now()`.
public export
ltac_3_4__guard : Iret_7_6__env -> Nat -> Ltim_2_4_1__ttest
ltac_3_4__guard env d = ltim_2_8_2__mono_test_of env (ltac_3_4__guard_expr d)

--@spec [LTAC.3.4]
--@spec [LEXP.9.5.1]
--@spec [LTIM.2.8.6]
||| THE GUARD AS A GATE: Rete/NetworkTwoClocks.idr's `dwell >= d` over the
||| stamp table, the form the theorem takes -- `t.dwell` read off the
||| candidate's entry stamp, compared as naturals.
public export
ltac_3_4__due_stamped : Nat -> Ltim_2_4_1__ttest
ltac_3_4__due_stamped d = \st => lexp_9_5_1__dwell_gate st d

--@derives [LTIM.2.8.2]
--@derives [LTAC.3.4]
||| THE GATE FORM IS A MONOTONIC GATE at every stamp table: it reads the
||| monotonic sample and the stamps, nothing of the wall. C2's hypothesis,
||| inhabited; a transcription of Rete/NetworkTwoClocks.idr's, said so.
export
ltac_3_4__due_stamped_monotonic : (d : Nat) -> (st : Ltim_2_8_6__stamps) -> Ltim_2_8_2__monotonic (ltac_3_4__due_stamped d st)
ltac_3_4__due_stamped_monotonic d st = lexp_9_5_1__dwell_gate_monotonic st d

--@derives [LTAC.3.4]
--@derives [LEXP.9.5.1]
||| THE TWO FORMS DECIDE ALIKE ON THE EXECUTED POINT: the runner's
||| expression and the gate, on the timer stamped 0 with duration 5, both
||| admit at the sample 6 and refuse at the sample 3. Computed; what the
||| evaluator's Integer order gives on literals is run, not proved, as
||| Rete/NetworkTimed.idr's `within` is.
export
ltac_3_4__guard_forms_agree :
  ( ltac_3_4__guard ltim_2_4_1__wenv 5 [(0, 0)] (6, 0) [] (ltac_3_2__capture_timer 1) = True
  , ltac_3_4__guard ltim_2_4_1__wenv 5 [(0, 0)] (3, 0) [] (ltac_3_2__capture_timer 1) = False
  , ltac_3_4__due_stamped 5 [(0, 0)] (6, 0) [] (ltac_3_2__capture_timer 1) = True
  , ltac_3_4__due_stamped 5 [(0, 0)] (3, 0) [] (ltac_3_2__capture_timer 1) = False )
ltac_3_4__guard_forms_agree = (Refl, Refl, Refl, Refl)

-- ---------------------------------------------------------------------
-- The guard is the gate [LTAC.3.4], [LTAC.3.3], [LTAC.7.1]
-- ---------------------------------------------------------------------

--@spec [LTAC.3.4]
--@spec [LTAC.5.1]
||| THE GATE OF ONE TIMER: the follow-up's `monotonic_ns() >= t.fire_at` as
||| a function of the clock alone, `fire_at <= c`. `>=` against the
||| absolute instant, as [LTAC.5.3] requires.
public export
ltac_3_4__due_b : Nat -> Nat -> Bool
ltac_3_4__due_b fire_at c = iret_12__lte_b fire_at c

--@derives [LTAC.5.3]
||| The two Boolean orders on naturals -- the Prelude's `lte`, which the
||| `dwell` gate uses, and Rete/TmsRun.idr's `lte_b`, which the gate above
||| uses -- are one function.
export
ltac_5_3__lte_is_lte_b : (a, b : Nat) -> lte a b = iret_12__lte_b a b
ltac_5_3__lte_is_lte_b Z b = Refl
ltac_5_3__lte_is_lte_b (S a) Z = Refl
ltac_5_3__lte_is_lte_b (S a) (S b) = ltac_5_3__lte_is_lte_b a b

--@derives [LTAC.3.4]
--@derives [LTAC.3.3]
--@derives [LTAC.7.1]
--@derives [LEXP.9.5.1]
--@derives [LTAC.5.3]
||| THE GUARD IS THE GATE: for every stamp, every positive duration and
||| every sample, `dwell >= S d` from the stamp `s` is `monotonic_ns() >=
||| fire_at` with `fire_at = s + S d`, the gate above. The duration is
||| positive by [LTAC.7.1] (a zero delay is no timer; the compiler refuses
||| it), and that is what closes the case of a stamp ahead of the sample,
||| where `dwell` saturates at zero. By induction on the stamp and the
||| sample together.
export
ltac_3_4__guard_is_due : (s, d, m : Nat) -> lexp_9_5_1__dwell_gate_b s (S d) m = ltac_3_4__due_b (s + S d) m
ltac_3_4__guard_is_due Z d Z = Refl
ltac_3_4__guard_is_due Z d (S m) = ltac_5_3__lte_is_lte_b d m
ltac_3_4__guard_is_due (S s) d Z = Refl
ltac_3_4__guard_is_due (S s) d (S m) = ltac_3_4__guard_is_due s d m

--@derives [LTAC.3.3]
--@derives [LTIM.2.8.6]
--@derives [IRET.19.1]
||| A MINT INTO AN EXPLICIT KIND IS STAMPED WITH THE SAMPLE: the explicit
||| lifecycle's assert always enters ([IRET.19.1] step 4), so
||| Rete/EntryStamp.idr's stamp of the fresh id is the sample. Stated over a
||| lifecycle equal to `Explicit`, so that a program's `life pg k` can be
||| passed with its equation.
export
ltac_3_3__explicit_mint_is_stamped : (l : Lscp_1_3__lifecycle) -> l = Explicit -> (avoid : List Nat) -> (k, key, pay, m : Nat) ->
                                     (wm : Rarc_5_6_4__wm) -> (st : Ltim_2_8_6__stamps) ->
                                     ltim_2_8_6__stamp_of (lfac_2_5_3__fresh_id avoid wm) (ltim_2_8_6__assert_stamps l avoid k key pay m wm st) = Just m
ltac_3_3__explicit_mint_is_stamped Explicit Refl avoid k key pay m wm st =
  ltim_2_8_6__entered_is_stamped Explicit avoid k key pay m wm (wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay]) st Refl

--@derives [LTAC.3.3]
--@derives [LTIM.2.8.6]
--@derives [IRET.19.1]
--@derives [LTIM.2.8.4]
||| THE STAMP IS `fire_at` LESS THE DURATION. An `Emit` into an explicit
||| kind, run by the stamped RHS at the net's clock `m`, stamps the fact it
||| mints with `m`: Rete/EntryStamp.idr's assert for the explicit lifecycle
||| always enters ([IRET.19.1] step 4, [LTIM.2.8.6]). And from that stamp the
||| follow-up's gate is `monotonic_ns() >= m + S d`: [LTAC.3.3]'s `fire_at:
||| monotonic_ns() + dur`, the clock read in the firing being the held
||| sample `m` ([LTIM.2.8.4]). For every program, kind, sample, activation,
||| value function, working memory and stamp table.
export
ltac_3_3__stamp_is_fire_at : (pg : Lcyc_3_2_1__program) -> (k : Nat) -> life pg k = Explicit -> (m : Nat) -> (a : Iret_8_1__act) ->
                             (value : List Lfac_1_7_1__fact -> (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (st : Ltim_2_8_6__stamps) ->
                             ( ltim_2_8_6__stamp_of (lfac_2_5_3__fresh_id (iret_11_3__fact_ids (atuple a)) wm)
                                 (ltim_2_8_6__record_action pg m a (Emit k value) wm st) = Just m
                             , (d, c : Nat) -> lexp_9_5_1__dwell_gate_b m (S d) c = ltac_3_4__due_b (m + S d) c )
ltac_3_3__stamp_is_fire_at pg k lifeE m a value wm st =
  ( ltac_3_3__explicit_mint_is_stamped (life pg k) lifeE (iret_11_3__fact_ids (atuple a)) k (fst (value (atuple a))) (snd (value (atuple a))) m wm st
  , \d, c => ltac_3_4__guard_is_due m d c )

-- ---------------------------------------------------------------------
-- The captures ride on the timer [LTAC.3.5], [LCCO.5.4]
-- ---------------------------------------------------------------------

--@spec [LTAC.3.5]
||| THE CAPTURES of a body: the parent's slot reads, each by (binding,
||| key-or-payload, slot) over the parent's positive patterns, in the order
||| the body first reads them; a read's index in the list is the timer's
||| payload slot the lowering rewrites it to.
public export
Ltac_3_5__captures : Type
Ltac_3_5__captures = List (Nat, Bool, Nat)

--@spec [LTAC.3.5]
||| A read's index among the captures, or none.
public export
ltac_3_5__index : Ltac_3_5__captures -> (Nat, Bool, Nat) -> Maybe Nat
ltac_3_5__index [] r = Nothing
ltac_3_5__index (c :: cs) r = if c == r then Just 0 else map S (ltac_3_5__index cs r)

--@spec [LTAC.3.5]
--@spec [LCCO.5.4]
||| THE REWRITE of a body expression: every captured read becomes the
||| timer's payload slot at the capture's index -- the timer is the
||| follow-up's one bound fact, at rank 0 -- and the rest of the expression
||| stands. A read the captures do not hold is left as it is; the lowering
||| refuses such a body (`after:capture`).
public export
ltac_3_5__rewrite : Ltac_3_5__captures -> Iret_7_5__expr -> Iret_7_5__expr
ltac_3_5__rewrite caps (ELit v)         = ELit v
ltac_3_5__rewrite caps (ESlot b k s)    = case ltac_3_5__index caps (b, k, s) of
  Just i  => ESlot 0 False i
  Nothing => ESlot b k s
ltac_3_5__rewrite caps (EClock r)       = EClock r
ltac_3_5__rewrite caps (ECmp op l r)    = ECmp op (ltac_3_5__rewrite caps l) (ltac_3_5__rewrite caps r)
ltac_3_5__rewrite caps (EArith op l r)  = EArith op (ltac_3_5__rewrite caps l) (ltac_3_5__rewrite caps r)
ltac_3_5__rewrite caps (ENeg e)         = ENeg (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (EAnd l r)       = EAnd (ltac_3_5__rewrite caps l) (ltac_3_5__rewrite caps r)
ltac_3_5__rewrite caps (EOr l r)        = EOr (ltac_3_5__rewrite caps l) (ltac_3_5__rewrite caps r)
ltac_3_5__rewrite caps (ENot e)         = ENot (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (EIs neg s e)    = EIs neg s (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (ECoalesce x d)  = ECoalesce (ltac_3_5__rewrite caps x) (ltac_3_5__rewrite caps d)
ltac_3_5__rewrite caps (ECast f t e)    = ECast f t (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (EPath segs e)   = EPath segs (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (EHas segs e)    = EHas segs (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (ELen e)         = ELen (ltac_3_5__rewrite caps e)
ltac_3_5__rewrite caps (ELenStr e)      = ELenStr (ltac_3_5__rewrite caps e)

--@spec [LTAC.3.5]
--@spec [LTAC.3.6]
||| WHETHER A BODY EXPRESSION IS CAPTURED WHOLE: every read it makes is
||| among the captures, and it reads no clock (the lowering refuses a clock
||| read in a body: the runner has no sample at an action). A body reading
||| nothing is captured by the empty list ([LTAC.3.6]).
public export
ltac_3_5__captured : Ltac_3_5__captures -> Iret_7_5__expr -> Bool
ltac_3_5__captured caps (ELit v)         = True
ltac_3_5__captured caps (ESlot b k s)    = isJust (ltac_3_5__index caps (b, k, s))
ltac_3_5__captured caps (EClock r)       = False
ltac_3_5__captured caps (ECmp op l r)    = ltac_3_5__captured caps l && ltac_3_5__captured caps r
ltac_3_5__captured caps (EArith op l r)  = ltac_3_5__captured caps l && ltac_3_5__captured caps r
ltac_3_5__captured caps (ENeg e)         = ltac_3_5__captured caps e
ltac_3_5__captured caps (EAnd l r)       = ltac_3_5__captured caps l && ltac_3_5__captured caps r
ltac_3_5__captured caps (EOr l r)        = ltac_3_5__captured caps l && ltac_3_5__captured caps r
ltac_3_5__captured caps (ENot e)         = ltac_3_5__captured caps e
ltac_3_5__captured caps (EIs neg s e)    = ltac_3_5__captured caps e
ltac_3_5__captured caps (ECoalesce x d)  = ltac_3_5__captured caps x && ltac_3_5__captured caps d
ltac_3_5__captured caps (ECast f t e)    = ltac_3_5__captured caps e
ltac_3_5__captured caps (EPath segs e)   = ltac_3_5__captured caps e
ltac_3_5__captured caps (EHas segs e)    = ltac_3_5__captured caps e
ltac_3_5__captured caps (ELen e)         = ltac_3_5__captured caps e
ltac_3_5__captured caps (ELenStr e)      = ltac_3_5__captured caps e

--@spec [LTAC.3.5]
--@spec [LCCO.5.4]
||| THE SNAPSHOT HYPOTHESIS: the timer's payload slot at each capture's
||| index reads, under the follow-up's environment over the timer, what the
||| parent's read gave under the parent's environment over its match. What
||| the parent's `emitx` computes at its firing and codes, and the runner
||| decodes at the follow-up's: the value code's round trip, run and not
||| proved as every code is.
public export
Ltac_3_5__snapshot : Iret_7_6__env -> Iret_7_6__env -> List Lfac_1_7_1__fact -> List Lfac_1_7_1__fact -> Ltac_3_5__captures -> Type
Ltac_3_5__snapshot env env' timer tok caps =
  (b : Nat) -> (k : Bool) -> (s, i : Nat) -> ltac_3_5__index caps (b, k, s) = Just i ->
  iret_7_6__slot env timer 0 False i = iret_7_6__slot env' tok b k s

--@derives [LTAC.3.5]
--@derives [LCCO.5.4]
--@derives [LTAC.6.2.1]
||| THE SNAPSHOT: for every body expression captured whole, its value over
||| the timer at the follow-up's firing is its value over the parent's match
||| at the parent's firing, under the snapshot hypothesis -- "capture is
||| snapshot-always" ([LCCO.5.4]), and the body's actions have their own
||| semantics unchanged ([LTAC.6.2.1]). By induction on the expression,
||| through Rete/Eval.idr's evaluator, every constructor a clause.
export
ltac_3_5__capture_snapshot : (env, env' : Iret_7_6__env) -> (timer, tok : List Lfac_1_7_1__fact) -> (caps : Ltac_3_5__captures) ->
                             Ltac_3_5__snapshot env env' timer tok caps -> (e : Iret_7_5__expr) -> ltac_3_5__captured caps e = True ->
                             iret_7_6__eval env timer (ltac_3_5__rewrite caps e) = iret_7_6__eval env' tok e
ltac_3_5__capture_snapshot env env' timer tok caps snap (ELit v) h = Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ESlot b k s) h with (ltac_3_5__index caps (b, k, s)) proof pi
  ltac_3_5__capture_snapshot env env' timer tok caps snap (ESlot b k s) h | (Just i) = snap b k s i pi
  ltac_3_5__capture_snapshot env env' timer tok caps snap (ESlot b k s) h | Nothing = absurd h
ltac_3_5__capture_snapshot env env' timer tok caps snap (EClock r) h = absurd h
ltac_3_5__capture_snapshot env env' timer tok caps snap (ECmp op l r) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap l (lcyc_1_1__and_true_l _ _ h) in
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap r (lcyc_1_1__and_true_r _ _ h) in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EArith op l r) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap l (lcyc_1_1__and_true_l _ _ h) in
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap r (lcyc_1_1__and_true_r _ _ h) in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ENeg e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EAnd l r) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap l (lcyc_1_1__and_true_l _ _ h) in
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap r (lcyc_1_1__and_true_r _ _ h) in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EOr l r) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap l (lcyc_1_1__and_true_l _ _ h) in
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap r (lcyc_1_1__and_true_r _ _ h) in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ENot e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EIs neg s e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ECoalesce x d) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap x (lcyc_1_1__and_true_l _ _ h) in
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap d (lcyc_1_1__and_true_r _ _ h) in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ECast f t e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EPath segs e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (EHas segs e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ELen e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl
ltac_3_5__capture_snapshot env env' timer tok caps snap (ELenStr e) h =
  rewrite ltac_3_5__capture_snapshot env env' timer tok caps snap e h in Refl

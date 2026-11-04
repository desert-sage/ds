-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE `ts` SLOT AND THE NO-OP TEST: the cost of each reading, proved for a
||| stream of any length and executed.
|||
||| EVIDENCE, TIED TO NO CLAUSE. No clause says whether `ts` is among the
||| slots [LFAC.2.5.1]'s no-op test compares; every element here is `gap__`
||| and names the question. The candidate readings are those of
||| formal/alloy/counterexamples/ts_identity.als, which decides what each
||| costs on one trace of one identity; this module proves the cost for a
||| stream of any length, which a bounded search cannot state.
|||
||| THE STREAM. One `logical` entity (kind 0, key 1, payload 0) re-observed
||| by an input that supplies `ts` at source times 1, 2, ..., n -- an adapter
||| polling an unchanged reading, and [LADP.4.2.1] has every adapter supply
||| `ts` -- each step sampled at a monotonic clock equal to its source time.
|||
||| THE READINGS, on Rete/FireLoop.idr's assert ([IRET.19.1]; the Entity
||| lifecycle: same key and same payload is a no-op, a changed payload is a
||| retract-and-replace, [LFAC.2.5.1], [LFAC.2.5.3]):
|||   A   `ts` is outside the comparison: the comparand is the payload.
|||   B   `ts` is a payload slot, compared. FireLoop's payload is one natural
|||       and the stream holds the payload fixed, so the pair (payload, ts)
|||       varies with `ts` alone and the comparand is `ts`. The Alloy model's
|||       B1 and B2 coincide on an input that supplies `ts`; they differ on a
|||       rule's emit, of which this stream has none.
|||
||| PROVED, for every n:
|||   * under A the stream enters once -- one fact, id 0, its entry stamp the
|||     first sample ([LTIM.2.8.6]: a suppressed reassertion keeps its stamp)
|||     -- and `dwell` at the last sample is n (`gap__a_enters_once`,
|||     `gap__a_dwell`);
|||   * under B every step enters -- n + 1 entries, the live fact's stamp the
|||     last sample -- and `dwell` at the last sample is 0, however long the
|||     stream (`gap__b_enters_each`, `gap__b_dwell`).
||| EXECUTED, three re-observations, with one rule reading the entity and
||| emitting an explicit fact: under A the rule fires at the first observation
||| and never again, and one fact is emitted; under B it fires at every
||| observation and three are emitted -- the flicker [LFAC.2.5.1] names, and
||| the re-firing refraction_readings.tla's `reassert` stream shows for a
||| meaningful change (`gap__firings_three`).
|||
||| NOT MODELLED: a rule's emit (the Alloy model's B1 / B2 split), the
||| `then` and `latest` constructs that read `ts`, and the clocked network;
||| the cost here is at the engine's assert and the plain fire loop.
|||
||| RESTATED ON PURPOSE: `gap__same_fact_refl` is Rete/NetworkView.idr's
||| `lfac_2_5_4__same_fact_refl`; this module imports Rete/FireLoop and
||| Rete/EntryStamp alone, as the other standalone side proofs do.
module TsIdentity

import Rete.FireLoop
import Rete.EntryStamp
import TwoClocks
import Lcyc.Lemmas
import Data.List
import Data.Maybe
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The readings, on the engine's assert
-- ---------------------------------------------------------------------

--@gap
||| The two readings of `ts` in the no-op test.
public export
data Gap__reading = ReadA | ReadB

--@gap
||| The comparand of a re-observation with payload `pay` at source time `ts`:
||| the payload under A; under B the pair, which with the payload fixed is
||| `ts`.
public export
gap__comparand : Gap__reading -> (pay, ts : Nat) -> Nat
gap__comparand ReadA pay ts = pay
gap__comparand ReadB pay ts = ts

--@gap
||| A re-observation of the entity (kind 0, key 1, payload 0) at source time
||| `ts`, on the engine's assert; `Nothing` is a suppressed no-op.
public export
gap__reobserve : Gap__reading -> (ts : Nat) -> Rarc_5_6_4__wm -> Maybe Rarc_5_6_4__wm
gap__reobserve r ts wm = iret_19_1__assert_fact Entity [] 0 1 (gap__comparand r 0 ts) wm

--@gap
||| What the stream threads: working memory, the entry stamps, and how many
||| steps entered.
public export
record Gap__state where
  constructor MkGapState
  gwm      : Rarc_5_6_4__wm
  gstamps  : Ltim_2_8_6__stamps
  gentries : Nat

--@gap
||| What a step makes of the assert's outcome, from the memory before it,
||| the stamps and the entries so far: a no-op keeps all three; an entry
||| restamps the id the assert minted, the fresh one against the memory
||| before, as Rete/EntryStamp.idr's `ltim_2_8_6__after` does.
public export
gap__after : (ts : Nat) -> (prev : Rarc_5_6_4__wm) -> Ltim_2_8_6__stamps -> Nat -> Maybe Rarc_5_6_4__wm -> Gap__state
gap__after ts prev st e Nothing   = MkGapState prev st e
gap__after ts prev st e (Just wm') = MkGapState wm' (ltim_2_8_6__restamp wm' (lfac_2_5_3__fresh_id [] prev) ts st) (S e)

--@gap
||| One step at source time `ts`, sampled at `ts`.
public export
gap__step : Gap__reading -> (ts : Nat) -> Gap__state -> Gap__state
gap__step r ts s = gap__after ts (gwm s) (gstamps s) (gentries s) (gap__reobserve r ts (gwm s))

--@gap
||| A state is its three components.
export
gap__state_eta : (s : Gap__state) -> MkGapState (gwm s) (gstamps s) (gentries s) = s
gap__state_eta (MkGapState w st e) = Refl

--@gap
||| The stream to source time `n`: steps at 1, 2, ..., n in order, from an
||| empty working memory.
public export
gap__run : Gap__reading -> (n : Nat) -> Gap__state
gap__run r Z = MkGapState [] [] 0
gap__run r (S n) = gap__step r (S n) (gap__run r n)

-- ---------------------------------------------------------------------
-- Under A: once
-- ---------------------------------------------------------------------

--@gap
||| Under A a re-observation of the live entity is a no-op at any source
||| time: the comparand is the payload, and the payload is the live one.
export
gap__a_reobserve_noop : (ts : Nat) -> gap__reobserve ReadA ts [MkFact 0 0 1 0] = Nothing
gap__a_reobserve_noop ts = Refl

--@gap
||| UNDER A THE STREAM ENTERS ONCE: for every n, the state after source time
||| n + 1 is the first observation's -- one fact, id 0, stamped 1, one entry.
export
gap__a_enters_once : (n : Nat) -> gap__run ReadA (S n) = MkGapState [MkFact 0 0 1 0] [(0, 1)] 1
gap__a_enters_once Z = Refl
gap__a_enters_once (S n) = trans (cong (gap__step ReadA (S (S n))) (gap__a_enters_once n)) Refl

--@gap
||| And `dwell` at the last sample grows with the stream: n + 1 less the
||| stamp 1, whatever the wall clock reads.
export
gap__a_dwell : (n, w : Nat) -> lexp_9_5_1__dwell (S n, w) 1 = n
gap__a_dwell n w = minusZeroRight n

-- ---------------------------------------------------------------------
-- Under B: every time
-- ---------------------------------------------------------------------

--@gap
||| A natural is not its own successor, as the Boolean comparison the assert
||| makes.
export
gap__nat_neq_succ : (k : Nat) -> (k == S k) = False
gap__nat_neq_succ Z = Refl
gap__nat_neq_succ (S k) = gap__nat_neq_succ k

--@gap
||| A fact is the same fact as itself (Rete/NetworkView.idr's, restated).
export
gap__same_fact_refl : (f : Lfac_1_7_1__fact) -> lfac_2_5_4__same_fact f f = True
gap__same_fact_refl (MkFact i k y p) =
  rewrite lcyc_1_1__nat_eq_refl i in rewrite lcyc_1_1__nat_eq_refl k in
  rewrite lcyc_1_1__nat_eq_refl y in rewrite lcyc_1_1__nat_eq_refl p in Refl

--@gap
||| Under B a re-observation at the next source time replaces the live fact:
||| the old one goes, a fresh id is minted against the memory it is still in
||| ([LFAC.2.5.3]), and the new fact carries the new time.
export
gap__b_replaces : (i, k : Nat) ->
  gap__reobserve ReadB (S k) [MkFact i 0 1 k]
    = Just [MkFact (lfac_2_5_3__fresh_id [] [MkFact i 0 1 k]) 0 1 (S k)]
gap__b_replaces i k =
  rewrite gap__nat_neq_succ k in rewrite gap__same_fact_refl (MkFact i 0 1 k) in Refl

--@gap
||| One step under B from a state whose live fact carries time n + 1, with
||| any stamps and any count: the step enters -- the live fact carries n + 2
||| under the fresh id, its stamp is n + 2 at the head of the table, and the
||| count grows by one.
export
gap__b_step_enters : (n, i : Nat) -> (st : Ltim_2_8_6__stamps) -> (e : Nat) ->
  gap__step ReadB (S (S n)) (MkGapState [MkFact i 0 1 (S n)] st e)
    = MkGapState [MkFact (lfac_2_5_3__fresh_id [] [MkFact i 0 1 (S n)]) 0 1 (S (S n))]
                 (ltim_2_8_6__restamp [MkFact (lfac_2_5_3__fresh_id [] [MkFact i 0 1 (S n)]) 0 1 (S (S n))]
                                      (lfac_2_5_3__fresh_id [] [MkFact i 0 1 (S n)]) (S (S n)) st)
                 (S e)
gap__b_step_enters n i st e =
  cong (gap__after (S (S n)) [MkFact i 0 1 (S n)] st e) (gap__b_replaces i (S n))

--@gap
||| UNDER B EVERY STEP ENTERS: for every n, after source time n + 1 the live
||| fact carries time n + 1 under some id, its stamp is n + 1, and n + 1
||| steps entered.
export
gap__b_enters_each : (n : Nat) ->
  (i ** ( gwm (gap__run ReadB (S n)) = [MkFact i 0 1 (S n)]
        , ltim_2_8_6__stamp_of i (gstamps (gap__run ReadB (S n))) = Just (S n)
        , gentries (gap__run ReadB (S n)) = S n ))
gap__b_enters_each Z = (0 ** (Refl, Refl, Refl))
gap__b_enters_each (S n) =
  let (i ** (wmEq, _, enEq)) = gap__b_enters_each n
      rEq = the (gap__run ReadB (S n)
                 = MkGapState [MkFact i 0 1 (S n)] (gstamps (gap__run ReadB (S n))) (gentries (gap__run ReadB (S n))))
                (trans (sym (gap__state_eta (gap__run ReadB (S n))))
                       (cong (\w => MkGapState w (gstamps (gap__run ReadB (S n))) (gentries (gap__run ReadB (S n)))) wmEq))
      stepEq = the (gap__run ReadB (S (S n))
                    = MkGapState [MkFact (lfac_2_5_3__fresh_id [] [MkFact i 0 1 (S n)]) 0 1 (S (S n))]
                                 (ltim_2_8_6__restamp [MkFact (lfac_2_5_3__fresh_id [] [MkFact i 0 1 (S n)]) 0 1 (S (S n))]
                                                      (lfac_2_5_3__fresh_id [] [MkFact i 0 1 (S n)]) (S (S n))
                                                      (gstamps (gap__run ReadB (S n))))
                                 (S (gentries (gap__run ReadB (S n)))))
                   (trans (cong (gap__step ReadB (S (S n))) rEq)
                          (gap__b_step_enters n i (gstamps (gap__run ReadB (S n))) (gentries (gap__run ReadB (S n)))))
  in (lfac_2_5_3__fresh_id [] [MkFact i 0 1 (S n)] **
        ( cong gwm stepEq
        , trans (cong (\x => ltim_2_8_6__stamp_of (lfac_2_5_3__fresh_id [] [MkFact i 0 1 (S n)]) (gstamps x)) stepEq)
                (ltim_2_8_6__stamp_of_head (lfac_2_5_3__fresh_id [] [MkFact i 0 1 (S n)]) (S (S n)) _)
        , trans (cong gentries stepEq) (cong S enEq) ))

--@gap
||| And `dwell` at the last sample is 0, however long the stream: the live
||| fact's stamp is the sample itself.
export
gap__b_dwell : (n, w : Nat) -> lexp_9_5_1__dwell (S n, w) (S n) = 0
gap__b_dwell n w = sym (minusZeroN (S n))

-- ---------------------------------------------------------------------
-- Executed: one rule reading the entity
-- ---------------------------------------------------------------------

--@gap
||| The lifecycles: kind 0 is an entity, every other kind explicit.
public export
gap__life : Nat -> Lscp_1_3__lifecycle
gap__life Z = Entity
gap__life (S _) = Explicit

--@gap
||| The rule's guard: every match is admitted.
public export
gap__admits : List Lfac_1_7_1__fact -> Bool
gap__admits _ = True

--@gap
||| The rule's emitted value: key 0, payload 0, whatever it matched.
public export
gap__zero : List Lfac_1_7_1__fact -> (Nat, Nat)
gap__zero _ = (0, 0)

--@gap
||| One rule reading the entity (kind 0) and emitting an explicit fact of
||| kind 1. Every test and action is a named function, so that a literal
||| state names it and the evaluator has no lambda to compare.
public export
gap__program : Lcyc_3_2_1__program
gap__program = MkProgram gap__life [MkRule [0] gap__admits [] [Emit 1 gap__zero]]

--@gap
||| One more firing in a run's count.
public export
gap__bump : (Rarc_5_6_5__state, Nat) -> (Rarc_5_6_5__state, Nat)
gap__bump (s, n) = (s, S n)

--@gap
||| The fire loop run with fuel, counting its firings: Rete/FireLoop.idr's
||| `iret_11_4__run` without its halt, by pattern matching alone so that the
||| type-level evaluator runs it (Lcyc/WitnessProofs.idr executes
||| `iret_11_4__step_n` for the same reason).
public export
gap__run_count : Nat -> Rarc_5_6_5__state -> (Rarc_5_6_5__state, Nat)
gap__run_count Z st = (st, 0)
gap__run_count (S fuel) st = case iret_11_4__step gap__program st of
  Nothing  => (st, 0)
  Just st' => gap__bump (gap__run_count fuel st')

--@gap
||| A re-observation at `ts`, propagated, then the fire loop run to
||| quiescence: the state after and the number of firings.
public export
gap__pump : Gap__reading -> (ts : Nat) -> Rarc_5_6_5__state -> (Rarc_5_6_5__state, Nat)
gap__pump r ts st = case gap__reobserve r ts (wm st) of
  Nothing  => gap__run_count 4 st
  Just wm' => gap__run_count 4 (MkState wm' (rarc_5_6_5__propagate gap__program wm' (toks st)))

--@gap
||| A firing count in front of the counts of the pumps that follow.
public export
gap__consk : Nat -> (List Nat, Rarc_5_6_5__state) -> (List Nat, Rarc_5_6_5__state)
gap__consk k (ks, s) = (k :: ks, s)

--@gap
||| Re-observations at the given source times, each pumped to quiescence:
||| the firings per step, and the state at the end.
public export
gap__pumps : Gap__reading -> List Nat -> Rarc_5_6_5__state -> (List Nat, Rarc_5_6_5__state)
gap__pumps r [] st = ([], st)
gap__pumps r (t :: ts) st = case gap__pump r t st of
  (st', k) => gap__consk k (gap__pumps r ts st')

--@gap
||| The firings per step, and the explicit facts left live at the end.
public export
gap__tally : (List Nat, Rarc_5_6_5__state) -> (List Nat, Nat)
gap__tally (ks, s) = (ks, rarc_5_6_4__count_kind 1 (wm s))

--@gap
||| Three re-observations from the loaded program with no facts: the firings
||| per step, and the explicit facts left live at the end.
public export
gap__three : Gap__reading -> (List Nat, Nat)
gap__three r = gap__tally (gap__pumps r [1, 2, 3] (rarc_5_6_5__init_state gap__program []))

--@gap
||| THE FIRST OBSERVATION, STEP BY STEP: the loaded program holds no token;
||| the observation enters; propagation makes one unfired token; one
||| firing marks it and emits the kind-1 fact; the counted run fires once.
export
gap__first_observation :
  ( rarc_5_6_5__init_state gap__program [] = MkState [] [[]]
  , rarc_5_6_5__propagate gap__program [MkFact 0 0 1 0] [[]] = [[MkTok [MkFact 0 0 1 0] False False]]
  , iret_11_4__step gap__program (MkState [MkFact 0 0 1 0] [[MkTok [MkFact 0 0 1 0] False False]])
      = Just (MkState [MkFact 0 0 1 0, MkFact 1 1 0 0] [[MkTok [MkFact 0 0 1 0] True False]])
  , gap__run_count 4 (MkState [MkFact 0 0 1 0] [[MkTok [MkFact 0 0 1 0] False False]])
      = (MkState [MkFact 0 0 1 0, MkFact 1 1 0 0] [[MkTok [MkFact 0 0 1 0] True False]], 1)
  , gap__pump ReadA 1 (MkState [] [[]])
      = (MkState [MkFact 0 0 1 0, MkFact 1 1 0 0] [[MkTok [MkFact 0 0 1 0] True False]], 1) )
gap__first_observation = (Refl, Refl, Refl, Refl, Refl)

--@gap
||| EXECUTED: under A the rule fires at the first observation and never
||| again, one fact emitted; under B it fires at every observation, three
||| emitted.
export
gap__firings_three : (gap__three ReadA, gap__three ReadB) = (([1, 0, 0], 1), ([1, 1, 1], 3))
gap__firings_three = Refl

-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Two clocks, one sample per step, recorded and replayed ([LTIM.2.8]).
||| The two-clock draft's unbounded half; `formal/tla/clock_sample.tla` is the
||| bounded one.
|||
||| THE CLAUSES. [LTIM.2.8.1]: the engine holds a monotonic clock and a wall
||| clock, and both are inputs. [LTIM.2.8.4]: it samples both together when it
||| consumes an input and when a pump begins, and "every read between two
||| samples ... returns the most recent sample", "whatever order the engine
||| evaluates the expressions containing them in and however many times it
||| evaluates each". [LTIM.2.8.5]: a sample that differs from the one before
||| it is recorded, both values together, and a replay restores both.
||| [LTIM.2.8.2]: every relative-time mechanism reads the monotonic clock and
||| no other, whose zero is unspecified.
|||
||| WHAT IS PROVED, each for every input and not for a bound.
|||
|||   ORDER AND COUNT. Under a held sample an expression is worth one value,
|||   whichever operand is evaluated first and however many clock reads it
|||   makes, and evaluating it calls the clock source not once
|||   (`ltim_2_8_4__held_value`, `ltim_2_8_4__held_calls_nothing`). Under a
|||   read that calls the source, `now() - now()` is worth two values by order
|||   (`ltim_2_8_4__fresh_differs_by_order`): the reading the clause refuses.
|||
|||   REPLAY. A replay engine driven by the recorded atoms alone, its clocks
|||   starting ANYWHERE, holds at every step the sample the recording engine
|||   held (`ltim_2_8_5__replay_holds_what_was_held`), for every clock source
|||   and every run length.
|||
|||   INDEPENDENCE. `dwell`, `within`, TTL expiry, a timer and a cooldown are
|||   each a function of the monotonic sample: a wall clock set anywhere moves
|||   none of them, and moving the monotonic clock's zero moves none of them
|||   (`ltim_2_8_2__*_ignores_wall`, `ltim_2_8_2__*_ignores_zero`). This is the
|||   statement about TWO runs that a model checker of one run cannot make.
|||   The five `ignores_wall` are TRANSCRIPTIONS: each mechanism is defined on
|||   the monotonic component, so each is `Refl`, fails if the definition is
|||   changed to read the wall, and refutes nothing else. The five
|||   `ignores_zero` have content: a shift of the zero is carried through
|||   the subtraction by induction.
|||
||| WHAT THE REPLAY NEEDS, each shown by the engine that does otherwise.
||| [LTIM.2.8.5] requires three things an engine could omit, and omitting any
||| of them breaks the replay: the first sample is recorded, having no sample
||| before it to differ from (`ltim_2_8_5__first_sample_must_be_recorded`);
||| a sample is recorded before the input it was taken for
||| (`rfcs_10_5__clock_atom_goes_first`); and both values go on the atom
||| (`ltim_2_8_5__one_clock_is_not_enough`). And the wall clock moves what
||| reads it: a `now()` gate is true under one sample and false under
||| another that differs in the wall clock alone, which is [LTIM.2.8.3]'s
||| second paragraph computed (`ltim_2_8_3__wall_moves_a_now_gate`).
||| [LTIM.2.8.2]'s list of what reads the monotonic clock alone does not
||| name re-evaluation, and the mechanisms it does name are the ones proved
||| independent of the wall clock below.
|||
||| THE CLOCK SOURCE IS A FUNCTION OF THE CALL COUNT, not a constant, which is
||| Rete/FireClock.idr's device and is what makes a second call visible in a
||| result. A source that returned one value would make an engine that called
||| it at every read indistinguishable from one that held a sample.
|||
||| NOT MODELLED HERE. The entry stamp's own lifecycle ([LTIM.2.8.6]: which
||| asserts re-stamp) is `Rete/EntryStamp.idr`; the mock clock's mutations
||| ([NTST.3.1], [NTST.3.3]) are `MockClock.idr`; a checkpoint ([RFCS.9.4]) is
||| `CheckpointClocks.idr`; a sequence's window as event time ([LTHE.2.2.2])
||| is `EventTime.idr`; which members a query's discount admits after an
||| eviction ([LSIG.2.5.1]) is `SeriesWindow.idr`. Each imports this module.
||| The mechanisms below take the stamp as given, and a series window's
||| membership (`ltim_2_8_2__in_window`) is `within`'s formula on the sample
||| at which the value was absorbed: the discounted value is not modelled.
module TwoClocks

import Data.Nat
import Data.List
import Decidable.Equality

%default total
-- A lowercase name in a type is bound as an implicit unless this is off, a
-- global of that name notwithstanding: `ltim_2_8_1__ticking` in a witness's
-- type would be any clock source at all, and the witness a claim about every
-- one of them. Every binder below is written out.
%unbound_implicits off

-- ---------------------------------------------------------------------
-- Samples, the clock source, and the two ways to serve a read
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.1]
||| One sample of both clocks, taken together: (monotonic, wall).
public export
Ltim_2_8_1__sample : Type
Ltim_2_8_1__sample = (Nat, Nat)

--@spec [LTIM.2.8.1]
||| The clock source: what its n-th call returns. Any function at all: the
||| wall component may go down from one call to the next ([LTIM.2.8.3]), and
||| nothing below needs the monotonic one to go up.
public export
Ltim_2_8_1__source : Type
Ltim_2_8_1__source = Nat -> Ltim_2_8_1__sample

--@spec [LTIM.2.8.4]
||| How a clock read is served: from the count of calls made to the source so
||| far, the sample the read sees and the count afterwards.
public export
Ltim_2_8_4__reader : Type
Ltim_2_8_4__reader = Nat -> (Ltim_2_8_1__sample, Nat)

--@spec [LTIM.2.8.4]
||| THE RULED READER: a read returns the held sample and calls nothing. (Its
||| type is `Ltim_2_8_1__sample -> Ltim_2_8_4__reader`, written out so that
||| the definition takes both arguments and reduces on them.)
public export
ltim_2_8_4__held : (Nat, Nat) -> Nat -> ((Nat, Nat), Nat)
ltim_2_8_4__held s n = (s, n)

--@spec [LTIM.2.8.4]
||| THE REFUSED READER: a read calls the clock source.
public export
ltim_2_8_4__fresh : (Nat -> (Nat, Nat)) -> Nat -> ((Nat, Nat), Nat)
ltim_2_8_4__fresh src n = (src n, S n)

-- ---------------------------------------------------------------------
-- Expressions over clock reads, and their evaluation
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.4]
||| An expression that may read the clocks: `now()` ([LTIM.2.1.1]),
||| `monotonic_ns()` ([LTIM.2.2.1]), a value that reads neither, and any
||| binary operation over two of these. The operation is a parameter, so
||| what is proved of `Bin` is proved of every operator at once.
public export
data Ltim_2_8_4__expr : Type where
  Now  : Ltim_2_8_4__expr
  Mono : Ltim_2_8_4__expr
  Lit  : Nat -> Ltim_2_8_4__expr
  Bin  : (Nat -> Nat -> Nat) -> Ltim_2_8_4__expr -> Ltim_2_8_4__expr -> Ltim_2_8_4__expr

--@spec [LTIM.2.8.4]
||| What an expression is worth under one sample: the definition the clause
||| gives, in which no order and no count appears.
public export
ltim_2_8_4__worth : Ltim_2_8_1__sample -> Ltim_2_8_4__expr -> Nat
ltim_2_8_4__worth s Now = snd s
ltim_2_8_4__worth s Mono = fst s
ltim_2_8_4__worth s (Lit k) = k
ltim_2_8_4__worth s (Bin f a b) = f (ltim_2_8_4__worth s a) (ltim_2_8_4__worth s b)

--@spec [LTIM.2.8.4]
||| EVALUATION, as an engine does it: operand by operand, in an order
||| (`True`, the left operand first; `False`, the right), each clock read
||| served by the reader, the count of source calls threaded through. The
||| result is the value and the count afterwards.
public export
ltim_2_8_4__eval : Ltim_2_8_4__expr -> Ltim_2_8_4__reader -> Bool -> Nat -> (Nat, Nat)
ltim_2_8_4__eval Now rd ord n = (snd (fst (rd n)), snd (rd n))
ltim_2_8_4__eval Mono rd ord n = (fst (fst (rd n)), snd (rd n))
ltim_2_8_4__eval (Lit k) rd ord n = (k, n)
ltim_2_8_4__eval (Bin f a b) rd True n =
  ( f (fst (ltim_2_8_4__eval a rd True n))
      (fst (ltim_2_8_4__eval b rd True (snd (ltim_2_8_4__eval a rd True n))))
  , snd (ltim_2_8_4__eval b rd True (snd (ltim_2_8_4__eval a rd True n))) )
ltim_2_8_4__eval (Bin f a b) rd False n =
  ( f (fst (ltim_2_8_4__eval a rd False (snd (ltim_2_8_4__eval b rd False n))))
      (fst (ltim_2_8_4__eval b rd False n))
  , snd (ltim_2_8_4__eval a rd False (snd (ltim_2_8_4__eval b rd False n))) )

--@derives [LTIM.2.8.4]
||| ONE VALUE, WHATEVER THE ORDER: under a held sample, evaluation in either
||| order and from any call count yields what the expression is worth under
||| that sample. For every expression, every operator, every sample.
export
ltim_2_8_4__held_value : (s : Ltim_2_8_1__sample) -> (e : Ltim_2_8_4__expr) -> (ord : Bool) -> (n : Nat) ->
                         fst (ltim_2_8_4__eval e (ltim_2_8_4__held s) ord n) = ltim_2_8_4__worth s e
ltim_2_8_4__held_value s Now ord n = Refl
ltim_2_8_4__held_value s Mono ord n = Refl
ltim_2_8_4__held_value s (Lit k) ord n = Refl
ltim_2_8_4__held_value s (Bin f a b) True n =
  cong2 f (ltim_2_8_4__held_value s a True n)
          (ltim_2_8_4__held_value s b True (snd (ltim_2_8_4__eval a (ltim_2_8_4__held s) True n)))
ltim_2_8_4__held_value s (Bin f a b) False n =
  cong2 f (ltim_2_8_4__held_value s a False (snd (ltim_2_8_4__eval b (ltim_2_8_4__held s) False n)))
          (ltim_2_8_4__held_value s b False n)

--@derives [LTIM.2.8.4]
||| AND THE CLOCK SOURCE IS NOT CALLED: the count after evaluation is the
||| count before it. "Must not read either clock at any other time", for an
||| expression of any size.
export
ltim_2_8_4__held_calls_nothing : (s : Ltim_2_8_1__sample) -> (e : Ltim_2_8_4__expr) -> (ord : Bool) -> (n : Nat) ->
                                 snd (ltim_2_8_4__eval e (ltim_2_8_4__held s) ord n) = n
ltim_2_8_4__held_calls_nothing s Now ord n = Refl
ltim_2_8_4__held_calls_nothing s Mono ord n = Refl
ltim_2_8_4__held_calls_nothing s (Lit k) ord n = Refl
ltim_2_8_4__held_calls_nothing s (Bin f a b) True n =
  trans (ltim_2_8_4__held_calls_nothing s b True (snd (ltim_2_8_4__eval a (ltim_2_8_4__held s) True n)))
        (ltim_2_8_4__held_calls_nothing s a True n)
ltim_2_8_4__held_calls_nothing s (Bin f a b) False n =
  trans (ltim_2_8_4__held_calls_nothing s a False (snd (ltim_2_8_4__eval b (ltim_2_8_4__held s) False n)))
        (ltim_2_8_4__held_calls_nothing s b False n)

--@derives [LTIM.2.8.4]
||| HOWEVER MANY TIMES: the two orders agree with each other, from any two
||| call counts. An engine that evaluates one expression twice, in two
||| orders, at two points of a step, reads one value.
export
ltim_2_8_4__held_orders_agree : (s : Ltim_2_8_1__sample) -> (e : Ltim_2_8_4__expr) -> (n, m : Nat) ->
                                fst (ltim_2_8_4__eval e (ltim_2_8_4__held s) True n)
                                  = fst (ltim_2_8_4__eval e (ltim_2_8_4__held s) False m)
ltim_2_8_4__held_orders_agree s e n m =
  trans (ltim_2_8_4__held_value s e True n) (sym (ltim_2_8_4__held_value s e False m))

--@spec [LTIM.2.8.1]
||| A clock source that moves at every call: the n-th call returns (n, n).
public export
ltim_2_8_1__ticking : Nat -> (Nat, Nat)
ltim_2_8_1__ticking n = (n, n)

--@spec [LTIM.2.8.4]
||| `now() - now()`.
public export
ltim_2_8_4__now_minus_now : Ltim_2_8_4__expr
ltim_2_8_4__now_minus_now = Bin minus Now Now

--@derives [LTIM.2.8.4]
||| THE REFUSED READER IS ORDER-DEPENDENT: reading the source at every read,
||| `now() - now()` is 0 with the left operand first and 1 with the right.
||| The engine's evaluation order has become an observable, which is what
||| one sample per step rules out.
export
ltim_2_8_4__fresh_differs_by_order :
  Not (fst (ltim_2_8_4__eval ltim_2_8_4__now_minus_now (ltim_2_8_4__fresh ltim_2_8_1__ticking) True 0)
         = fst (ltim_2_8_4__eval ltim_2_8_4__now_minus_now (ltim_2_8_4__fresh ltim_2_8_1__ticking) False 0))
ltim_2_8_4__fresh_differs_by_order Refl impossible

--@derives [LTIM.2.8.4]
||| AND IT CALLS THE SOURCE: two reads, two calls.
export
ltim_2_8_4__fresh_calls_twice :
  snd (ltim_2_8_4__eval ltim_2_8_4__now_minus_now (ltim_2_8_4__fresh ltim_2_8_1__ticking) True 0) = 2
ltim_2_8_4__fresh_calls_twice = Refl

-- ---------------------------------------------------------------------
-- Steps: what is held, what is recorded, what a replay holds
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.4]
||| The samples a run holds, one per step: the source is called once as each
||| step begins, `n` being the calls made before the first. A step is a
||| sample point of [LTIM.2.8.4], an input consumed or a pump begun; the
||| steps are a list of them, and what a step does between its sample and
||| the next does not matter here, only that it samples once.
public export
ltim_2_8_4__samples : Ltim_2_8_1__source -> Nat -> List Nat -> List Ltim_2_8_1__sample
ltim_2_8_4__samples src n [] = []
ltim_2_8_4__samples src n (i :: is) = src n :: ltim_2_8_4__samples src (S n) is

--@spec [RFCS.10.1]
||| What the recorder writes: a `ClockAdvance` carrying a sample, or the
||| record of a step's input.
public export
data Rfcs_10_1__atom : Type where
  Advance : Ltim_2_8_1__sample -> Rfcs_10_1__atom
  Inject  : Nat -> Rfcs_10_1__atom

--@spec [LTIM.2.8.5]
||| The atoms of one step, in the clause's engine: the sample's `ClockAdvance`
||| if the sample is an observed value, THEN the input. `prev` is the sample
||| of the step before, and `Nothing` before the first step: the first sample
||| has no sample to differ from and is recorded.
public export
ltim_2_8_5__step_atoms : Maybe (Nat, Nat) -> (Nat, Nat) -> Nat -> List Rfcs_10_1__atom
ltim_2_8_5__step_atoms Nothing s i = [Advance s, Inject i]
ltim_2_8_5__step_atoms (Just p) s i with (decEq p s)
  ltim_2_8_5__step_atoms (Just p) s i | Yes _ = [Inject i]
  ltim_2_8_5__step_atoms (Just p) s i | No _ = [Advance s, Inject i]

--@spec [LTIM.2.8.5]
||| THE RECORDING of a run.
public export
ltim_2_8_5__record : Ltim_2_8_1__source -> Nat -> Maybe Ltim_2_8_1__sample -> List Nat -> List Rfcs_10_1__atom
ltim_2_8_5__record src n prev [] = []
ltim_2_8_5__record src n prev (i :: is) =
  ltim_2_8_5__step_atoms prev (src n) i ++ ltim_2_8_5__record src (S n) (Just (src n)) is

--@spec [RFCS.10.5]
||| THE REPLAY: the samples a replay engine holds, one per input it
||| consumes. It has the atoms and its own clocks, `cur`, and nothing else.
||| A `ClockAdvance` sets its clocks; an input is consumed under the clocks
||| as they then stand.
public export
rfcs_10_5__replay : Ltim_2_8_1__sample -> List Rfcs_10_1__atom -> List Ltim_2_8_1__sample
rfcs_10_5__replay cur [] = []
rfcs_10_5__replay cur (Advance s :: rest) = rfcs_10_5__replay s rest
rfcs_10_5__replay cur (Inject i :: rest) = cur :: rfcs_10_5__replay cur rest

--@derives [LTIM.2.8.5]
||| One step replayed, when the replay's clocks are the sample of the step
||| before: whether or not the step wrote a `ClockAdvance`, the replay holds
||| the step's sample and goes on with it.
export
ltim_2_8_5__step_replayed : (p, s : (Nat, Nat)) -> (i : Nat) -> (rest : List Rfcs_10_1__atom) ->
                            rfcs_10_5__replay p (ltim_2_8_5__step_atoms (Just p) s i ++ rest)
                              = s :: rfcs_10_5__replay s rest
ltim_2_8_5__step_replayed p s i rest with (decEq p s)
  ltim_2_8_5__step_replayed p s i rest | Yes prf = rewrite prf in Refl
  ltim_2_8_5__step_replayed p s i rest | No _ = Refl

--@derives [LTIM.2.8.5]
||| The replay of a run from its second step on, the replay's clocks being
||| the sample of the step before.
export
ltim_2_8_5__replay_from : (src : Ltim_2_8_1__source) -> (n : Nat) -> (p : Ltim_2_8_1__sample) -> (is : List Nat) ->
                          rfcs_10_5__replay p (ltim_2_8_5__record src n (Just p) is) = ltim_2_8_4__samples src n is
ltim_2_8_5__replay_from src n p [] = Refl
ltim_2_8_5__replay_from src n p (i :: is) =
  trans (ltim_2_8_5__step_replayed p (src n) i (ltim_2_8_5__record src (S n) (Just (src n)) is))
        (cong (src n ::) (ltim_2_8_5__replay_from src (S n) (src n) is))

--@derives [LTIM.2.8.5]
--@derives [RFCS.10.5]
--@derives [LDET.1.1]
||| REPLAY HOLDS WHAT WAS HELD: for every clock source, every run, and every
||| value the replay engine's clocks start at, the samples the replay holds
||| are the samples the recording engine held, step for step. With
||| `ltim_2_8_4__held_value`, every `now()`, every `monotonic_ns()` and every
||| expression over them is worth on replay what it was worth when recorded.
export
ltim_2_8_5__replay_holds_what_was_held : (src : Ltim_2_8_1__source) -> (n : Nat) -> (cur : Ltim_2_8_1__sample) -> (is : List Nat) ->
                                         rfcs_10_5__replay cur (ltim_2_8_5__record src n Nothing is)
                                           = ltim_2_8_4__samples src n is
ltim_2_8_5__replay_holds_what_was_held src n cur [] = Refl
ltim_2_8_5__replay_holds_what_was_held src n cur (i :: is) =
  cong (src n ::) (ltim_2_8_5__replay_from src (S n) (src n) is)

-- ---------------------------------------------------------------------
-- What [LTIM.2.8.5] requires, by the engines that do otherwise
-- ---------------------------------------------------------------------

--@spec [LTIM.2.8.1]
||| A clock source that does not move: every call returns (0, 0).
public export
ltim_2_8_1__still : Nat -> (Nat, Nat)
ltim_2_8_1__still n = (0, 0)

--@derives [LTIM.2.8.5]
||| THE FIRST SAMPLE MUST BE RECORDED -- "the first sample is an observed
||| clock value" ([LTIM.2.8.5]) -- and this is the engine that does not: it
||| compares the first sample with a starting value it assumes, (0, 0), and
||| writes nothing when they agree, which is `record` started at
||| `Just (0, 0)`. A platform whose clocks start there leaves a trace with no
||| `ClockAdvance`, and a replay engine whose clocks start at (7, 7) holds
||| (7, 7) in the first step where the recording held (0, 0).
export
ltim_2_8_5__first_sample_must_be_recorded :
  Not (rfcs_10_5__replay (7, 7) (ltim_2_8_5__record ltim_2_8_1__still 0 (Just (0, 0)) [1])
         = ltim_2_8_4__samples ltim_2_8_1__still 0 [1])
ltim_2_8_5__first_sample_must_be_recorded Refl impossible

--@spec [RFCS.10.5]
||| A recorder that writes a step's input BEFORE the step's `ClockAdvance`:
||| the shape [LTIM.2.8.5] forbids ("must record a sample before it records
||| the input or the pump boundary the sample was taken for"), and
||| RARC.5.8.10 with it. [RFCS.10.5] binds the replayer to apply a
||| `ClockAdvance` before the atom after it, which is why the order matters.
public export
rfcs_10_5__record_input_first : Ltim_2_8_1__source -> Nat -> List Nat -> List Rfcs_10_1__atom
rfcs_10_5__record_input_first src n [] = []
rfcs_10_5__record_input_first src n (i :: is) =
  Inject i :: Advance (src n) :: rfcs_10_5__record_input_first src (S n) is

--@derives [RFCS.10.5]
--@derives [LTIM.2.8.5]
||| THE CLOCK ATOM GOES FIRST. Written input-first, every sample is on the
||| trace and the replay still holds the wrong one: each input is consumed
||| under the clocks of the step before it.
export
rfcs_10_5__clock_atom_goes_first :
  Not (rfcs_10_5__replay (0, 0) (rfcs_10_5__record_input_first ltim_2_8_1__ticking 1 [1, 2])
         = ltim_2_8_4__samples ltim_2_8_1__ticking 1 [1, 2])
rfcs_10_5__clock_atom_goes_first Refl impossible

--@spec [LTIM.2.8.5]
||| A replay of atoms that carry the monotonic clock alone: a `ClockAdvance`
||| sets the monotonic clock and leaves the wall clock where it was.
public export
ltim_2_8_5__replay_mono_only : (Nat, Nat) -> List Rfcs_10_1__atom -> List (Nat, Nat)
ltim_2_8_5__replay_mono_only cur [] = []
ltim_2_8_5__replay_mono_only cur (Advance s :: rest) = ltim_2_8_5__replay_mono_only (fst s, snd cur) rest
ltim_2_8_5__replay_mono_only cur (Inject i :: rest) = cur :: ltim_2_8_5__replay_mono_only cur rest

--@spec [LTIM.2.8.3]
||| A clock source whose wall clock goes BACK: (1, 9) and then (2, 4).
public export
ltim_2_8_3__stepped_back : Nat -> (Nat, Nat)
ltim_2_8_3__stepped_back Z = (1, 9)
ltim_2_8_3__stepped_back (S k) = (2, 4)

--@derives [LTIM.2.8.5]
||| ONE CLOCK ON THE ATOM IS NOT ENOUGH: with the monotonic value restored
||| and the wall value not, a replay reads a `now()` the recording never
||| read.
export
ltim_2_8_5__one_clock_is_not_enough :
  Not (ltim_2_8_5__replay_mono_only (0, 0) (ltim_2_8_5__record ltim_2_8_3__stepped_back 0 Nothing [1, 2])
         = ltim_2_8_4__samples ltim_2_8_3__stepped_back 0 [1, 2])
ltim_2_8_5__one_clock_is_not_enough Refl impossible

--@derives [LTIM.2.8.5]
--@derives [LTIM.2.8.3]
||| AND WITH BOTH, A WALL CLOCK THAT GOES BACK IS REPLAYED AS IT WENT: the
||| replay holds (1, 9) and then (2, 4), the later step at the earlier
||| instant. The theorem above says so for every source; this is the run in
||| which it happens.
export
ltim_2_8_5__wall_goes_back_on_replay :
  rfcs_10_5__replay (0, 0) (ltim_2_8_5__record ltim_2_8_3__stepped_back 0 Nothing [1, 2]) = [(1, 9), (2, 4)]
ltim_2_8_5__wall_goes_back_on_replay = Refl

-- ---------------------------------------------------------------------
-- Relative time is a function of the monotonic sample
-- ---------------------------------------------------------------------

--@spec [LEXP.9.5.1]
||| `dwell`: the monotonic sample less the fact's entry stamp ([LTIM.2.8.6]).
public export
lexp_9_5_1__dwell : Ltim_2_8_1__sample -> (stamp : Nat) -> Nat
lexp_9_5_1__dwell s stamp = minus (fst s) stamp

--@spec [LTIM.2.7.1]
||| `within <dur>`: the fact entered less than `dur` ago.
public export
ltim_2_7_1__within : Ltim_2_8_1__sample -> (stamp : Nat) -> (dur : Nat) -> Bool
ltim_2_7_1__within s stamp dur = lt (minus (fst s) stamp) dur

--@spec [LTIM.2.8.2]
||| A deadline on the monotonic clock is reached: a TTL's expiry, an `after`
||| timer's `fire_at` ([LTAC.3.2]). Inclusive, as for expiry.
public export
ltim_2_8_2__reached : Ltim_2_8_1__sample -> (deadline : Nat) -> Bool
ltim_2_8_2__reached s deadline = lte deadline (fst s)

--@spec [LTIM.2.8.2]
||| A cooldown has run: at least `window` since the last firing.
public export
ltim_2_8_2__cooled : Ltim_2_8_1__sample -> (last : Nat) -> (window : Nat) -> Bool
ltim_2_8_2__cooled s last window = lte window (minus (fst s) last)

--@spec [LTIM.2.8.2]
||| A series window's membership: a value absorbed at monotonic sample `at`
||| is in a window of `w` at the sample `s` while it entered less than `w`
||| ago -- `within`'s formula on the sample at which it was absorbed. A
||| TRANSCRIPTION, as the four mechanisms above are.
public export
ltim_2_8_2__in_window : Ltim_2_8_1__sample -> (at : Nat) -> (w : Nat) -> Bool
ltim_2_8_2__in_window s at w = ltim_2_7_1__within s at w

--@derives [LTIM.2.8.2]
||| A WALL CLOCK SET ANYWHERE MOVES NO `dwell`.
export
ltim_2_8_2__dwell_ignores_wall : (m, w, w', stamp : Nat) ->
                                 lexp_9_5_1__dwell (m, w) stamp = lexp_9_5_1__dwell (m, w') stamp
ltim_2_8_2__dwell_ignores_wall m w w' stamp = Refl

--@derives [LTIM.2.8.2]
||| NOR ANY `within`.
export
ltim_2_8_2__within_ignores_wall : (m, w, w', stamp, dur : Nat) ->
                                  ltim_2_7_1__within (m, w) stamp dur = ltim_2_7_1__within (m, w') stamp dur
ltim_2_8_2__within_ignores_wall m w w' stamp dur = Refl

--@derives [LTIM.2.8.2]
||| NOR ANY DEADLINE: no TTL expires and no timer comes due because the host
||| clock was set.
export
ltim_2_8_2__reached_ignores_wall : (m, w, w', deadline : Nat) ->
                                   ltim_2_8_2__reached (m, w) deadline = ltim_2_8_2__reached (m, w') deadline
ltim_2_8_2__reached_ignores_wall m w w' deadline = Refl

--@derives [LTIM.2.8.2]
||| NOR ANY COOLDOWN.
export
ltim_2_8_2__cooled_ignores_wall : (m, w, w', last, window : Nat) ->
                                  ltim_2_8_2__cooled (m, w) last window = ltim_2_8_2__cooled (m, w') last window
ltim_2_8_2__cooled_ignores_wall m w w' last window = Refl

--@derives [LTIM.2.8.2]
||| NOR A SERIES WINDOW'S MEMBERSHIP.
export
ltim_2_8_2__in_window_ignores_wall : (m, w, w', at, win : Nat) ->
                                     ltim_2_8_2__in_window (m, w) at win = ltim_2_8_2__in_window (m, w') at win
ltim_2_8_2__in_window_ignores_wall m w w' at win = Refl

--@derives [LTIM.2.8.2]
||| Moving the zero: a difference of two readings taken `k` later on the
||| dial is the difference it was.
export
ltim_2_8_2__difference_ignores_zero : (k, a, b : Nat) -> minus (k + a) (k + b) = minus a b
ltim_2_8_2__difference_ignores_zero Z a b = Refl
ltim_2_8_2__difference_ignores_zero (S j) a b = ltim_2_8_2__difference_ignores_zero j a b

--@derives [LTIM.2.8.2]
||| And an order of two readings is the order it was.
export
ltim_2_8_2__order_ignores_zero : (k, a, b : Nat) -> lte (k + a) (k + b) = lte a b
ltim_2_8_2__order_ignores_zero Z a b = Refl
ltim_2_8_2__order_ignores_zero (S j) a b = ltim_2_8_2__order_ignores_zero j a b

--@derives [LTIM.2.8.2]
||| THE ZERO IS UNSPECIFIED, AND NO `dwell` DEPENDS ON IT: a monotonic clock
||| that counts from `k` later gives every fact the `dwell` it had. "Only the
||| difference between two of its readings has a meaning."
export
ltim_2_8_2__dwell_ignores_zero : (k, m, w, stamp : Nat) ->
                                 lexp_9_5_1__dwell (k + m, w) (k + stamp) = lexp_9_5_1__dwell (m, w) stamp
ltim_2_8_2__dwell_ignores_zero k m w stamp = ltim_2_8_2__difference_ignores_zero k m stamp

--@derives [LTIM.2.8.2]
export
ltim_2_8_2__within_ignores_zero : (k, m, w, stamp, dur : Nat) ->
                                  ltim_2_7_1__within (k + m, w) (k + stamp) dur = ltim_2_7_1__within (m, w) stamp dur
ltim_2_8_2__within_ignores_zero k m w stamp dur =
  cong (\d => lt d dur) (ltim_2_8_2__difference_ignores_zero k m stamp)

--@derives [LTIM.2.8.2]
export
ltim_2_8_2__reached_ignores_zero : (k, m, w, deadline : Nat) ->
                                   ltim_2_8_2__reached (k + m, w) (k + deadline) = ltim_2_8_2__reached (m, w) deadline
ltim_2_8_2__reached_ignores_zero k m w deadline = ltim_2_8_2__order_ignores_zero k deadline m

--@derives [LTIM.2.8.2]
export
ltim_2_8_2__cooled_ignores_zero : (k, m, w, last, window : Nat) ->
                                  ltim_2_8_2__cooled (k + m, w) (k + last) window = ltim_2_8_2__cooled (m, w) last window
ltim_2_8_2__cooled_ignores_zero k m w last window =
  cong (\d => lte window d) (ltim_2_8_2__difference_ignores_zero k m last)

--@derives [LTIM.2.8.2]
||| And a series window's membership: it is `within`'s, which ignores the
||| zero.
export
ltim_2_8_2__in_window_ignores_zero : (k, m, w, at, win : Nat) ->
                                     ltim_2_8_2__in_window (k + m, w) (k + at) win = ltim_2_8_2__in_window (m, w) at win
ltim_2_8_2__in_window_ignores_zero k m w at win = ltim_2_8_2__within_ignores_zero k m w at win

-- ---------------------------------------------------------------------
-- What the wall clock does move
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.1]
||| A time-dependent condition that reads `now()`: `now() > 5`.
public export
ltim_2_4_1__now_gate : (Nat, Nat) -> Bool
ltim_2_4_1__now_gate s = lt 5 (snd s)

--@derives [LTIM.2.8.3]
--@derives [LTIM.2.4.3]
||| THE WALL CLOCK MOVES A `now()` GATE, THE MONOTONIC CLOCK STANDING STILL:
||| the gate is true under one sample and false under another that differs
||| in the wall clock alone. [LTIM.2.8.3]: a comparison of `now()` against a
||| fixed instant "can become false again when the wall clock moves backward
||| across the instant"; [LTIM.2.4.3]: re-evaluation reads both clocks as
||| sampled. [LTIM.2.8.2] names what the wall clock does NOT move, and a
||| condition's re-evaluation is not in its list, as this witness shows.
export
ltim_2_8_3__wall_moves_a_now_gate :
  Not (ltim_2_4_1__now_gate (3, 6) = ltim_2_4_1__now_gate (3, 4))
ltim_2_8_3__wall_moves_a_now_gate Refl impossible

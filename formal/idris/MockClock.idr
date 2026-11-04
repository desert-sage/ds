-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The mock clock: what a test may do to the two clocks, and what the trace
||| then carries ([NTST.3.1], [NTST.3.3]). The two-clock draft's gap 2; the
||| question the lane asked of a mutation is settled by [NTST.3.3] as it now
||| reads.
|||
||| THE CLAUSES. [NTST.3.1]: a test moves the mock clock by setting the
||| monotonic clock to an absolute instant, by advancing both clocks by one
||| duration, or by setting the wall clock alone to any instant; a set below
||| the current monotonic value is refused once the engine has consumed its
||| first input, and taken before. [NTST.3.3]: a mutation sets the mock clock
||| and is not itself a sample -- it emits no event and records nothing; the
||| next input or pump samples the clock source, reads the value the
||| mutation left, and records it as a `ClockAdvance` when it differs from
||| the previous sample, so a test writes the trace a live run through the
||| same clock values writes, and two mutations between samples leave one
||| record. [LTIM.2.8.5]: a sample that differs from the one before it is
||| recorded, and a replay restores both clocks.
|||
||| WHAT IS PROVED, each for every input. The monotonic clock never decreases
||| across any mutation, and so across any run of them, once an input has been
||| consumed (`ntst_3_1__mono_never_decreases`, `ntst_3_1__run_never_decreases`);
||| an advance moves both clocks by one amount
||| (`ntst_3_1__advance_moves_both_alike`). Two recorders are stated side by
||| side: at SAMPLES, the clauses' own, where a move writes nothing and the
||| next input's sample is recorded if it differs; and at MUTATIONS, the
||| reading [NTST.3.3] refuses, where a move writes a `ClockAdvance` as it is
||| made. Under either, a replay from any starting clocks holds at every input
||| what the recording held (`ltim_2_8_5__mock_replay_at_samples`,
||| `ntst_3_3__mock_replay_at_mutations`): the choice between them was never
||| one of soundness, and the clause made it on the trace.
|||
||| WHAT IS REFUTED. An engine that takes every set puts the monotonic clock
||| below where it was (`ntst_3_1__unguarded_goes_back`). And the two
||| recorders leave different traces of one run: two moves and an input are
||| three atoms recorded at mutations and two recorded at samples
||| (`ntst_3_3__mock_traces_differ`), and the second is the trace a LIVE
||| engine leaves through the same clock values
||| (`ntst_3_3__live_trace_is_at_samples`): the clause's "a test writes the
||| trace a live run through the same clock values writes", computed, and
||| what the refused recorder would cost.
|||
||| THE MOCK CLOCK IS THE SAMPLE. In mock mode the engine's clocks are the
||| mock's, so an input is consumed under the mock's values as they stand:
||| `ntst_3_3__held` is the sample at each input. `TwoClocks.idr`'s recorder
||| and replayer are reused as they are: a step's atoms, and what a replay
||| holds, are its definitions.
|||
||| NOT MODELLED. `seq`, and the tick's event on the stream; the engine's
||| behaviour at the inputs themselves, which is the lane's elsewhere.
module MockClock

import Data.Nat
import Decidable.Equality
import TwoClocks

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The mock clock and its three mutations
-- ---------------------------------------------------------------------

--@spec [NTST.3.1]
||| The mock engine's clocks, and whether an input has been consumed.
public export
record Ntst_3_1__mock where
  constructor MkMock
  mono : Nat
  wall : Nat
  consumed : Bool

--@spec [NTST.3.1]
||| The three mutations: a set of the monotonic clock to an instant
||| (`ds_engine_clock_set`), an advance of both clocks by a duration
||| (`ds_engine_clock_advance`), a set of the wall clock alone
||| (`ds_engine_wall_clock_set`).
public export
data Ntst_3_1__mutation : Type where
  SetMono   : Nat -> Ntst_3_1__mutation
  AdvanceBy : Nat -> Ntst_3_1__mutation
  SetWall   : Nat -> Ntst_3_1__mutation

--@spec [NTST.3.1]
||| A set once an input has been consumed, decided on the comparison: taken
||| when the value is at or above the monotonic clock, refused below it.
public export
ntst_3_1__set_at : (v, mo, w : Nat) -> Dec (LTE mo v) -> Ntst_3_1__mock
ntst_3_1__set_at v mo w (Yes _) = MkMock v w True
ntst_3_1__set_at v mo w (No _) = MkMock mo w True

--@spec [NTST.3.1]
||| One mutation. A set before the first input takes any value; after it,
||| `ntst_3_1__set_at` decides.
public export
ntst_3_1__mutate : Ntst_3_1__mutation -> Ntst_3_1__mock -> Ntst_3_1__mock
ntst_3_1__mutate (SetMono v) (MkMock mo w True) = ntst_3_1__set_at v mo w (isLTE mo v)
ntst_3_1__mutate (SetMono v) (MkMock mo w False) = MkMock v w False
ntst_3_1__mutate (AdvanceBy d) (MkMock mo w c) = MkMock (mo + d) (w + d) c
ntst_3_1__mutate (SetWall v) (MkMock mo w c) = MkMock mo v c

--@spec [NTST.3.1]
||| A run of mutations, in order.
public export
ntst_3_1__run : List Ntst_3_1__mutation -> Ntst_3_1__mock -> Ntst_3_1__mock
ntst_3_1__run [] m = m
ntst_3_1__run (mu :: mus) m = ntst_3_1__run mus (ntst_3_1__mutate mu m)

-- ---------------------------------------------------------------------
-- The monotonic clock never decreases
-- ---------------------------------------------------------------------

--@derives [NTST.3.1]
||| A decided set never puts the monotonic clock below where it was.
export
ntst_3_1__set_at_lte : (v, mo, w : Nat) -> (d : Dec (LTE mo v)) -> LTE mo (mono (ntst_3_1__set_at v mo w d))
ntst_3_1__set_at_lte v mo w (Yes p) = p
ntst_3_1__set_at_lte v mo w (No _) = reflexive

--@derives [NTST.3.1]
--@derives [LTIM.2.8.2]
||| THE MONOTONIC CLOCK NEVER DECREASES across one mutation, once an input has
||| been consumed: for every mutation and every pair of clocks. [LTIM.2.8.2]'s
||| first sentence, on the mock; the refusal of [NTST.3.1] is how it is kept.
export
ntst_3_1__mono_never_decreases : (mu : Ntst_3_1__mutation) -> (mo, w : Nat) ->
                                 LTE mo (mono (ntst_3_1__mutate mu (MkMock mo w True)))
ntst_3_1__mono_never_decreases (SetMono v) mo w = ntst_3_1__set_at_lte v mo w (isLTE mo v)
ntst_3_1__mono_never_decreases (AdvanceBy d) mo w = lteAddRight mo
ntst_3_1__mono_never_decreases (SetWall v) mo w = reflexive

--@derives [NTST.3.1]
||| No mutation un-consumes: the state after one is some pair of clocks with
||| `consumed` still set.
export
ntst_3_1__set_at_shape : (v, mo, w : Nat) -> (d : Dec (LTE mo v)) ->
                         (mo' ** (w' ** ntst_3_1__set_at v mo w d = MkMock mo' w' True))
ntst_3_1__set_at_shape v mo w (Yes _) = (v ** (w ** Refl))
ntst_3_1__set_at_shape v mo w (No _) = (mo ** (w ** Refl))

--@derives [NTST.3.1]
export
ntst_3_1__mutate_shape : (mu : Ntst_3_1__mutation) -> (mo, w : Nat) ->
                         (mo' ** (w' ** ntst_3_1__mutate mu (MkMock mo w True) = MkMock mo' w' True))
ntst_3_1__mutate_shape (SetMono v) mo w = ntst_3_1__set_at_shape v mo w (isLTE mo v)
ntst_3_1__mutate_shape (AdvanceBy d) mo w = (mo + d ** (w + d ** Refl))
ntst_3_1__mutate_shape (SetWall v) mo w = (mo ** (v ** Refl))

--@derives [NTST.3.1]
--@derives [LTIM.2.8.2]
||| AND ACROSS ANY RUN: for every sequence of mutations from a state that has
||| consumed an input, the monotonic clock ends at or above where it began.
export
ntst_3_1__run_never_decreases : (mus : List Ntst_3_1__mutation) -> (mo, w : Nat) ->
                                LTE mo (mono (ntst_3_1__run mus (MkMock mo w True)))
ntst_3_1__run_never_decreases [] mo w = reflexive
ntst_3_1__run_never_decreases (mu :: mus) mo w =
  let (mo' ** (w' ** eq)) = ntst_3_1__mutate_shape mu mo w
      first : LTE mo mo'
      first = replace {p = \z => LTE mo (mono z)} eq (ntst_3_1__mono_never_decreases mu mo w)
  in replace {p = \z => LTE mo (mono (ntst_3_1__run mus z))} (sym eq)
       (transitive first (ntst_3_1__run_never_decreases mus mo' w'))

-- ---------------------------------------------------------------------
-- An advance moves both clocks by one amount
-- ---------------------------------------------------------------------

--@derives [NTST.3.1]
||| AN ADVANCE MOVES BOTH CLOCKS ALIKE: across it each clock has moved by the
||| duration, whatever the clocks were and whether or not an input has been
||| consumed.
export
ntst_3_1__advance_moves_both_alike : (d, mo, w : Nat) -> (c : Bool) ->
  ( minus (mono (ntst_3_1__mutate (AdvanceBy d) (MkMock mo w c))) mo = d
  , minus (wall (ntst_3_1__mutate (AdvanceBy d) (MkMock mo w c))) w = d )
ntst_3_1__advance_moves_both_alike d mo w c = (minusPlus mo, minusPlus w)

-- ---------------------------------------------------------------------
-- TEETH: the refusal, and an engine without it
-- ---------------------------------------------------------------------

--@spec [NTST.3.1]
||| An engine that takes every set, consumed or not.
public export
ntst_3_1__unguarded : Ntst_3_1__mutation -> Ntst_3_1__mock -> Ntst_3_1__mock
ntst_3_1__unguarded (SetMono v) (MkMock mo w c) = MkMock v w c
ntst_3_1__unguarded mu m = ntst_3_1__mutate mu m

--@derives [NTST.3.1]
||| WITHOUT THE REFUSAL THE MONOTONIC CLOCK GOES BACK: set to 3 at 5, after an
||| input, it reads below 5.
export
ntst_3_1__unguarded_goes_back :
  lt (mono (ntst_3_1__unguarded (SetMono 3) (MkMock 5 0 True))) 5 = True
ntst_3_1__unguarded_goes_back = Refl

--@derives [NTST.3.1]
||| BEFORE THE FIRST INPUT a set below the current value is taken: a test
||| fixes its epoch.
export
ntst_3_1__before_the_first_input : ntst_3_1__mutate (SetMono 3) (MkMock 5 0 False) = MkMock 3 0 False
ntst_3_1__before_the_first_input = Refl

--@derives [NTST.3.1]
||| AFTER IT the same set is refused and the clocks are as they were.
export
ntst_3_1__after_it : ntst_3_1__mutate (SetMono 3) (MkMock 5 0 True) = MkMock 5 0 True
ntst_3_1__after_it = Refl

-- ---------------------------------------------------------------------
-- A run as moves and inputs; what the recorder writes, two ways
-- ---------------------------------------------------------------------

--@spec [NTST.3.3]
||| A step of a mock run: a clock move, or an input.
public export
data Ntst_3_3__event : Type where
  Move  : Ntst_3_1__mutation -> Ntst_3_3__event
  Input : Nat -> Ntst_3_3__event

--@spec [NTST.3.3]
||| The sample the mock holds: its own clocks.
public export
ntst_3_3__cur : Ntst_3_1__mock -> Ltim_2_8_1__sample
ntst_3_3__cur m = (mono m, wall m)

--@spec [NTST.3.3]
||| Consuming an input: the clocks stand, and the engine has consumed one.
public export
ntst_3_3__consume : Ntst_3_1__mock -> Ntst_3_1__mock
ntst_3_3__consume m = MkMock (mono m) (wall m) True

--@spec [NTST.3.3]
||| THE SAMPLES HELD AT THE INPUTS of a run: one per input, the mock's clocks
||| as they then stand.
public export
ntst_3_3__held : Ntst_3_1__mock -> List Ntst_3_3__event -> List Ltim_2_8_1__sample
ntst_3_3__held m [] = []
ntst_3_3__held m (Move mu :: es) = ntst_3_3__held (ntst_3_1__mutate mu m) es
ntst_3_3__held m (Input i :: es) = ntst_3_3__cur m :: ntst_3_3__held (ntst_3_3__consume m) es

--@spec [NTST.3.3]
--@spec [LTIM.2.8.5]
||| RECORDED AT SAMPLES, the clauses' reading: a move writes nothing; at an
||| input the sample is recorded if it differs from the one recorded before,
||| by `TwoClocks.idr`'s step. `prev` is the last recorded sample, `Nothing`
||| before the first.
public export
ltim_2_8_5__record_at_samples : Ntst_3_1__mock -> Maybe Ltim_2_8_1__sample -> List Ntst_3_3__event -> List Rfcs_10_1__atom
ltim_2_8_5__record_at_samples m prev [] = []
ltim_2_8_5__record_at_samples m prev (Move mu :: es) = ltim_2_8_5__record_at_samples (ntst_3_1__mutate mu m) prev es
ltim_2_8_5__record_at_samples m prev (Input i :: es) =
  ltim_2_8_5__step_atoms prev (ntst_3_3__cur m) i ++ ltim_2_8_5__record_at_samples (ntst_3_3__consume m) (Just (ntst_3_3__cur m)) es

--@spec [NTST.3.3]
||| RECORDED AT MUTATIONS, the reading the clause refuses ("emits no event
||| and records nothing"): a move writes a `ClockAdvance` with both clocks
||| as it is made; an input writes its record, and before it the first
||| sample if nothing has been recorded yet. Kept so that what the clause
||| rules out is computed beside what it requires.
public export
ntst_3_3__record_at_mutations : Ntst_3_1__mock -> Maybe Ltim_2_8_1__sample -> List Ntst_3_3__event -> List Rfcs_10_1__atom
ntst_3_3__record_at_mutations m prev [] = []
ntst_3_3__record_at_mutations m prev (Move mu :: es) =
  Advance (ntst_3_3__cur (ntst_3_1__mutate mu m)) :: ntst_3_3__record_at_mutations (ntst_3_1__mutate mu m) (Just (ntst_3_3__cur (ntst_3_1__mutate mu m))) es
ntst_3_3__record_at_mutations m Nothing (Input i :: es) =
  Advance (ntst_3_3__cur m) :: Inject i :: ntst_3_3__record_at_mutations (ntst_3_3__consume m) (Just (ntst_3_3__cur m)) es
ntst_3_3__record_at_mutations m (Just p) (Input i :: es) =
  Inject i :: ntst_3_3__record_at_mutations (ntst_3_3__consume m) (Just p) es

-- ---------------------------------------------------------------------
-- Under either reading, a replay holds what was held
-- ---------------------------------------------------------------------

--@derives [LTIM.2.8.5]
||| Recorded at samples, a replay whose clocks are the last recorded sample
||| holds what the run held, from any state of the mock.
export
ltim_2_8_5__mock_replay_from : (p : Ltim_2_8_1__sample) -> (m : Ntst_3_1__mock) -> (es : List Ntst_3_3__event) ->
                               rfcs_10_5__replay p (ltim_2_8_5__record_at_samples m (Just p) es) = ntst_3_3__held m es
ltim_2_8_5__mock_replay_from p m [] = Refl
ltim_2_8_5__mock_replay_from p m (Move mu :: es) = ltim_2_8_5__mock_replay_from p (ntst_3_1__mutate mu m) es
ltim_2_8_5__mock_replay_from p m (Input i :: es) =
  trans (ltim_2_8_5__step_replayed p (ntst_3_3__cur m) i (ltim_2_8_5__record_at_samples (ntst_3_3__consume m) (Just (ntst_3_3__cur m)) es))
        (cong (ntst_3_3__cur m ::) (ltim_2_8_5__mock_replay_from (ntst_3_3__cur m) (ntst_3_3__consume m) es))

--@derives [LTIM.2.8.5]
--@derives [NTST.3.1]
||| RECORDED AT SAMPLES, A REPLAY FROM ANY STARTING CLOCKS HOLDS AT EVERY
||| INPUT WHAT THE RECORDING HELD, for every mock run of moves and inputs.
export
ltim_2_8_5__mock_replay_at_samples : (start : Ltim_2_8_1__sample) -> (m : Ntst_3_1__mock) -> (es : List Ntst_3_3__event) ->
                                     rfcs_10_5__replay start (ltim_2_8_5__record_at_samples m Nothing es) = ntst_3_3__held m es
ltim_2_8_5__mock_replay_at_samples start m [] = Refl
ltim_2_8_5__mock_replay_at_samples start m (Move mu :: es) = ltim_2_8_5__mock_replay_at_samples start (ntst_3_1__mutate mu m) es
ltim_2_8_5__mock_replay_at_samples start m (Input i :: es) =
  cong (ntst_3_3__cur m ::) (ltim_2_8_5__mock_replay_from (ntst_3_3__cur m) (ntst_3_3__consume m) es)

--@derives [NTST.3.3]
||| Recorded at mutations, a replay whose clocks are the mock's holds what the
||| run held: every move is written as it is made, so the replay's clocks are
||| the mock's at every input.
export
ntst_3_3__mock_replay_from : (m : Ntst_3_1__mock) -> (es : List Ntst_3_3__event) ->
                             rfcs_10_5__replay (ntst_3_3__cur m) (ntst_3_3__record_at_mutations m (Just (ntst_3_3__cur m)) es) = ntst_3_3__held m es
ntst_3_3__mock_replay_from m [] = Refl
ntst_3_3__mock_replay_from m (Move mu :: es) = ntst_3_3__mock_replay_from (ntst_3_1__mutate mu m) es
ntst_3_3__mock_replay_from m (Input i :: es) = cong (ntst_3_3__cur m ::) (ntst_3_3__mock_replay_from (ntst_3_3__consume m) es)

--@derives [NTST.3.3]
--@derives [LTIM.2.8.5]
||| RECORDED AT MUTATIONS, A REPLAY FROM ANY STARTING CLOCKS HOLDS AT EVERY
||| INPUT WHAT THE RECORDING HELD, for every mock run: the refused recorder
||| replays exactly too, so the clause's choice between the two is about the
||| trace a test leaves, not about soundness.
export
ntst_3_3__mock_replay_at_mutations : (start : Ltim_2_8_1__sample) -> (m : Ntst_3_1__mock) -> (es : List Ntst_3_3__event) ->
                                     rfcs_10_5__replay start (ntst_3_3__record_at_mutations m Nothing es) = ntst_3_3__held m es
ntst_3_3__mock_replay_at_mutations start m [] = Refl
ntst_3_3__mock_replay_at_mutations start m (Move mu :: es) = ntst_3_3__mock_replay_from (ntst_3_1__mutate mu m) es
ntst_3_3__mock_replay_at_mutations start m (Input i :: es) =
  cong (ntst_3_3__cur m ::) (ntst_3_3__mock_replay_from (ntst_3_3__consume m) es)

-- ---------------------------------------------------------------------
-- The two recorders leave different traces of one run; the clause's is the
-- live engine's
-- ---------------------------------------------------------------------

--@spec [NTST.3.3]
||| Two advances by 1 and then an input, from clocks at (0, 0) before any
||| input: two mutations between samples.
public export
ntst_3_3__two_moves_then_input : List Ntst_3_3__event
ntst_3_3__two_moves_then_input = [Move (AdvanceBy 1), Move (AdvanceBy 1), Input 7]

--@derives [NTST.3.3]
||| THE TRACES DIFFER: three atoms recorded at mutations, two at samples --
||| "two mutations between samples leave one record" under the clause's
||| recorder, and two under the refused one.
export
ntst_3_3__mock_traces_differ :
  Not (ntst_3_3__record_at_mutations (MkMock 0 0 False) Nothing ntst_3_3__two_moves_then_input
         = ltim_2_8_5__record_at_samples (MkMock 0 0 False) Nothing ntst_3_3__two_moves_then_input)
ntst_3_3__mock_traces_differ Refl impossible

--@spec [NTST.3.3]
||| A live clock source whose sample at the one input is (2, 2): the values
||| the mock run reaches.
public export
ntst_3_3__live_at_two : Nat -> (Nat, Nat)
ntst_3_3__live_at_two n = (2, 2)

--@derives [NTST.3.3]
--@derives [LTIM.2.8.5]
||| AND THE TRACE RECORDED AT SAMPLES IS THE LIVE ENGINE'S through the same
||| values: `TwoClocks.idr`'s recorder on that source, one input, writes the
||| same two atoms. "A test writes the trace a live run through the same
||| clock values writes", computed.
export
ntst_3_3__live_trace_is_at_samples :
  ltim_2_8_5__record ntst_3_3__live_at_two 0 Nothing [7]
    = ltim_2_8_5__record_at_samples (MkMock 0 0 False) Nothing ntst_3_3__two_moves_then_input
ntst_3_3__live_trace_is_at_samples = Refl

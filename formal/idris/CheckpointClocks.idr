-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| A checkpoint's clocks, and what a seek from it holds ([RFCS.9.4]).
|||
||| THE CLAUSE. [RFCS.9.4]: a reader may use a `Checkpoint` atom as a
||| random-access entry point: it restores working memory from the
||| `FactAssert` atoms after it, the cache, and both clocks from the
||| checkpoint ([LTIM.2.8.5]), then applies the stream events after it; a
||| restored fact enters with the entry stamp its atom carries ([RFCS.9.3]),
||| not the clock the checkpoint restored. The clocks a checkpoint carries
||| are not said to be any particular sample.
|||
||| WHAT IS PROVED, for every clock source, every position after a first
||| input and every run after it. A recording splits at a position into the
||| atoms before and the atoms after, the latter recorded from the count and
||| the held sample the earlier steps left (`rfcs_9_4__record_splits`). And a
||| seek from a checkpoint that carries THE HELD SAMPLE -- the sample the
||| engine held at the input before the checkpoint -- holds at every later
||| input what the recording held (`rfcs_9_4__seek_holds_what_was_held`).
||| The theorem is `TwoClocks.idr`'s replay from the second step on, applied.
||| Its hypothesis is what the two clauses give together: [RFCS.9.4] takes the
||| checkpoint's clocks as the engine's, and [LTIM.2.8.4] forbids the engine
||| to read a clock at any time but a sample point, so what a conforming
||| writer puts in a checkpoint is the sample it holds. The clause does not
||| say "the held sample" in those words; the premise is derived, not
||| assumed, and the witness below is what a writer that reads afresh costs.
|||
||| WHAT IS REFUTED, each by a witness, and each is why the premise matters.
||| A checkpoint carrying the monotonic clock alone leaves the wall clock
||| where the reader had it (`rfcs_9_4__mono_only_checkpoint_breaks`). A
||| checkpoint whose clocks were READ when it was written, against
||| [LTIM.2.8.4], and not held: the wall clock was elsewhere at that moment,
||| the next sample is the held one again so no `ClockAdvance` is written,
||| and the seek holds a value the recording never held
||| (`rfcs_9_4__fresh_checkpoint_breaks`).
|||
||| WHAT THE RE-STAMP WOULD COST, as two witnesses. [RFCS.9.4] has a restored
||| fact keep the entry stamp its atom carries ([LTIM.2.8.6]); a reader that
||| re-stamped it with the checkpoint's clock would read a `dwell` the
||| recording never read, and find it inside a `within` it had left
||| (`rfcs_9_4__restamped_dwell_differs`, `rfcs_9_4__restamped_within_reopens`).
|||
||| NOT SETTLED HERE. [RFCS.9.1a] says a trace that carries a checkpoint does
||| not support the determinism check at all, the mechanism being unsettled;
||| nothing here settles it. Working memory and the cache are not modelled,
||| nor a wall clock with no value (`Checkpoint.has_wall`, [LTIM.2.8.3]): a
||| sample here always has a wall component.
module CheckpointClocks

import Data.List
import Data.Nat
import Decidable.Equality
import TwoClocks

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The seek, and a position in a recording
-- ---------------------------------------------------------------------

--@spec [RFCS.9.4]
||| A SEEK: the reader's clocks are the checkpoint's, and it applies the
||| atoms after it. It is the replay, started at the checkpoint.
public export
rfcs_9_4__seek : Ltim_2_8_1__sample -> List Rfcs_10_1__atom -> List Ltim_2_8_1__sample
rfcs_9_4__seek cp atoms = rfcs_10_5__replay cp atoms

--@derives [RFCS.9.4]
||| The call count after some steps of a run.
public export
rfcs_9_4__count_after : Nat -> List Nat -> Nat
rfcs_9_4__count_after n [] = n
rfcs_9_4__count_after n (i :: is) = rfcs_9_4__count_after (S n) is

--@derives [RFCS.9.4]
||| The recorder's last recorded sample after some steps of a run.
public export
rfcs_9_4__held_after : Ltim_2_8_1__source -> Nat -> Maybe Ltim_2_8_1__sample -> List Nat -> Maybe Ltim_2_8_1__sample
rfcs_9_4__held_after src n prev [] = prev
rfcs_9_4__held_after src n prev (i :: is) = rfcs_9_4__held_after src (S n) (Just (src n)) is

--@derives [RFCS.9.4]
||| THE HELD SAMPLE at the last of one or more steps: what a checkpoint
||| written there carries, on the hypothesis the theorem needs.
public export
rfcs_9_4__held_at : Ltim_2_8_1__source -> Nat -> Nat -> List Nat -> Ltim_2_8_1__sample
rfcs_9_4__held_at src n i [] = src n
rfcs_9_4__held_at src n i (j :: js) = rfcs_9_4__held_at src (S n) j js

--@derives [RFCS.9.4]
||| After one or more steps the recorder's last recorded sample is the held
||| one, whatever it was before them.
export
rfcs_9_4__held_after_just : (src : Ltim_2_8_1__source) -> (n : Nat) -> (prev : Maybe Ltim_2_8_1__sample) -> (i : Nat) -> (is : List Nat) ->
                            rfcs_9_4__held_after src n prev (i :: is) = Just (rfcs_9_4__held_at src n i is)
rfcs_9_4__held_after_just src n prev i [] = Refl
rfcs_9_4__held_after_just src n prev i (j :: js) = rfcs_9_4__held_after_just src (S n) (Just (src n)) j js

-- ---------------------------------------------------------------------
-- The recording splits, and a seek holds what was held
-- ---------------------------------------------------------------------

--@derives [RFCS.9.4]
--@derives [LTIM.2.8.5]
||| THE RECORDING SPLITS at any position: the atoms of the steps before, then
||| the atoms of the steps after, recorded from the count and the held sample
||| the first steps left. For every source, every start and every two runs.
export
rfcs_9_4__record_splits : (src : Ltim_2_8_1__source) -> (n : Nat) -> (prev : Maybe Ltim_2_8_1__sample) -> (is1, is2 : List Nat) ->
                          ltim_2_8_5__record src n prev (is1 ++ is2)
                            = ltim_2_8_5__record src n prev is1
                              ++ ltim_2_8_5__record src (rfcs_9_4__count_after n is1) (rfcs_9_4__held_after src n prev is1) is2
rfcs_9_4__record_splits src n prev [] is2 = Refl
rfcs_9_4__record_splits src n prev (i :: is) is2 =
  trans (cong (ltim_2_8_5__step_atoms prev (src n) i ++) (rfcs_9_4__record_splits src (S n) (Just (src n)) is is2))
        (appendAssociative (ltim_2_8_5__step_atoms prev (src n) i)
                           (ltim_2_8_5__record src (S n) (Just (src n)) is)
                           (ltim_2_8_5__record src (rfcs_9_4__count_after (S n) is) (rfcs_9_4__held_after src (S n) (Just (src n)) is) is2))

--@derives [RFCS.9.4]
--@derives [LTIM.2.8.5]
--@derives [LTIM.2.8.4]
||| A SEEK FROM A CHECKPOINT THAT CARRIES THE HELD SAMPLE holds at every
||| later input what the recording held: for every clock source, every
||| position after a first input, and every run after it. `TwoClocks.idr`'s
||| `ltim_2_8_5__replay_from`, applied at the position. That the checkpoint
||| carries the held sample is [LTIM.2.8.4]'s: a conforming writer has no
||| other clock value to put in it.
export
rfcs_9_4__seek_holds_what_was_held : (src : Ltim_2_8_1__source) -> (n, i : Nat) -> (is1, is2 : List Nat) ->
  rfcs_9_4__seek (rfcs_9_4__held_at src n i is1)
                 (ltim_2_8_5__record src (rfcs_9_4__count_after n (i :: is1)) (rfcs_9_4__held_after src n Nothing (i :: is1)) is2)
    = ltim_2_8_4__samples src (rfcs_9_4__count_after n (i :: is1)) is2
rfcs_9_4__seek_holds_what_was_held src n i is1 is2 =
  replace {p = \h => rfcs_9_4__seek (rfcs_9_4__held_at src n i is1)
                                    (ltim_2_8_5__record src (rfcs_9_4__count_after n (i :: is1)) h is2)
                       = ltim_2_8_4__samples src (rfcs_9_4__count_after n (i :: is1)) is2}
    (sym (rfcs_9_4__held_after_just src n Nothing i is1))
    (ltim_2_8_5__replay_from src (rfcs_9_4__count_after n (i :: is1)) (rfcs_9_4__held_at src n i is1) is2)

-- ---------------------------------------------------------------------
-- TEETH: what a checkpoint must carry, by the two that do not
-- ---------------------------------------------------------------------

--@spec [RFCS.9.4]
||| A clock source that stands still at (3, 8).
public export
rfcs_9_4__steady : Nat -> (Nat, Nat)
rfcs_9_4__steady n = (3, 8)

--@spec [RFCS.9.4]
||| A reader whose checkpoint carries the monotonic clock alone: its wall
||| clock is whatever it had.
public export
rfcs_9_4__seek_mono_only : (cpmono, readerwall : Nat) -> List Rfcs_10_1__atom -> List Ltim_2_8_1__sample
rfcs_9_4__seek_mono_only cpmono readerwall atoms = rfcs_10_5__replay (cpmono, readerwall) atoms

--@derives [RFCS.9.4]
--@derives [LTIM.2.8.5]
||| THE MONOTONIC CLOCK ALONE IS NOT ENOUGH: the held sample is (3, 8), the
||| next sample is (3, 8) again so the step writes no `ClockAdvance`, and a
||| reader that restored the monotonic clock alone holds (3, 0) where the
||| recording held (3, 8).
export
rfcs_9_4__mono_only_checkpoint_breaks :
  Not (rfcs_9_4__seek_mono_only 3 0 (ltim_2_8_5__record rfcs_9_4__steady 1 (Just (3, 8)) [2])
         = ltim_2_8_4__samples rfcs_9_4__steady 1 [2])
rfcs_9_4__mono_only_checkpoint_breaks Refl impossible

--@derives [RFCS.9.4]
--@derives [LTIM.2.8.5]
||| A FRESH READ IS NOT THE HELD SAMPLE: a checkpoint whose clocks were read
||| when it was written, (3, 9), the wall clock having moved since the held
||| sample (3, 8). The next sample is (3, 8) again, so no `ClockAdvance` is
||| written, and the seek holds (3, 9), a value the recording never held.
export
rfcs_9_4__fresh_checkpoint_breaks :
  Not (rfcs_9_4__seek (3, 9) (ltim_2_8_5__record rfcs_9_4__steady 1 (Just (3, 8)) [2])
         = ltim_2_8_4__samples rfcs_9_4__steady 1 [2])
rfcs_9_4__fresh_checkpoint_breaks Refl impossible

-- ---------------------------------------------------------------------
-- A restored fact keeps its stamp: what re-stamping it would cost
-- ---------------------------------------------------------------------

--@derives [RFCS.9.4]
--@derives [LTIM.2.8.6]
||| A fact that entered at monotonic 3, restored at a checkpoint whose clock
||| is 7 and re-stamped with it, against the clause: at 10 its `dwell` would
||| read 3 where the recording read 7.
export
rfcs_9_4__restamped_dwell_differs : Not (lexp_9_5_1__dwell (10, 0) 3 = lexp_9_5_1__dwell (10, 0) 7)
rfcs_9_4__restamped_dwell_differs Refl impossible

--@derives [RFCS.9.4]
--@derives [LTIM.2.8.6]
||| AND A `within 5` IT HAD LEFT WOULD BE OPEN AGAIN: at 10, false from the
||| stamp of 3, true from the re-stamp of 7. "`dwell` and `within` read after
||| a seek what they read in the recording" is what the stamp from the atom
||| buys.
export
rfcs_9_4__restamped_within_reopens : (ltim_2_7_1__within (10, 0) 3 5 = False, ltim_2_7_1__within (10, 0) 7 5 = True)
rfcs_9_4__restamped_within_reopens = (Refl, Refl)

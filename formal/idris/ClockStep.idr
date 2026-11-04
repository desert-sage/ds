-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Step (2) of the consumption loop: the sample, and TTL expiry
||| (RARC.5.6.3, [RARC.5.2.4]).
|||
||| THE CLAUSES. RARC.5.6.3: the loop "samples both clocks, as the engine
||| does whenever it consumes an input ([LTIM.2.8.4]), whatever `clock_ns`
||| the event carries; then retracts expired `ttl` facts, a fact being
||| expired when its deadline is at or before the monotonic sample".
||| [RARC.5.2.4] elaborates: "`ttl` facts carry a deadline; the consumption
||| loop retracts expired `ttl` facts at each clock advance before dispatching
||| new input events." RARC.7.15 says it a third time.
|||
||| WHAT THIS FILE WAS. RARC.5.6.3 once read "Advances the clock if the event
||| carries a newer `clock_ns`": a maximum of the clock with the value the
||| event carried, which this module models and proves monotone. The clock is a
||| sample of the source, taken whenever
||| an input is consumed and whatever the input carries;
||| that the clock never goes backwards is the source's property
||| ([LTIM.2.8.2]: `MockClock.idr` proves the mock keeps it, and
||| `Rete/TtlSweep.idr` carries it on the engine). The maximum is kept below
||| as THE REFUSED READING, with the witness of where the two differ.
|||
||| TWO THINGS ARE SHOWN, AND THE THIRD IS STATED.
|||
||| Shown: the clock after the step is the sample's monotonic component,
||| whatever `clock_ns` the event carries (`rarc_5_6_3__sampled`,
||| `rarc_5_6_3__event_clock_ignored`, a transcription as its doc says); and
||| an event carrying a value above the sample moves the refused clock and
||| not the clause's (`rarc_5_6_3__event_clock_moves_the_refused_only`).
|||
||| STATED: what "expired" MEANS at the boundary. `<` and `<=` agree on EVERY
||| instant except one, so a suite that never lands exactly on a deadline cannot
||| tell them apart. RARC.5.6.3 is INCLUSIVE: a fact
||| whose deadline is "at or before the monotonic sample" is expired -- the
||| reading both runtimes implement, the differential harness validates, and
||| `lfac.k`'s sweep (`Dl <=Int C`) and `Rete/TtlSweep.idr`'s take.
|||
||| So this module has both readings: `rarc_5_2_4__expired_inclusive` is the
||| clause's, `rarc_5_2_4__expired_exclusive` is the other, and the two witnesses
||| below say where they agree and name the one instant that separates them.
module ClockStep

import Data.Nat
import TwoClocks

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The clock after the step is the sample, whatever the event carries
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.3]
--@spec [LTIM.2.8.4]
||| THE SAMPLE: the clock after step 2 is the monotonic component of the
||| sample the source gave when the input was consumed, whatever `clock_ns`
||| the event carries.
rarc_5_6_3__sampled : Ltim_2_8_1__sample -> (eventClock : Nat) -> Nat
rarc_5_6_3__sampled s eventClock = fst s

--@derives [RARC.5.6.3]
||| WHATEVER THE EVENT CARRIES: two events carrying any two `clock_ns`
||| values leave the clock at the sample. A TRANSCRIPTION: the definition
||| reads the sample and not the event, so this is `Refl`; it fails if the
||| definition is changed to read the event and refutes nothing else.
rarc_5_6_3__event_clock_ignored : (s : Ltim_2_8_1__sample) -> (c1, c2 : Nat) ->
                                  rarc_5_6_3__sampled s c1 = rarc_5_6_3__sampled s c2
rarc_5_6_3__event_clock_ignored s c1 c2 = Refl

--@spec [RARC.5.6.3]
||| THE REFUSED READING: take the event's `clock_ns` if it is newer, else
||| stay -- "advances the clock if the event carries a newer `clock_ns`",
||| which the clause no longer says. Written as an explicit recursion rather
||| than `max`, as it was while it was the clause's.
rarc_5_6_3__advance : (now : Nat) -> (eventClock : Nat) -> Nat
rarc_5_6_3__advance Z     ev      = ev
rarc_5_6_3__advance (S n) Z       = S n
rarc_5_6_3__advance (S n) (S e)   = S (rarc_5_6_3__advance n e)

--@derives [RARC.5.6.3]
||| WHERE THE TWO READINGS DIFFER: with the sample's monotonic clock at 5, an
||| event carrying 9 moves the refused clock to 9 and leaves the clause's at
||| 5; one carrying 3 leaves both at 5. Computed. The refused reading let an
||| event set the clock; the clause lets only a sample.
rarc_5_6_3__event_clock_moves_the_refused_only :
  ( rarc_5_6_3__advance 5 9 = 9, rarc_5_6_3__sampled (5, 0) 9 = 5
  , rarc_5_6_3__advance 5 3 = 5, rarc_5_6_3__sampled (5, 0) 3 = 5 )
rarc_5_6_3__event_clock_moves_the_refused_only = (Refl, Refl, Refl, Refl)

-- ---------------------------------------------------------------------
-- Expired: at or before the monotonic sample
-- ---------------------------------------------------------------------

--@spec [RARC.5.2.4]
--@spec [RARC.5.6.3]
||| "Expired", read INCLUSIVELY: a fact whose deadline is at or before the
||| current instant is expired. THE CLAUSE'S READING:
||| what both runtimes implement and the differential harness validates, and
||| what RARC.5.6.3 states, "at or before the monotonic sample".
rarc_5_2_4__expired_inclusive : (deadline : Nat) -> (now : Nat) -> Bool
rarc_5_2_4__expired_inclusive d n = d <= n

--@spec [RARC.5.2.4]
||| "Expired", read EXCLUSIVELY: the fact survives the instant it is due and
||| goes at the next one. NOT THE CLAUSE'S READING, here so the witnesses below
||| can name the instant that separates them.
rarc_5_2_4__expired_exclusive : (deadline : Nat) -> (now : Nat) -> Bool
rarc_5_2_4__expired_exclusive d n = d < n

--@derives [RARC.5.2.4]
||| The two readings agree away from the boundary -- strictly before the deadline
||| neither expires the fact, strictly after both do.
|||
||| An implementation choosing either reading behaves identically at every instant
||| except one, so a suite that never lands exactly on a deadline cannot
||| distinguish them.
rarc_5_2_4__agree_away_from_boundary :
  (rarc_5_2_4__expired_inclusive 5 3 = rarc_5_2_4__expired_exclusive 5 3,
   rarc_5_2_4__expired_inclusive 3 5 = rarc_5_2_4__expired_exclusive 3 5)
rarc_5_2_4__agree_away_from_boundary = (Refl, Refl)

--@derives [RARC.5.2.4]
||| And they disagree exactly ON the boundary -- deadline equal to now. This is
||| the one instant that separates them: under the inclusive reading the fact is
||| expired here, under the exclusive one it survives.
rarc_5_2_4__readings_differ_only_at_the_deadline :
  Not (rarc_5_2_4__expired_inclusive 5 5 = rarc_5_2_4__expired_exclusive 5 5)
rarc_5_2_4__readings_differ_only_at_the_deadline Refl impossible

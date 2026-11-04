-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| A sequence's window is event time ([LTHE.2.2.2]), and an emitted fact's
||| `ts` is the wall sample (RLOW.7.1.2).
|||
||| THE CLAUSES. [LTHE.2.2.2]: `X then Y within T` matches Y with
||| `Y.ts > X.ts` and `Y.ts - X.ts < T`, both on the facts' `ts` -- when the
||| events happened -- and not on when the engine received them, so the
||| monotonic clock takes no part ([LTIM.2.8.2]); a fact delivered late still
||| orders by its `ts`, and a wall clock step between two facts whose `ts`
||| the engine filled can invert their order. RLOW.7.1.2: an emitted fact's
||| `ts` is auto-populated from the wall clock's current sample.
|||
||| WHAT IS SHOWN. The clause's test and the refused one, on arrival, side by
||| side: a fact delivered long after its event matches by `ts` and not by
||| arrival, one delivered at once whose event was long after does the
||| reverse (`lthe_2_2_2__late_delivery_still_matches`,
||| `lthe_2_2_2__prompt_delivery_does_not`). Two facts emitted at
||| consecutive steps across a wall clock that went back: the one emitted
||| later is the earlier event, and the sequence matches them in that order
||| and not in the order of emission (`lthe_2_2_2__wall_step_inverts`). And,
||| for every source, run and starting clocks, every emitted fact has on
||| replay the `ts` and the stamp it had (`rlow_7_1_2__emitted_ts_replays`),
||| from `TwoClocks.idr`'s replay theorem.
|||
||| THE CLOCK-MEASURED WINDOW, as a witness. [IRET.19.5] says a
||| `then ... within` test compares two facts' `ts` values and is
||| not re-evaluated by the tick. Written out, a clock-measured window would be
||| time-dependent: true under one sample and false under a later one, the
||| facts unchanged (`iret_19_5__by_clock_is_time_dependent`). The clause's test
||| has no clock in it to move.
|||
||| NOT MODELLED. The sequence's join on the network, and which of a
||| sequence's facts a late delivery displaces; `TwoClocks.idr` and the
||| network modules carry those.
module EventTime

import Data.Nat
import TwoClocks

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- A fact as a sequence sees it, and the two tests
-- ---------------------------------------------------------------------

--@spec [LTHE.2.2.2]
||| A fact as a sequence sees it: its `ts`, when the event happened, and its
||| entry stamp, when the engine received it ([LTIM.2.8.6]).
public export
record Lthe_2_2_2__event where
  constructor MkEvent
  ets    : Nat
  estamp : Nat

--@spec [LTHE.2.2.2]
||| THE SEQUENCE'S TEST, on `ts` alone: Y strictly after X, and within the
||| bound.
public export
lthe_2_2_2__sequence : Lthe_2_2_2__event -> Lthe_2_2_2__event -> (bound : Nat) -> Bool
lthe_2_2_2__sequence x y bound = lt (ets x) (ets y) && lt (minus (ets y) (ets x)) bound

--@spec [LTHE.2.2.2]
||| THE REFUSED READING: the same test on the entry stamps, when the engine
||| received the facts.
public export
lthe_2_2_2__sequence_by_arrival : Lthe_2_2_2__event -> Lthe_2_2_2__event -> (bound : Nat) -> Bool
lthe_2_2_2__sequence_by_arrival x y bound = lt (estamp x) (estamp y) && lt (minus (estamp y) (estamp x)) bound

--@derives [LTHE.2.2.2]
||| A FACT DELIVERED LATE STILL MATCHES BY ITS `ts`: X happened at 1 and
||| arrived at 1; Y happened at 2 and arrived at 50. By event time Y is
||| within 10 of X; by arrival it is not.
export
lthe_2_2_2__late_delivery_still_matches :
  ( lthe_2_2_2__sequence (MkEvent 1 1) (MkEvent 2 50) 10 = True
  , lthe_2_2_2__sequence_by_arrival (MkEvent 1 1) (MkEvent 2 50) 10 = False )
lthe_2_2_2__late_delivery_still_matches = (Refl, Refl)

--@derives [LTHE.2.2.2]
||| AND ONE DELIVERED AT ONCE WHOSE EVENT WAS LONG AFTER does the reverse:
||| Y happened at 100 and arrived at 2.
export
lthe_2_2_2__prompt_delivery_does_not :
  ( lthe_2_2_2__sequence (MkEvent 1 1) (MkEvent 100 2) 10 = False
  , lthe_2_2_2__sequence_by_arrival (MkEvent 1 1) (MkEvent 100 2) 10 = True )
lthe_2_2_2__prompt_delivery_does_not = (Refl, Refl)

-- ---------------------------------------------------------------------
-- An emitted fact: ts from the wall sample, the stamp from the monotonic
-- ---------------------------------------------------------------------

--@spec [RLOW.7.1.2]
||| AN EMITTED FACT: its `ts` is the wall sample, its entry stamp the
||| monotonic one ([LTIM.2.8.6]).
public export
rlow_7_1_2__emitted : Ltim_2_8_1__sample -> Lthe_2_2_2__event
rlow_7_1_2__emitted s = MkEvent (snd s) (fst s)

--@derives [LTHE.2.2.2]
--@derives [LTIM.2.8.3]
||| A WALL CLOCK STEP INVERTS THE ORDER of two facts the engine emitted at
||| consecutive steps. With `TwoClocks.idr`'s source whose wall clock goes
||| back, (1, 9) then (2, 4), the fact emitted second is the earlier event:
||| the sequence matches the two in that order, and not in the order of
||| emission.
export
lthe_2_2_2__wall_step_inverts :
  ( lthe_2_2_2__sequence (rlow_7_1_2__emitted (ltim_2_8_3__stepped_back 1)) (rlow_7_1_2__emitted (ltim_2_8_3__stepped_back 0)) 10 = True
  , lthe_2_2_2__sequence (rlow_7_1_2__emitted (ltim_2_8_3__stepped_back 0)) (rlow_7_1_2__emitted (ltim_2_8_3__stepped_back 1)) 10 = False )
lthe_2_2_2__wall_step_inverts = (Refl, Refl)

--@derives [RLOW.7.1.2]
--@derives [LTIM.2.8.5]
||| EVERY EMITTED FACT HAS ON REPLAY THE `ts` AND THE STAMP IT HAD, for
||| every clock source, every run and every starting clocks of the replay:
||| the samples replay, and an emitted fact is a function of its sample.
export
rlow_7_1_2__emitted_ts_replays : (src : Ltim_2_8_1__source) -> (n : Nat) -> (cur : Ltim_2_8_1__sample) -> (is : List Nat) ->
                                 map rlow_7_1_2__emitted (rfcs_10_5__replay cur (ltim_2_8_5__record src n Nothing is))
                                   = map rlow_7_1_2__emitted (ltim_2_8_4__samples src n is)
rlow_7_1_2__emitted_ts_replays src n cur is =
  cong (map rlow_7_1_2__emitted) (ltim_2_8_5__replay_holds_what_was_held src n cur is)

-- ---------------------------------------------------------------------
-- The window measured on the clock, which [IRET.19.5] refuses, is
-- time-dependent
-- ---------------------------------------------------------------------

--@spec [IRET.19.5]
||| A sequence's window measured on the monotonic clock -- the reading
||| [IRET.19.5] refuses ("is not re-evaluated by the tick"): Y after X, and
||| X entered less than the bound ago at the sample.
public export
iret_19_5__sequence_window_by_clock : Ltim_2_8_1__sample -> Lthe_2_2_2__event -> Lthe_2_2_2__event -> (bound : Nat) -> Bool
iret_19_5__sequence_window_by_clock s x y bound = lt (ets x) (ets y) && lt (minus (fst s) (estamp x)) bound

--@derives [IRET.19.5]
--@derives [LTHE.2.2.2]
||| IT IS TIME-DEPENDENT: the same two facts, true under one sample and
||| false under a later one, so a tick would have to re-evaluate it. The
||| clause's test has no clock in it to move, which is why the tick leaves it.
export
iret_19_5__by_clock_is_time_dependent :
  ( iret_19_5__sequence_window_by_clock (0, 0) (MkEvent 1 1) (MkEvent 2 2) 10 = True
  , iret_19_5__sequence_window_by_clock (20, 0) (MkEvent 1 1) (MkEvent 2 2) 10 = False )
iret_19_5__by_clock_is_time_dependent = (Refl, Refl)

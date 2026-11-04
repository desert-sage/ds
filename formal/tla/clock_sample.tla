-------------------------------- MODULE clock_sample --------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS's two clocks -- ONE SAMPLE PER STEP, RECORDED, REPLAYED, as a SAFETY  *)
(* spec (TLA+ / TLC). The engine holds a monotonic clock and a wall clock   *)
(* ([LTIM.2.8.1]); it samples both together when it consumes an input and   *)
(* when a pump begins, and every read between two samples returns the held  *)
(* sample ([LTIM.2.8.4]); a sample that differs from the one before it is   *)
(* recorded, both values together ([LTIM.2.8.5], [RFCS.10.3]); and a replay *)
(* restores both from the recording ([RFCS.10.5]).                          *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the tag line above it repeats the clause so the      *)
(* checker confirms the id exists AND matches.                             *)
(*                                                                         *)
(* WHAT IS MODELLED. The PLATFORM clocks move whenever they like, a step    *)
(* in progress or not: the monotonic one forward, the wall one either way   *)
(* ([LTIM.2.8.2], [LTIM.2.8.3]). Where each starts is any value -- the      *)
(* monotonic clock's zero is unspecified. A STEP is an input consumed or a  *)
(* pump begun; the model does not tell the two apart, because the clauses   *)
(* give them one rule. Within a step the engine makes up to MAXREAD reads,  *)
(* of either clock, with the platform free to move between them. The        *)
(* RECORDER writes to the trace; the REPLAY engine is run in lockstep from  *)
(* what is written and from nothing else, its own clocks starting at any    *)
(* value, so that nothing it agrees on is agreed by accident.               *)
(*                                                                         *)
(* THE GUARANTEE, in the clause's engine:                                   *)
(*   one_value_per_step   the reads of one step return one value per clock, *)
(*                        however the platform moved between them           *)
(*   replay_holds_what_was_held                                             *)
(*                        in every step the replay engine holds the sample  *)
(*                        the live engine held, both clocks                 *)
(*   mono_never_decreases a step's monotonic sample is never below the one  *)
(*                        before it, whatever the wall clock did            *)
(*                                                                         *)
(* WHAT THE THIRD DOES NOT SAY. [LTIM.2.8.2] ends "a change to the wall     *)
(* clock therefore moves none of them", which is INDEPENDENCE: two runs     *)
(* with one monotonic history and two wall histories hold the same          *)
(* monotonic samples. That is a statement about a pair of runs, and a       *)
(* model of one run cannot state it. What is checked here is what one run   *)
(* can show, that the sample never goes down. The independence of `dwell`,  *)
(* `within`, a deadline, a cooldown and a series window from the wall clock *)
(* is the Idris lane's, where each is a function and "of the monotonic      *)
(* sample alone" is a theorem about it: formal/idris/TwoClocks.idr,         *)
(* ltim_2_8_2__dwell_ignores_wall and its four siblings, with the same five *)
(* for the monotonic clock's zero.                                          *)
(*                                                                         *)
(* NOT MODELLED HERE, and modelled in Idris: the entry                      *)
(* stamp ([LTIM.2.8.6], formal/idris/Rete/EntryStamp.idr); a checkpoint's   *)
(* clocks ([RFCS.9.4], CheckpointClocks.idr); the mock clock's own          *)
(* mutations ([NTST.3.3], MockClock.idr), which this model, following       *)
(* [LTIM.2.8.5], records when they are sampled -- MockClock shows that and  *)
(* recording them when they are made both replay exactly.                   *)
(*                                                                         *)
(* THREE THINGS THE CLAUSES LEAVE UNSAID, which the replay property needs   *)
(* and the model therefore makes explicit. Each is a constant, the main     *)
(* config sets the value the replay needs, and each has a `.teeth.` config in *)
(* which the other value breaks the replay:                                 *)
(*   FIRST   [LTIM.2.8.5] records "a sample in which either clock's value   *)
(*           differs from the previous sample". The first sample has no     *)
(*           previous. "always": it is recorded. "if_moved": it is compared *)
(*           with a starting value the engine assumes, and a replay that    *)
(*           starts anywhere else reads a different first step.             *)
(*   ORDER   [RFCS.10.5] has the replayer apply a `ClockAdvance` "before    *)
(*           processing the next atom". Nothing says the RECORDER writes    *)
(*           the step's `ClockAdvance` before the step's inject atom.       *)
(*           "before": it does. "after": the replay consumes the input      *)
(*           under the clocks of the step before.                          *)
(*   WHAT    "both": a sample is observed when either clock moved, and the  *)
(*           atom carries both. "mono": an engine the clause rules out,     *)
(*           one clock; a wall clock that moves alone is on no atom.        *)
(*                                                                         *)
(* TEETH, RUN ON EVERY LANE RUN (one config each):                          *)
(*   .teeth.per_read   the engine reads the platform at every read:         *)
(*                     two reads of one step differ.                        *)
(*   .teeth.first      FIRST = "if_moved"                                   *)
(*   .teeth.order      ORDER = "after"                                      *)
(*   .teeth.mono_only  WHAT = "mono"                                        *)
(*   .teeth.one_clock  the relative-time mechanisms are given the wall      *)
(*                     clock: an operator sets the host clock back and the  *)
(*                     "monotonic" sample goes down with it.                *)
(*                                                                         *)
(* THE CLAUSE'S BEHAVIOUR IS SEEN TO HAPPEN. The replay                     *)
(* property holds of a model in which the wall clock never goes back, and   *)
(* that is the case at issue. `.probe.wall_back` runs the clause's          *)
(* engine against a property that says the replayed wall sample never       *)
(* decreases, and TLC must return the behaviour that breaks it.             *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

\* @spec [LTIM.2.8.4]
\* The step horizon. Bounds the state graph.
CONSTANT ltim_2_8_4__MAXSTEP

\* @spec [LTIM.2.8.4]
\* How many reads a step may make.
CONSTANT ltim_2_8_4__MAXREAD

\* @spec [LTIM.2.8.2]
\* The monotonic clock's range.
CONSTANT ltim_2_8_2__MAXMONO

\* @spec [LTIM.2.8.3]
\* The wall clock's range.
CONSTANT ltim_2_8_3__MAXWALL

\* @spec [LTIM.2.8.4]
\* When the engine reads the platform: "step", once as the step begins, or
\* "read", at every read.
CONSTANT ltim_2_8_4__SAMPLING

\* @spec [LTIM.2.8.5]
\* Whether the first sample is recorded "always", or only "if_moved" from the
\* starting value the engine assumes.
CONSTANT ltim_2_8_5__FIRST

\* @spec [LTIM.2.8.5]
\* What is observed and carried: "both" clocks, or "mono" alone.
CONSTANT ltim_2_8_5__WHAT

\* @spec [RFCS.10.5]
\* Whether a step's `ClockAdvance` is written "before" or "after" the step's
\* inject atom.
CONSTANT rfcs_10_5__ORDER

\* @spec [LTIM.2.8.2]
\* Which platform clock the relative-time mechanisms are given: "mono", or
\* "wall" -- one clock doing both jobs, which is what the corpus had.
CONSTANT ltim_2_8_2__RELATIVE

\* @spec [LTIM.2.8.2]
\* The platform's monotonic clock.
VARIABLE ltim_2_8_2__platform_mono

\* @spec [LTIM.2.8.3]
\* The platform's wall clock.
VARIABLE ltim_2_8_3__platform_wall

\* @spec [LTIM.2.8.4]
\* The held sample: what the live engine's reads return, as <<mono, wall>>.
VARIABLE ltim_2_8_4__held

\* @spec [LTIM.2.8.4]
\* Steps begun so far.
VARIABLE ltim_2_8_4__step

\* @spec [LTIM.2.8.4]
\* Whether a step is in progress.
VARIABLE ltim_2_8_4__in_step

\* @spec [LTIM.2.8.4]
\* Reads made in the step in progress.
VARIABLE ltim_2_8_4__reads

\* @spec [LTIM.2.8.4]
\* The values the monotonic reads of this step returned.
VARIABLE ltim_2_8_4__mono_values

\* @spec [LTIM.2.8.4]
\* The values the wall reads of this step returned.
VARIABLE ltim_2_8_4__wall_values

\* @spec [RFCS.10.5]
\* The replay engine's clocks, as <<mono, wall>>: what the `ClockAdvance` atoms
\* written so far have set them to, and before any, where they started.
VARIABLE rfcs_10_5__restored

\* @spec [LTIM.2.8.5]
\* The replay engine's held sample, taken from its own clocks when it consumes
\* the step's inject atom.
VARIABLE ltim_2_8_5__replay_held

\* @spec [LTIM.2.8.4]
\* The state tuple.
ltim_2_8_4__vars ==
    << ltim_2_8_2__platform_mono, ltim_2_8_3__platform_wall, ltim_2_8_4__held,
       ltim_2_8_4__step, ltim_2_8_4__in_step, ltim_2_8_4__reads,
       ltim_2_8_4__mono_values, ltim_2_8_4__wall_values, rfcs_10_5__restored,
       ltim_2_8_5__replay_held >>

\* @spec [LTIM.2.8.1]
\* Every pair of clock values.
ltim_2_8_1__Samples ==
    (0..ltim_2_8_2__MAXMONO) \X (0..ltim_2_8_3__MAXWALL)

\* @spec [LTIM.2.8.4]
\* Both platform clocks start anywhere, and so do the replay engine's. The
\* live engine has sampled nothing: what it "holds" is the starting value the
\* "if_moved" recorder compares its first sample with.
ltim_2_8_4__Init ==
    /\ ltim_2_8_2__platform_mono \in 0..ltim_2_8_2__MAXMONO
    /\ ltim_2_8_3__platform_wall \in 0..ltim_2_8_3__MAXWALL
    /\ ltim_2_8_4__held = << 0, 0 >>
    /\ ltim_2_8_4__step = 0
    /\ ltim_2_8_4__in_step = FALSE
    /\ ltim_2_8_4__reads = 0
    /\ ltim_2_8_4__mono_values = {}
    /\ ltim_2_8_4__wall_values = {}
    /\ rfcs_10_5__restored \in ltim_2_8_1__Samples
    /\ ltim_2_8_5__replay_held = << 0, 0 >>

\* @spec [LTIM.2.8.3]
\* The platform moves: the monotonic clock forward or not at all, the wall
\* clock anywhere. At any time, a step in progress or not.
ltim_2_8_3__Drift ==
    /\ \E m \in ltim_2_8_2__platform_mono..ltim_2_8_2__MAXMONO :
         \E w \in 0..ltim_2_8_3__MAXWALL :
           /\ << m, w >> # << ltim_2_8_2__platform_mono, ltim_2_8_3__platform_wall >>
           /\ ltim_2_8_2__platform_mono' = m
           /\ ltim_2_8_3__platform_wall' = w
    /\ UNCHANGED << ltim_2_8_4__held, ltim_2_8_4__step, ltim_2_8_4__in_step,
                    ltim_2_8_4__reads, ltim_2_8_4__mono_values,
                    ltim_2_8_4__wall_values, rfcs_10_5__restored,
                    ltim_2_8_5__replay_held >>

\* @spec [LTIM.2.8.4]
\* One sample of both clocks, taken together, as <<mono, wall>>.
ltim_2_8_4__sample ==
    << IF ltim_2_8_2__RELATIVE = "mono"
       THEN ltim_2_8_2__platform_mono
       ELSE ltim_2_8_3__platform_wall,
       ltim_2_8_3__platform_wall >>

\* @spec [LTIM.2.8.5]
\* Whether the sample now being taken is an observed clock value: it differs
\* from the one before it. The first sample is the case the clause does not
\* decide, and FIRST does.
ltim_2_8_5__observed ==
    LET moved == IF ltim_2_8_5__WHAT = "both"
                 THEN ltim_2_8_4__sample # ltim_2_8_4__held
                 ELSE ltim_2_8_4__sample[1] # ltim_2_8_4__held[1]
    IN  IF ltim_2_8_4__step = 0 /\ ltim_2_8_5__FIRST = "always"
        THEN TRUE
        ELSE moved

\* @spec [RFCS.10.5]
\* The replay engine's clocks once the `ClockAdvance` of this sample, if there
\* is one, has been applied. A "mono" atom carries no wall value to restore.
rfcs_10_5__applied ==
    IF ~ltim_2_8_5__observed THEN rfcs_10_5__restored
    ELSE IF ltim_2_8_5__WHAT = "both"
         THEN ltim_2_8_4__sample
         ELSE << ltim_2_8_4__sample[1], rfcs_10_5__restored[2] >>

\* @spec [LTIM.2.8.4]
\* A STEP BEGINS: an input is consumed, or a pump begins. The live engine
\* samples both platform clocks together. The recorder writes the
\* `ClockAdvance`, if the sample is an observed value, and the step's inject
\* atom; the replay engine applies the one and consumes the other in the order
\* they were written, sampling its own clocks as it consumes.
ltim_2_8_4__Begin ==
    /\ ~ltim_2_8_4__in_step
    /\ ltim_2_8_4__step < ltim_2_8_4__MAXSTEP
    /\ ltim_2_8_4__step' = ltim_2_8_4__step + 1
    /\ ltim_2_8_4__in_step' = TRUE
    /\ ltim_2_8_4__reads' = 0
    /\ ltim_2_8_4__mono_values' = {}
    /\ ltim_2_8_4__wall_values' = {}
    /\ ltim_2_8_4__held' = ltim_2_8_4__sample
    /\ rfcs_10_5__restored' = rfcs_10_5__applied
    /\ ltim_2_8_5__replay_held' =
         IF rfcs_10_5__ORDER = "before"
         THEN rfcs_10_5__applied
         ELSE rfcs_10_5__restored
    /\ UNCHANGED << ltim_2_8_2__platform_mono, ltim_2_8_3__platform_wall >>

\* @spec [LTIM.2.8.4]
\* What a read of the live engine returns, as <<mono, wall>>: the held sample,
\* or, in the engine that samples at every read, the platform as it stands.
ltim_2_8_4__read_from ==
    IF ltim_2_8_4__SAMPLING = "step"
    THEN ltim_2_8_4__held
    ELSE ltim_2_8_4__sample

\* @spec [LTIM.2.2.1]
\* A read of the monotonic clock: `monotonic_ns()`, `dwell`, a TTL deadline, a
\* window, a timer.
ltim_2_2_1__ReadMono ==
    /\ ltim_2_8_4__in_step
    /\ ltim_2_8_4__reads < ltim_2_8_4__MAXREAD
    /\ ltim_2_8_4__reads' = ltim_2_8_4__reads + 1
    /\ ltim_2_8_4__mono_values' =
         ltim_2_8_4__mono_values \cup { ltim_2_8_4__read_from[1] }
    /\ UNCHANGED << ltim_2_8_2__platform_mono, ltim_2_8_3__platform_wall,
                    ltim_2_8_4__held, ltim_2_8_4__step, ltim_2_8_4__in_step,
                    ltim_2_8_4__wall_values, rfcs_10_5__restored,
                    ltim_2_8_5__replay_held >>

\* @spec [LTIM.2.1.1]
\* A read of the wall clock: `now()`.
ltim_2_1_1__ReadWall ==
    /\ ltim_2_8_4__in_step
    /\ ltim_2_8_4__reads < ltim_2_8_4__MAXREAD
    /\ ltim_2_8_4__reads' = ltim_2_8_4__reads + 1
    /\ ltim_2_8_4__wall_values' =
         ltim_2_8_4__wall_values \cup { ltim_2_8_4__read_from[2] }
    /\ UNCHANGED << ltim_2_8_2__platform_mono, ltim_2_8_3__platform_wall,
                    ltim_2_8_4__held, ltim_2_8_4__step, ltim_2_8_4__in_step,
                    ltim_2_8_4__mono_values, rfcs_10_5__restored,
                    ltim_2_8_5__replay_held >>

\* @spec [LTIM.2.8.4]
\* The step ends.
ltim_2_8_4__End ==
    /\ ltim_2_8_4__in_step
    /\ ltim_2_8_4__in_step' = FALSE
    /\ UNCHANGED << ltim_2_8_2__platform_mono, ltim_2_8_3__platform_wall,
                    ltim_2_8_4__held, ltim_2_8_4__step, ltim_2_8_4__reads,
                    ltim_2_8_4__mono_values, ltim_2_8_4__wall_values,
                    rfcs_10_5__restored, ltim_2_8_5__replay_held >>

\* @spec [LTIM.2.8.4]
\* The horizon is reached -- an explicit terminal stutter, not a TLC deadlock.
ltim_2_8_4__Idle ==
    /\ ~ltim_2_8_4__in_step
    /\ ltim_2_8_4__step = ltim_2_8_4__MAXSTEP
    /\ UNCHANGED ltim_2_8_4__vars

\* @spec [LTIM.2.8.4]
\* Next: the platform moves, a step begins, reads, ends.
ltim_2_8_4__Next ==
    \/ ltim_2_8_3__Drift
    \/ ltim_2_8_4__Begin
    \/ ltim_2_2_1__ReadMono
    \/ ltim_2_1_1__ReadWall
    \/ ltim_2_8_4__End
    \/ ltim_2_8_4__Idle

\* @spec [LTIM.2.8.4]
\* The behavior spec. A SAFETY model: no fairness is needed.
ltim_2_8_4__Spec ==
    ltim_2_8_4__Init /\ [][ltim_2_8_4__Next]_ltim_2_8_4__vars

\* @spec [LTIM.2.8.4]
\* Type-correctness -- a state invariant true at every reachable state.
ltim_2_8_4__TypeOK ==
    /\ ltim_2_8_2__platform_mono \in 0..ltim_2_8_2__MAXMONO
    /\ ltim_2_8_3__platform_wall \in 0..ltim_2_8_3__MAXWALL
    /\ ltim_2_8_4__held \in ltim_2_8_1__Samples
    /\ ltim_2_8_4__step \in 0..ltim_2_8_4__MAXSTEP
    /\ ltim_2_8_4__in_step \in BOOLEAN
    /\ ltim_2_8_4__reads \in 0..ltim_2_8_4__MAXREAD
    /\ ltim_2_8_4__mono_values \subseteq 0..ltim_2_8_2__MAXMONO
    /\ ltim_2_8_4__wall_values \subseteq 0..ltim_2_8_3__MAXWALL
    /\ rfcs_10_5__restored \in ltim_2_8_1__Samples
    /\ ltim_2_8_5__replay_held \in ltim_2_8_1__Samples
    /\ ltim_2_8_4__SAMPLING \in { "step", "read" }
    /\ ltim_2_8_5__FIRST \in { "always", "if_moved" }
    /\ ltim_2_8_5__WHAT \in { "both", "mono" }
    /\ rfcs_10_5__ORDER \in { "before", "after" }
    /\ ltim_2_8_2__RELATIVE \in { "mono", "wall" }

\* @derives [LTIM.2.8.4]
\* ONE VALUE PER STEP (safety): the reads of one step return one value of each
\* clock -- "two reads of `now()`, or of `monotonic_ns()`, between the same two
\* samples therefore return the same value" -- whatever the platform did
\* between them and in whatever order they were made. NO counterexample.
ltim_2_8_4__one_value_per_step ==
    /\ Cardinality(ltim_2_8_4__mono_values) <= 1
    /\ Cardinality(ltim_2_8_4__wall_values) <= 1

\* @derives [LTIM.2.8.5]
\* REPLAY HOLDS WHAT WAS HELD (safety): in every step the replay engine holds
\* the sample the live engine held -- so `now()`, `monotonic_ns()` and every
\* relative-time mechanism "read on replay exactly what they read when the
\* trace was recorded". The replay engine is driven by the atoms alone and
\* starts from any clocks. NO counterexample.
ltim_2_8_5__replay_holds_what_was_held ==
    ltim_2_8_4__in_step => ltim_2_8_5__replay_held = ltim_2_8_4__held

\* @derives [LTIM.2.8.2]
\* THE MONOTONIC SAMPLE NEVER DECREASES (safety): the held monotonic value is
\* never below the one held in the step before, however the wall clock moved
\* between them. NO counterexample. It is not the independence the clause
\* ends on; the header says where that is.
ltim_2_8_2__mono_never_decreases ==
    [][ ltim_2_8_4__step > 0
          => ltim_2_8_4__held'[1] >= ltim_2_8_4__held[1] ]_ltim_2_8_4__vars

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: it says the wall sample a replay holds never
\* goes down from one step to the next. FALSE of the clause's engine, and
\* clock_sample.probe.wall_back.cfg requires TLC to say so: the host clock is
\* set back between two steps, the sample is recorded, and the replay engine
\* holds the earlier instant after the later one ([LTIM.2.8.3]).
probe__wall_never_goes_back ==
    [][ ltim_2_8_4__step > 0
          => ltim_2_8_5__replay_held'[2] >= ltim_2_8_5__replay_held[2]
      ]_ltim_2_8_4__vars

=============================================================================

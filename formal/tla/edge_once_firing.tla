------------------------------ MODULE edge_once_firing ------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS time-dependent rules -- ONCE PER MATCH, as a SAFETY+LIVENESS spec     *)
(* (TLA+ / TLC). A rule gated on a time-dependent `where` ([LTIM.2.4.1]) is *)
(* re-evaluated at every pump ([LTIM.2.4.2]) and fires once per false ->    *)
(* true edge of the condition for a matched fact wrapper; a condition that  *)
(* closes ends the match, and a reopening is a new edge ([LTIM.2.5.1]).     *)
(*                                                                         *)
(* WHAT THIS MODEL COULD NOT SEE BEFORE. Its condition was                  *)
(* `clock >= threshold` over a clock that only rose, so a gate once open    *)
(* stayed open, and "once per wrapper" and "once per edge" were the same    *)
(* count on every behaviour TLC could reach. The condition is now ANY       *)
(* truth value at each pump: a window that shuts, a `now()` gate the wall   *)
(* clock crosses back over ([LTIM.2.8.3]), a gate that never opens.         *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the tag line above it repeats the clause so the      *)
(* checker confirms the id exists AND matches.                             *)
(*                                                                         *)
(* THE STEP. Both clocks are sampled when an input is consumed and when a   *)
(* pump begins ([LTIM.2.8.4]). An assert is an input: the condition is      *)
(* evaluated under its sample, and a match true then is an activation       *)
(* waiting for the pump. A pump begins with a new sample and re-evaluates   *)
(* BEFORE it fires anything ([IRET.19.5], steps 3 and 4), so what a pump    *)
(* fires is what is true under the pump's own sample.                      *)
(*                                                                         *)
(* AN EDGE IS BETWEEN TWO PUMPS. `seen` is what the last pump saw of the    *)
(* condition for the current wrapper, FALSE before its first. An edge is a  *)
(* pump that sees TRUE after one that saw FALSE. The value at assert is     *)
(* not an observation: nothing fires between an assert and the pump after   *)
(* it, so a condition true at the assert and false at the pump was never    *)
(* true at a moment the engine could act on. [LTIM.2.5.3] says such a fact  *)
(* fires on the next pump "if it still holds under that pump's sample",     *)
(* and the model shows the other case (mint with TRUE, begin with FALSE: no *)
(* firing, no edge).                                                        *)
(*                                                                         *)
(* THE GUARANTEE, in the clause's engine with the pump run to quiescence:   *)
(*   once_per_edge       firings and edges are the same count, at every     *)
(*                       state, for every truth history                     *)
(*   fired_where_it_rose no pump ends with its edge unfired                 *)
(*   shut_means_silent   nothing fires while the condition is false         *)
(*   edge_fires          an activation a pump holds unfired does fire       *)
(*                                                                         *)
(* TEETH, RUN ON EVERY LANE RUN. Five configs select an                     *)
(* engine the clauses rule out, one or more for every property, and each    *)
(* must end in a violation:                                                 *)
(*   .teeth.wrapper  the firing is remembered per wrapper and outlives the  *)
(*                   activation. A gate that shuts and reopens does not     *)
(*                   fire again: open, shut, open is two edges and one      *)
(*                   firing. This is [IRET.11.3.2] as it reads -- "nothing  *)
(*                   else clears it" -- and it is what [LTIM.2.5.1] now     *)
(*                   forbids. Breaks once_per_edge.                         *)
(*   .teeth.level    every pump re-arms while the condition holds: the      *)
(*                   per-pump reading of refraction [IRET.11.3.2] refuses.  *)
(*                   One edge, a firing per pump. Breaks           *)
(*                   once_per_edge.                                         *)
(*   .teeth.limited  the pump may end before quiescence, a firing limit     *)
(*                   reached ([IRET.11.5]). The edge's activation is left   *)
(*                   unfired when the pump ends. Breaks                     *)
(*                   fired_where_it_rose.                                   *)
(*   .teeth.starved  the same engine, seen over time: the pump ends with    *)
(*                   the activation unfired and the match is gone before    *)
(*                   any pump fires it -- the gate shut, or the fact        *)
(*                   replaced or retracted. The edge never fires. Breaks    *)
(*                   edge_fires. "On the tick at which the edge occurs"     *)
(*                   is a property of a pump that drains.                   *)
(*   .teeth.stale    a match made at the assert is fired by the pump        *)
(*                   without being re-evaluated under the pump's own        *)
(*                   sample: true at the assert, false when the pump        *)
(*                   begins, fired all the same. This is the reading        *)
(*                   [LTIM.2.5.3] refuses: a condition the pump's sample    *)
(*                   finds false has ended its match, and nothing fires.    *)
(*                   Breaks shut_means_silent.                              *)
(*                                                                         *)
(* THE CLAUSE'S BEHAVIOUR IS SEEN TO HAPPEN. once_per_edge                  *)
(* is an equality of two counters, and it holds of a model in which         *)
(* neither ever reaches two. `.probe.refires` runs the CLAUSE'S engine      *)
(* against a property that says no wrapper fires twice, and TLC must        *)
(* return the behaviour that breaks it: the gate opens and the rule fires,  *)
(* the gate shuts, it opens again and the rule fires again.                 *)
(*                                                                         *)
(* ONE WINDOW, THREE MODELS. Three models of                               *)
(* [LTIM.2.5.1] pin the window {2, 3, 6, 7} -- open at 2 and 3, shut at 4  *)
(* and 5, open again at 6 and 7 -- to two firings, one per opening.         *)
(* refraction_readings.tla's stream `tick_edge_twice` fires 1@2 1@6 under  *)
(* the clause's reading; formal/idris/Rete/NetworkClocked.idr's            *)
(* `ltim_2_5_1__window_2367_clocked` computes [0, 1, 0, 0, 0, 1, 0] over    *)
(* ticks 1 to 7 on the clocked network; this model abstracts the clock, so *)
(* its pin is `.probe.refires`: open, shut, open, two firings, which TLC    *)
(* returns. The conformance fixture LTIM.2.5.1_window_reopens.json runs    *)
(* the window on the runtimes (`dwell` in [2 s, 4 s) or at least 6 s,       *)
(* pumped at 0, 2, 4, 6 s: two firings). One disagreement among the three  *)
(* was found by reading; the pin is what a reader                           *)
(* compares.                                                               *)
(***************************************************************************)
EXTENDS Naturals

\* @spec [LTIM.2.4.2]
\* The pump horizon -- how many pumps a behaviour takes. Bounds the state graph.
CONSTANT ltim_2_4_2__MAXPUMP

\* @spec [LTIM.2.5.2]
\* The re-mint horizon -- how many fresh fact wrappers may be minted.
CONSTANT ltim_2_5_2__MAXWRAPPER

\* @spec [LTIM.2.5.1]
\* Which engine this run is of. "match" is the clause's: the firing is a flag
\* on the activation and goes when the match ends. "wrapper" remembers the
\* firing for as long as the wrapper lives. "level" forgets it at every pump.
\* "stale" is "match" but for one thing: an activation made at the assert and
\* not yet fired is kept by the pump whatever its condition has become.
CONSTANT ltim_2_5_1__READING

\* @spec [IRET.11.5]
\* Whether a pump may end with an activation unfired -- a firing limit below
\* what the pump had to fire. FALSE is `max_fires = 0`, run until empty.
CONSTANT iret_11_5__LIMITED

\* @spec [LTIM.2.4.2]
\* Pumps begun so far.
VARIABLE ltim_2_4_2__pump

\* @spec [LTIM.2.4.2]
\* Whether a pump is running: between its sample and its quiescence.
VARIABLE ltim_2_4_2__pumping

\* @spec [LTIM.2.5.2]
\* The current fact wrapper id (fact_id, [LFAC.1.7]) -- a fresh id per mint.
VARIABLE ltim_2_5_2__wrapper

\* @spec [LTIM.2.5.2]
\* Whether a matched fact wrapper is present (asserted, not retracted).
VARIABLE ltim_2_5_2__present

\* @spec [LTIM.2.4.1]
\* The condition's truth under the held sample, for the present wrapper.
VARIABLE ltim_2_4_1__holds

\* @spec [LTIM.2.4.1]
\* What the last pump saw of the condition for this wrapper; FALSE before its
\* first pump. An edge is a pump that sees TRUE where this is FALSE.
VARIABLE ltim_2_4_1__seen

\* @spec [LTIM.2.5.1]
\* The activation of the match: none, or one that has or has not fired.
VARIABLE ltim_2_5_1__act

\* @spec [LTIM.2.5.1]
\* Whether this wrapper has ever fired. Only the "wrapper" engine reads it.
VARIABLE ltim_2_5_1__latched

\* @spec [LTIM.2.5.1]
\* Firings for the current wrapper.
VARIABLE ltim_2_5_1__fires

\* @spec [LTIM.2.5.1]
\* False -> true edges the pumps have seen for the current wrapper.
VARIABLE ltim_2_5_1__edges

\* @spec [LTIM.2.5]
\* The state tuple -- the variables a step may change.
ltim_2_5__vars ==
    << ltim_2_4_2__pump, ltim_2_4_2__pumping, ltim_2_5_2__wrapper,
       ltim_2_5_2__present, ltim_2_4_1__holds, ltim_2_4_1__seen,
       ltim_2_5_1__act, ltim_2_5_1__latched, ltim_2_5_1__fires,
       ltim_2_5_1__edges >>

\* @spec [LTIM.2.5]
\* Initially no pump has run and no fact is present.
ltim_2_5__Init ==
    /\ ltim_2_4_2__pump = 0
    /\ ltim_2_4_2__pumping = FALSE
    /\ ltim_2_5_2__wrapper = 0
    /\ ltim_2_5_2__present = FALSE
    /\ ltim_2_4_1__holds = FALSE
    /\ ltim_2_4_1__seen = FALSE
    /\ ltim_2_5_1__act = "none"
    /\ ltim_2_5_1__latched = FALSE
    /\ ltim_2_5_1__fires = 0
    /\ ltim_2_5_1__edges = 0

\* @spec [LTIM.2.5.2]
\* A new fact wrapper is minted between pumps -- a first assert, a re-match
\* after a retract, or a meaningful change (a retract and an assert under the
\* hood). It is an input, so the condition is evaluated under its sample: `b`
\* is that value, and a match true then is an unfired activation. No pump has
\* seen this wrapper, and nothing is remembered of the last one. (A no-op
\* reassert preserves the wrapper -- a stutter here.)
ltim_2_5_2__Mint ==
    /\ ~ltim_2_4_2__pumping
    /\ ltim_2_5_2__wrapper < ltim_2_5_2__MAXWRAPPER
    /\ ltim_2_5_2__wrapper' = ltim_2_5_2__wrapper + 1
    /\ ltim_2_5_2__present' = TRUE
    /\ \E b \in BOOLEAN :
         /\ ltim_2_4_1__holds' = b
         /\ ltim_2_5_1__act' = IF b THEN "unfired" ELSE "none"
    /\ ltim_2_4_1__seen' = FALSE
    /\ ltim_2_5_1__latched' = FALSE
    /\ ltim_2_5_1__fires' = 0
    /\ ltim_2_5_1__edges' = 0
    /\ UNCHANGED << ltim_2_4_2__pump, ltim_2_4_2__pumping >>

\* @spec [LTIM.2.5.2]
\* The matched fact is retracted between pumps: no match, no activation.
ltim_2_5_2__Retract ==
    /\ ~ltim_2_4_2__pumping
    /\ ltim_2_5_2__present
    /\ ltim_2_5_2__present' = FALSE
    /\ ltim_2_4_1__holds' = FALSE
    /\ ltim_2_4_1__seen' = FALSE
    /\ ltim_2_5_1__act' = "none"
    /\ UNCHANGED << ltim_2_4_2__pump, ltim_2_4_2__pumping, ltim_2_5_2__wrapper,
                    ltim_2_5_1__latched, ltim_2_5_1__fires, ltim_2_5_1__edges >>

\* @spec [LTIM.2.5.1]
\* What re-evaluation makes of the activation when the condition is `o`, by
\* engine. In the clause's, a false condition ends the match and its
\* activation, a true one keeps the activation it has and makes an unfired one
\* where there is none. The "stale" engine does not look at `o` while it holds
\* an activation it has not fired.
ltim_2_5_1__reevaluated(o) ==
    IF ltim_2_5_1__READING = "stale" /\ ltim_2_5_1__act = "unfired" THEN "unfired"
    ELSE IF ~o THEN "none"
    ELSE IF ltim_2_5_1__READING = "level" THEN "unfired"
    ELSE IF ltim_2_5_1__act # "none" THEN ltim_2_5_1__act
    ELSE IF ltim_2_5_1__READING = "wrapper" /\ ltim_2_5_1__latched THEN "fired"
    ELSE "unfired"

\* @spec [LTIM.2.4.2]
\* A pump begins: the clocks are sampled ([LTIM.2.8.4]) and every
\* time-dependent condition is re-evaluated under the sample, before anything
\* fires. `o` is the condition's value now -- any value, whatever it was.
ltim_2_4_2__Begin ==
    /\ ~ltim_2_4_2__pumping
    /\ ltim_2_4_2__pump < ltim_2_4_2__MAXPUMP
    /\ ltim_2_4_2__pump' = ltim_2_4_2__pump + 1
    /\ ltim_2_4_2__pumping' = TRUE
    /\ IF ltim_2_5_2__present
       THEN \E o \in BOOLEAN :
              /\ ltim_2_4_1__holds' = o
              /\ ltim_2_4_1__seen' = o
              /\ ltim_2_5_1__act' = ltim_2_5_1__reevaluated(o)
              /\ ltim_2_5_1__edges' =
                   IF o /\ ~ltim_2_4_1__seen
                   THEN ltim_2_5_1__edges + 1 ELSE ltim_2_5_1__edges
       ELSE UNCHANGED << ltim_2_4_1__holds, ltim_2_4_1__seen, ltim_2_5_1__act,
                         ltim_2_5_1__edges >>
    /\ UNCHANGED << ltim_2_5_2__wrapper, ltim_2_5_2__present,
                    ltim_2_5_1__latched, ltim_2_5_1__fires >>

\* @spec [LTIM.2.5.1]
\* The firing: an unfired activation fires and is marked. The mark is the
\* refraction [LDET.5.3] describes; a tick does not clear it ([LDET.5.8]).
ltim_2_5_1__Fire ==
    /\ ltim_2_4_2__pumping
    /\ ltim_2_5_1__act = "unfired"
    /\ ltim_2_5_1__act' = "fired"
    /\ ltim_2_5_1__latched' = TRUE
    /\ ltim_2_5_1__fires' = ltim_2_5_1__fires + 1
    /\ UNCHANGED << ltim_2_4_2__pump, ltim_2_4_2__pumping, ltim_2_5_2__wrapper,
                    ltim_2_5_2__present, ltim_2_4_1__holds, ltim_2_4_1__seen,
                    ltim_2_5_1__edges >>

\* @spec [IRET.11.5]
\* The pump ends: at quiescence, or, in the limited engine, wherever it stops.
iret_11_5__End ==
    /\ ltim_2_4_2__pumping
    /\ iret_11_5__LIMITED \/ ltim_2_5_1__act # "unfired"
    /\ ltim_2_4_2__pumping' = FALSE
    /\ UNCHANGED << ltim_2_4_2__pump, ltim_2_5_2__wrapper, ltim_2_5_2__present,
                    ltim_2_4_1__holds, ltim_2_4_1__seen, ltim_2_5_1__act,
                    ltim_2_5_1__latched, ltim_2_5_1__fires, ltim_2_5_1__edges >>

\* @spec [LTIM.2.5]
\* The pump horizon is reached -- an explicit terminal stutter so the end state
\* is legitimate, not a TLC deadlock.
ltim_2_5__Idle ==
    /\ ~ltim_2_4_2__pumping
    /\ ltim_2_4_2__pump = ltim_2_4_2__MAXPUMP
    /\ UNCHANGED ltim_2_5__vars

\* @spec [LTIM.2.5]
\* Next: an input between pumps, a pump beginning, a firing, a pump ending.
ltim_2_5__Next ==
    \/ ltim_2_5_2__Mint
    \/ ltim_2_5_2__Retract
    \/ ltim_2_4_2__Begin
    \/ ltim_2_5_1__Fire
    \/ iret_11_5__End
    \/ ltim_2_5__Idle

\* @spec [LTIM.2.5]
\* The behavior spec. WEAK FAIRNESS on the firing and on the pump's end: a pump
\* that has begun runs. Inputs and the next pump are the integrator's choice
\* and carry NO fairness.
ltim_2_5__Spec ==
    /\ ltim_2_5__Init
    /\ [][ltim_2_5__Next]_ltim_2_5__vars
    /\ WF_ltim_2_5__vars(ltim_2_5_1__Fire)
    /\ WF_ltim_2_5__vars(iret_11_5__End)

\* @spec [LTIM.2.5]
\* Type-correctness -- a state invariant true at every reachable state.
ltim_2_5__TypeOK ==
    /\ ltim_2_4_2__pump \in 0..ltim_2_4_2__MAXPUMP
    /\ ltim_2_4_2__pumping \in BOOLEAN
    /\ ltim_2_5_2__wrapper \in 0..ltim_2_5_2__MAXWRAPPER
    /\ ltim_2_5_2__present \in BOOLEAN
    /\ ltim_2_4_1__holds \in BOOLEAN
    /\ ltim_2_4_1__seen \in BOOLEAN
    /\ ltim_2_5_1__act \in { "none", "unfired", "fired" }
    /\ ltim_2_5_1__latched \in BOOLEAN
    /\ ltim_2_5_1__fires \in 0..ltim_2_4_2__MAXPUMP
    /\ ltim_2_5_1__edges \in 0..ltim_2_4_2__MAXPUMP
    /\ ltim_2_5_1__READING \in { "match", "wrapper", "level", "stale" }
    /\ iret_11_5__LIMITED \in BOOLEAN

\* @derives [LTIM.2.5.1]
\* ONCE PER EDGE (safety): for every truth history, the firings of a wrapper
\* are its edges. Between pumps the two counts are equal; inside a pump they
\* differ by the one activation still to fire. Two counters kept by different
\* actions -- `edges` by what the pump SEES, `fires` by what the engine DOES --
\* so this is not either action restated. NO counterexample.
ltim_2_5_1__once_per_edge ==
    ltim_2_5_1__edges =
        ltim_2_5_1__fires
          + (IF ltim_2_4_2__pumping /\ ltim_2_5_1__act = "unfired" THEN 1 ELSE 0)

\* @spec [LTIM.2.5.1]
\* FIRED WHERE IT ROSE (safety): "on the tick at which the edge occurs" -- no
\* pump ends holding an activation it has not fired. NO counterexample.
\*
\* TAGGED `spec`: in the unlimited engine this restates `End`'s guard in a
\* second spelling, a check on the transcription. The limited engine is the
\* one it disagrees with.
ltim_2_5_1__fired_where_it_rose ==
    [][ (ltim_2_4_2__pumping /\ ~ltim_2_4_2__pumping')
          => ltim_2_5_1__act # "unfired" ]_ltim_2_5__vars

\* @derives [LTIM.2.4.1]
\* SHUT MEANS SILENT (safety): nothing fires while the condition is false
\* under the held sample. `Fire` is guarded by the activation, not by the
\* condition, so this rests on an activation existing only where the
\* condition holds -- which re-evaluation before firing is what gives. NO
\* counterexample.
ltim_2_4_1__shut_means_silent ==
    [][ (ltim_2_5_1__fires' > ltim_2_5_1__fires)
          => (ltim_2_5_2__present /\ ltim_2_4_1__holds) ]_ltim_2_5__vars

\* @derives [LTIM.2.4.2]
\* AN EDGE FIRES (liveness): an activation a pump holds unfired does fire --
\* "must therefore fire once the clock advances to satisfy it". Under weak
\* fairness on the firing. NO counterexample.
ltim_2_4_2__edge_fires ==
    []( (ltim_2_4_2__pumping /\ ltim_2_5_1__act = "unfired")
          => <>(ltim_2_5_1__act = "fired") )

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: it says a wrapper fires once at most, which is
\* what the clause stopped saying. FALSE of the clause's engine, and
\* edge_once_firing.probe.refires.cfg requires TLC to say so. A wrapper's
\* second firing can be reached one way only, through a pump that saw the
\* condition false, so the behaviour TLC returns is open, shut, open.
probe__one_firing_a_wrapper ==
    ltim_2_5_1__fires < 2

=============================================================================

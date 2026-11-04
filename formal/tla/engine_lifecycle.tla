------------------------------- MODULE engine_lifecycle -------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS engine lifecycle -- the one-way phase FSM + substituted clock, as a  *)
(* TEMPORAL spec (TLA+ / TLC). The behavioral sibling of                   *)
(* formal/alloy/engine_lifecycle.als: where the Alloy model fakes a trace  *)
(* with util/ordering over a static set of steps and checks the property   *)
(* AT REST, this models the lifecycle as an actual state machine (Init +   *)
(* Next) and checks the property across every reachable state of every     *)
(* behavior -- the movie, not the photograph.                              *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* to be machine-checked by the spec gate's crossref: every operator is    *)
(* named <lowercased-clause-id>__<Tag> after the paragraph it formalizes,  *)
(* and the `\* @spec [ID]` / `\* @derives [ID]` line above it repeats the   *)
(* clause so the checker confirms the id exists AND matches the name.      *)
(*                                                                         *)
(* THE INVARIANT. An engine's lifecycle phase advances one way --          *)
(* fresh -> running (first pump) -> freed -- and `freed` is TERMINAL: after *)
(* ds_engine_free the handle is invalid, so no operation runs on it        *)
(* ([NLFC.6.2], its first bullet). The clock SOURCE may be substituted     *)
(* (live <-> mock, [NLFC.5.4]) but only while the handle is live. TLC      *)
(* proves that over ALL behaviors freed is stable and no clock             *)
(* substitution -- the one use of the handle this model has -- ever occurs *)
(* after free. The clause's other two bullets, the fact and schema         *)
(* pointers and the callbacks, are outside this model (see                 *)
(* nlfc_6_2__NoUseAfterFree).                                              *)
(*                                                                         *)
(* TEETH: drop the `\in {"fresh","running"}` guard on ToggleClock and      *)
(* NoUseAfterFree fails -- TLC returns a trace toggling the clock on a      *)
(* freed engine.                                                           *)
(*                                                                         *)
(* THAT SENTENCE WAS RUN ONCE AND IS NOT A CONFIG.                         *)
(* NoUseAfterFree restates the guard, so an engine without the guard ran   *)
(* once, and the property failed of it as the sentence                     *)
(* says. The `.teeth.` config beside this module is for FreedIsTerminal.   *)
(***************************************************************************)

\* @spec [NLFC.6]
\* The engine lifecycle phases: fresh (after ds_engine_new), running (after the
\* first pump), freed (after ds_engine_free).
nlfc_6__Phase == { "fresh", "running", "freed" }

\* @spec [NLFC.5.4]
\* The clock mode -- which source is in force, live or mock.
nlfc_5_4__ClockMode == { "live", "mock" }

\* @spec [NLFC.6]
\* Which engine this run is of. "clause" is the clause's, and
\* engine_lifecycle.cfg runs it. The other is an engine the clause rules out,
\* modelled so that a property can be SEEN to fail: the
\* `.teeth.` config beside this module is a run scripts/formal/check_tla.py
\* requires to end in a violation, on every run of the lane.
\*   "revives"  a freed engine comes back as a fresh one
CONSTANT nlfc_6__ENGINE

\* @spec [NLFC.6]
\* The current lifecycle phase.
VARIABLE nlfc_6__phase

\* @spec [NLFC.5.4]
\* The current clock mode.
VARIABLE nlfc_5_4__clock

\* @spec [NLFC.6]
\* The state tuple -- the variables a lifecycle step may change.
nlfc_6__vars == << nlfc_6__phase, nlfc_5_4__clock >>

\* @spec [NLFC.6]
\* Initial state: a freshly created engine on the live clock, nothing loaded.
nlfc_6__Init ==
    /\ nlfc_6__phase = "fresh"
    /\ nlfc_5_4__clock = "live"

\* @spec [NLFC.6]
\* First pump: fresh -> running. Only a fresh engine advances into running.
nlfc_6__Pump ==
    /\ nlfc_6__phase = "fresh"
    /\ nlfc_6__phase' = "running"
    /\ UNCHANGED nlfc_5_4__clock

\* @spec [NLFC.6.1]
\* ds_engine_free: (fresh | running) -> freed. Teardown from any live phase.
nlfc_6_1__Free ==
    /\ nlfc_6__phase \in { "fresh", "running" }
    /\ nlfc_6__phase' = "freed"
    /\ UNCHANGED nlfc_5_4__clock

\* @spec [NLFC.5.4]
\* Clock source substitution -- a legal call in either direction, but only on a
\* live handle (guarded off `freed`, so it can never operate on a torn-down
\* engine). The clause contracts nothing about the timeline on the way back;
\* this model carries no clock values and does not pretend to.
nlfc_5_4__ToggleClock ==
    /\ nlfc_6__phase \in { "fresh", "running" }
    /\ nlfc_5_4__clock' = (IF nlfc_5_4__clock = "live" THEN "mock" ELSE "live")
    /\ UNCHANGED nlfc_6__phase

\* @spec [NLFC.6.2]
\* A freed engine takes no further action -- modelled as an explicit terminal
\* stutter so `freed` is a legitimate end state (the handle is inert after free),
\* not a TLC deadlock. This is the one disjunct enabled at `freed`.
nlfc_6_2__Terminated ==
    /\ nlfc_6__phase = "freed"
    /\ IF nlfc_6__ENGINE = "revives"
         THEN /\ nlfc_6__phase' = "fresh"
              /\ UNCHANGED nlfc_5_4__clock
         ELSE UNCHANGED nlfc_6__vars

\* @spec [NLFC.6]
\* The next-state relation. Only `nlfc_6_2__Terminated` is enabled at `freed`, so
\* the engine loops there forever -- terminal, but not a deadlock.
nlfc_6__Next ==
    \/ nlfc_6__Pump
    \/ nlfc_6_1__Free
    \/ nlfc_5_4__ToggleClock
    \/ nlfc_6_2__Terminated

\* @spec [NLFC.6]
\* The behavior spec: Init, then stutter-closed steps of Next.
nlfc_6__Spec == nlfc_6__Init /\ [][nlfc_6__Next]_nlfc_6__vars

\* @spec [NLFC.6]
\* Type-correctness -- a state invariant true at every reachable state.
nlfc_6__TypeOK ==
    /\ nlfc_6__phase \in nlfc_6__Phase
    /\ nlfc_5_4__clock \in nlfc_5_4__ClockMode
    /\ nlfc_6__ENGINE \in { "clause", "revives" }

\* @derives [NLFC.6.2]
\* FREED IS TERMINAL: once freed, always freed thereafter -- freed absorbs. A
\* temporal property over the whole behavior, not a snapshot.
nlfc_6_2__FreedIsTerminal ==
    [](nlfc_6__phase = "freed" => [](nlfc_6__phase = "freed"))

\* @spec [NLFC.6.2]
\* NO USE AFTER FREE: no step ever operates on a freed handle -- once freed the clock
\* never changes again (ToggleClock, the only handle-touching action, is disabled).
\*
\* A TRANSCRIPTION, NOT A CONSEQUENCE. The one action that
\* changes the clock is `nlfc_5_4__ToggleClock`, and its guard is that the phase
\* is not `freed`; this property says the clock does not change at `freed`. It
\* restates the guard, so what TLC checks of it is that the guard is there, which
\* is the header's TEETH. The tag is the one a transcription carries.
\*
\* WHAT IT SAYS OF THE CLAUSE, AND WHAT IT DOES NOT. [NLFC.6.2] has three
\* bullets: the handle is invalid, every fact and schema pointer from the engine
\* is invalid, no registered callback is invoked again. This property is the
\* first, for the one operation this model has on the handle. The model carries
\* no facts, no schemas and no callbacks, so the second and third bullets are
\* outside it -- not refuted, not stated. The tie's verdict is `partial` for
\* that reason, and `nlfc_6_2__Terminated` is the closest the model comes to the
\* third: the only step enabled at `freed` changes nothing.
nlfc_6_2__NoUseAfterFree ==
    [][nlfc_6__phase = "freed" => nlfc_5_4__clock' = nlfc_5_4__clock]_nlfc_6__vars

\* PROBES. Both properties above are of the form "once
\* freed, ...", and hold of a model in which nothing is ever freed; the second
\* is about a clock that does not change, and holds of one in which no clock is
\* ever substituted. The definition below says neither happens; its `.probe.`
\* config runs THIS engine and scripts/formal/check_tla.py requires TLC to end in a
\* violation.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no engine is ever freed on a substituted
\* clock. The run that breaks it substitutes the clock source on a live handle
\* and then frees the engine: the state both properties are about, in which the
\* mode the handle was freed in is the mode it keeps.
probe__never_freed_on_a_substituted_clock ==
    ~(nlfc_6__phase = "freed" /\ nlfc_5_4__clock = "mock")


\* WHAT THIS MODEL DOES NOT SAY ABOUT [NLFC.5.4]: [NLFC.5.4] reads "the clock
\* source is substituted, not switched back and forth", and "going back is not
\* guaranteed to resume the mock timeline". The model may take a substitution
\* in either direction, because both are legal calls on a live handle; it
\* promises nothing about the order they come in, and it carries no clock
\* VALUES, so the continuity half of the clause is outside it (the gap below).

\* @gap
gap__nlfc_5_4_time_continuity == TRUE
=============================================================================

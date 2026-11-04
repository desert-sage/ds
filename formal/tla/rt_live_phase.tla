------------------------------- MODULE rt_live_phase -------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS realtime INIT->LIVE phase gate -- the structurally-frozen LIVE phase, *)
(* as a TEMPORAL spec (TLA+ / TLC). The behavioral sibling of              *)
(* formal/alloy/rt_lifecycle.als: where the Alloy model fakes a trace with *)
(* util/ordering over a static set of steps and checks the frozen property *)
(* AT REST (every structural op precedes every pump), this models the      *)
(* lifecycle as an actual state machine (Init + Next) where structural      *)
(* operations are ATTEMPTED over time -- and proves the LIVE phase refuses   *)
(* them across every reachable state of every behavior. The movie, not the  *)
(* photograph.                                                             *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the `\* @spec [ID]` / `\* @derives [ID]` line above   *)
(* it repeats the clause so the checker confirms the id exists AND matches. *)
(*                                                                         *)
(* THE INVARIANT. RT execution has an INIT phase (load rules/schemas, size  *)
(* pools, warm the intern table) and a LIVE phase (pump, zero-alloc, NO     *)
(* structural change), joined by the one-way `ds_engine_go_live` gate       *)
(* ([NRTM.5.1] / [NRTM.5.2]). go_live requires its preconditions            *)
(* (`ds_engine_set_wm_max` first, then bundle loaded + warmed) or returns   *)
(* `DS_ERR_RT_PRECOND`; a structural op attempted after go_live returns     *)
(* `DS_ERR_RT_LIVE` and mutates nothing ([NRTM.5.3]). TLC proves LIVE is    *)
(* one-way (absorbing), that reaching LIVE implies both preconditions held, *)
(* and -- the headline -- that no structural generation ever advances while *)
(* the engine is LIVE.                                                      *)
(*                                                                         *)
(* TEETH. Drop the `nrtm_5_1__phase = "init"` guard on structural work (let  *)
(* a load land in LIVE and bump struct_gen) and `nrtm_5_3__live_is_frozen`   *)
(* fails -- TLC returns a trace with the structural generation advancing     *)
(* after go_live, exactly the zero-alloc breach LIVE forbids.               *)
(*                                                                         *)
(* THAT SENTENCE WAS RUN ONCE AND IS NOT A CONFIG.                         *)
(* `live_is_frozen` restates the guard, so an engine without the guard     *)
(* ran once, and the property failed of it as the sentence                 *)
(* says. The `.teeth.` configs beside this module are for the other two    *)
(* properties.                                                             *)
(***************************************************************************)
EXTENDS Naturals

\* @spec [NRTM.5.3]
\* Bound on structural loads in INIT -- keeps the state graph finite. Each load
\* (rule set / schema registration) advances the structural generation.
CONSTANT nrtm_5_3__MAXGEN

\* @spec [NRTM.5.1]
\* Which engine this run is of. "clause" is the clause's, and rt_live_phase.cfg
\* runs it. The others are engines the clauses rule out, each modelled so that a
\* property can be SEEN to fail: each `.teeth.` config
\* beside this module is a run scripts/formal/check_tla.py requires to end in a
\* violation, on every run of the lane.
\*   "ungated"  go_live does not ask for its preconditions
\*   "returns"  a pump in LIVE puts the engine back in INIT
CONSTANT nrtm_5_1__ENGINE

\* @spec [NRTM.5.1]
\* The two RT phases: INIT (load/size/warm) and LIVE (bounded zero-alloc pump).
nrtm_5_1__Phase == { "init", "live" }

\* @spec [NRTM.5.3]
\* The result code of the most recent operation: none yet, DS_OK, or the two RT
\* transition errors (DS_ERR_RT_LIVE, DS_ERR_RT_PRECOND).
nrtm_5_3__Result == { "none", "ok", "rt_live", "rt_precond" }

\* @spec [NRTM.5.1]
\* The current RT phase.
VARIABLE nrtm_5_1__phase

\* @spec [NRTM.5.2]
\* Whether ds_engine_set_wm_max has run -- pools sized and the intern table locked
\* (a go_live precondition).
VARIABLE nrtm_5_2__wm_max_set

\* @spec [NRTM.5.2]
\* Whether the bundle is loaded and warmed -- every workload string interned before
\* the lock (a go_live precondition).
VARIABLE nrtm_5_2__warmed

\* @spec [NRTM.5.3]
\* The structural generation -- how many structural changes (rule/schema loads) have
\* been applied. It may advance in INIT; the LIVE phase must freeze it.
VARIABLE nrtm_5_3__struct_gen

\* @spec [NRTM.5.3]
\* The result code the last operation reported.
VARIABLE nrtm_5_3__result

\* @spec [NRTM.5.1]
\* The state tuple -- the variables a lifecycle step may change.
nrtm_5_1__vars ==
    << nrtm_5_1__phase, nrtm_5_2__wm_max_set, nrtm_5_2__warmed,
       nrtm_5_3__struct_gen, nrtm_5_3__result >>

\* @spec [NRTM.5.1]
\* Initial state: a fresh engine in INIT, no wm_max, unwarmed, nothing loaded.
nrtm_5_1__Init ==
    /\ nrtm_5_1__phase = "init"
    /\ nrtm_5_2__wm_max_set = FALSE
    /\ nrtm_5_2__warmed = FALSE
    /\ nrtm_5_3__struct_gen = 0
    /\ nrtm_5_3__result = "none"

\* @spec [NRTM.5.2]
\* ds_engine_set_wm_max: sizes the pools and locks the intern table. INIT-only, and
\* a go_live precondition. Guarded off "already set" to keep the graph finite.
nrtm_5_2__SetWmMax ==
    /\ nrtm_5_1__phase = "init"
    /\ nrtm_5_2__wm_max_set = FALSE
    /\ nrtm_5_2__wm_max_set' = TRUE
    /\ nrtm_5_3__result' = "ok"
    /\ UNCHANGED << nrtm_5_1__phase, nrtm_5_2__warmed, nrtm_5_3__struct_gen >>

\* @spec [NRTM.5.1]
\* A structural change in INIT -- load rules / register schemas and warm the intern
\* table. Advances the structural generation and marks the bundle warmed. INIT-only.
nrtm_5_1__LoadWarm ==
    /\ nrtm_5_1__phase = "init"
    /\ nrtm_5_3__struct_gen < nrtm_5_3__MAXGEN
    /\ nrtm_5_3__struct_gen' = nrtm_5_3__struct_gen + 1
    /\ nrtm_5_2__warmed' = TRUE
    /\ nrtm_5_3__result' = "ok"
    /\ UNCHANGED << nrtm_5_1__phase, nrtm_5_2__wm_max_set >>

\* @spec [NRTM.5.2]
\* ds_engine_go_live: the one-way INIT->LIVE gate. Fires only with both
\* preconditions met (wm_max set, bundle warmed); phase advances and never returns.
nrtm_5_2__GoLive ==
    /\ nrtm_5_1__phase = "init"
    /\ (nrtm_5_1__ENGINE = "ungated" \/ nrtm_5_2__wm_max_set = TRUE)
    /\ (nrtm_5_1__ENGINE = "ungated" \/ nrtm_5_2__warmed = TRUE)
    /\ nrtm_5_1__phase' = "live"
    /\ nrtm_5_3__result' = "ok"
    /\ UNCHANGED << nrtm_5_2__wm_max_set, nrtm_5_2__warmed, nrtm_5_3__struct_gen >>

\* @spec [NRTM.5.3]
\* go_live attempted before its preconditions are met -- refused with
\* DS_ERR_RT_PRECOND; the engine stays in INIT and nothing structural changes.
nrtm_5_3__GoLivePrecondFail ==
    /\ nrtm_5_1__phase = "init"
    /\ ~(nrtm_5_2__wm_max_set = TRUE /\ nrtm_5_2__warmed = TRUE)
    /\ nrtm_5_3__result' = "rt_precond"
    /\ UNCHANGED << nrtm_5_1__phase, nrtm_5_2__wm_max_set, nrtm_5_2__warmed,
                    nrtm_5_3__struct_gen >>

\* @spec [NRTM.5.3]
\* A structural op (load rules / register schema) attempted in LIVE -- refused with
\* DS_ERR_RT_LIVE. It reports the error and mutates NOTHING: the structural
\* generation is unchanged. This is the frozen phase's teeth.
nrtm_5_3__StructuralRefused ==
    /\ nrtm_5_1__phase = "live"
    /\ nrtm_5_3__result' = "rt_live"
    /\ UNCHANGED << nrtm_5_1__phase, nrtm_5_2__wm_max_set, nrtm_5_2__warmed,
                    nrtm_5_3__struct_gen >>

\* @spec [NRTM.5.1]
\* A LIVE-phase pump: bounded, zero-alloc, no structural change. LIVE-only.
nrtm_5_1__Pump ==
    /\ nrtm_5_1__phase = "live"
    /\ nrtm_5_3__result' = "ok"
    /\ nrtm_5_1__phase' = (IF nrtm_5_1__ENGINE = "returns" THEN "init" ELSE "live")
    /\ UNCHANGED << nrtm_5_2__wm_max_set, nrtm_5_2__warmed, nrtm_5_3__struct_gen >>

\* @spec [NRTM.5.1]
\* Next: INIT setup (wm_max, load/warm, go_live or its precond failure), then the
\* LIVE-phase steps (refused structural op, pump). Every state has an enabled step,
\* so LIVE loops forever -- terminal phase, but not a deadlock.
nrtm_5_1__Next ==
    \/ nrtm_5_2__SetWmMax
    \/ nrtm_5_1__LoadWarm
    \/ nrtm_5_2__GoLive
    \/ nrtm_5_3__GoLivePrecondFail
    \/ nrtm_5_3__StructuralRefused
    \/ nrtm_5_1__Pump

\* @spec [NRTM.5.1]
\* The behavior spec: Init, then stutter-closed steps of Next. A SAFETY spec -- the
\* guarantees are invariants over reachable states, so no fairness is required.
nrtm_5_1__Spec == nrtm_5_1__Init /\ [][nrtm_5_1__Next]_nrtm_5_1__vars

\* @spec [NRTM.5.1]
\* Type-correctness -- a state invariant true at every reachable state.
nrtm_5_1__TypeOK ==
    /\ nrtm_5_1__phase \in nrtm_5_1__Phase
    /\ nrtm_5_2__wm_max_set \in BOOLEAN
    /\ nrtm_5_2__warmed \in BOOLEAN
    /\ nrtm_5_3__struct_gen \in 0..nrtm_5_3__MAXGEN
    /\ nrtm_5_3__result \in nrtm_5_3__Result
    /\ nrtm_5_1__ENGINE \in { "clause", "ungated", "returns" }

\* @derives [NRTM.5.2]
\* PRECONDITIONS HELD (safety): the engine is never LIVE without both go_live
\* preconditions having been satisfied -- the gate is never bypassed. NO
\* counterexample.
nrtm_5_2__live_implies_preconds ==
    (nrtm_5_1__phase = "live") =>
        (nrtm_5_2__wm_max_set = TRUE /\ nrtm_5_2__warmed = TRUE)

\* @derives [NRTM.5.2]
\* ONE-WAY (safety, temporal): once LIVE, always LIVE -- the INIT->LIVE transition
\* never reverses (live absorbs). NO counterexample.
nrtm_5_2__live_is_terminal ==
    [](nrtm_5_1__phase = "live" => [](nrtm_5_1__phase = "live"))

\* @spec [NRTM.5.3]
\* FROZEN LIVE (safety, temporal): no structural change ever occurs while the engine
\* is LIVE -- the structural generation is unchanged on every step taken from a LIVE
\* state (a refused load reports DS_ERR_RT_LIVE but mutates nothing). This is the
\* over-time form of rt_lifecycle.als's at-rest frozen assertion. NO counterexample.
\*
\* TAGGED `spec`, NOT `derives`: `nrtm_5_1__LoadWarm` is the only action that
\* moves `struct_gen`, and `phase = "init"` is its guard, so this property
\* restates the guard (the TEETH above: drop it and this fails). A transcription
\* check, not a derivation.
nrtm_5_3__live_is_frozen ==
    [][ nrtm_5_1__phase = "live" =>
          nrtm_5_3__struct_gen' = nrtm_5_3__struct_gen ]_nrtm_5_1__vars

\* PROBES. All three properties above are of the form
\* "whenever the engine is LIVE, ...", and hold of a model that never goes
\* live; the third is about a structural operation ATTEMPTED in LIVE, and holds
\* of one in which none is. The definition below says none is; its `.probe.`
\* config runs THIS engine, with the constants of rt_live_phase.cfg, and
\* scripts/formal/check_tla.py requires TLC to end in a violation.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no operation is ever refused for the engine
\* being LIVE. The run that breaks it sizes the pools, loads and warms, goes
\* live, and attempts a structural operation, which is refused.
probe__live_refuses_nothing ==
    nrtm_5_3__result # "rt_live"

=============================================================================

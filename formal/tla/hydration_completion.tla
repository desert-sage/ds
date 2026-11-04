------------------------------ MODULE hydration_completion ------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS fact hydration -- the completion protocol, as a LIVENESS spec        *)
(* (TLA+ / TLC). A `call <adapter>;hydrate_*` rides the ordinary call      *)
(* surface ([NCBK.9]): the engine gates it on the working-memory hydration *)
(* budget ([RHIM.5.1]), then the adapter asserts the matching facts one at *)
(* a time ([RHIM.3.2]) and finally signals the outcome. This model has no  *)
(* static Alloy sibling: the guarantee is intrinsically about what happens *)
(* OVER TIME -- that a dispatched hydration cannot stall half-done.        *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the `\* @spec [ID]` / `\* @derives [ID]` line above   *)
(* it repeats the clause so the checker confirms the id exists AND matches. *)
(*                                                                         *)
(* THE GUARANTEE. Every hydration reaches a terminal OUTCOME -- it either   *)
(* completes (a single `HydrationComplete` emitted strictly AFTER all its   *)
(* facts, [RHIM.3.4] / [LHYD.5.3]) or fails cleanly (a `CallError`, either  *)
(* the budget-gate rejection [RHIM.5.1.2] or an adapter query failure       *)
(* [RHIM.3.6]). It never parks half-hydrated: some facts asserted but no    *)
(* completion and no error, which a waiting rule would observe as a         *)
(* permanent hang. TLC proves the SAFETY invariant (HydrationComplete only  *)
(* in a state where all facts are already asserted, [RHIM.3.4]) and the     *)
(* LIVENESS property (the outcome always eventually arrives, [LHYD.5]).     *)
(*                                                                         *)
(* TEETH. Liveness holds ONLY under weak fairness on completion. Drop       *)
(* `WF_..(rhim_3_4__Complete)` from the spec and TLC returns a behavior     *)
(* parked in "asserting" with every fact asserted but `HydrationComplete`   *)
(* never emitted -- the half-hydrated hang [RHIM.3.6] / [LHYD.5.3] forbid.  *)
(*                                                                         *)
(* DEFERRED WITH ITS CLAUSES. Every clause this module ties -- [NCBK.9],   *)
(* [LHYD.5], [RHIM.3], [RHIM.3.2], [RHIM.3.4], [RHIM.3.6], [RHIM.5.1] and   *)
(* [RHIM.5.1.2] -- is `deferred` in this edition: hydration, the `storage;` *)
(* services and the `hydrate_*` calls are in the tree and bind nothing in  *)
(* v1, and no v1 program can issue the call this protocol begins with. The *)
(* module is kept, run and tied as the model of that deferred contract, so  *)
(* a green here says what the contract will hold when an edition binds it   *)
(* and says NOTHING about a v1 runtime, which has no hydration to get      *)
(* right or wrong. It is not deleted because the clauses are not: when     *)
(* they bind, the model is already theirs, with the readings above.        *)
(***************************************************************************)
EXTENDS Naturals

\* @spec [RHIM.5.1]
\* The global hydration budget: the max facts with a non-empty hydrated_corr the
\* engine permits in working memory before it refuses a new hydration.
CONSTANT rhim_5_1__BUDGET

\* @spec [RHIM.3.2]
\* How many facts this hydration's adapter would assert on a clean run (its result
\* set, already bounded by the caller's limit: / adapter cap).
CONSTANT rhim_3_2__TARGET

\* @spec [RHIM.3]
\* Which engine this run is of. "clause" is the clause's, and
\* hydration_completion.cfg runs it. The others are engines the clauses rule
\* out, each modelled so that a property can be SEEN to fail: each
\* `.teeth.` config beside this module is a run
\* scripts/formal/check_tla.py requires to end in a violation, on every run of
\* the lane.
\*   "completes_early"  the completion does not wait for the last fact
\*   "never_completes"  the adapter asserts every fact and emits no completion:
\*                      the header's TEETH, as an engine
CONSTANT rhim_3__ENGINE

\* @spec [RHIM.3]
\* The hydration protocol states: pending (issued, pre-gate), asserting (dispatched,
\* adapter mid-batch), then the three terminal outcomes.
rhim_3__Hstate == { "pending", "asserting", "completed", "rejected", "failed" }

\* @spec [RHIM.3]
\* The terminal outcomes -- an emitted signal every one: completed => HydrationComplete,
\* rejected/failed => CallError. There is no silent-stop state.
rhim_3__Terminal == { "completed", "rejected", "failed" }

\* @spec [RHIM.3]
\* The current protocol state of the hydration.
VARIABLE rhim_3__hstate

\* @spec [RHIM.3.2]
\* Count of hydrated facts the adapter has asserted so far for this call.
VARIABLE rhim_3_2__asserted

\* @spec [RHIM.5.1]
\* Working-memory hydration occupancy the engine reads at the budget gate -- the
\* facts already carrying a non-empty hydrated_corr when this call arrives.
VARIABLE rhim_5_1__wm_hydrated

\* @spec [RHIM.3]
\* The state tuple -- the variables a protocol step may change.
rhim_3__vars == << rhim_3__hstate, rhim_3_2__asserted, rhim_5_1__wm_hydrated >>

\* @spec [RHIM.3]
\* Initially the call is pending with nothing asserted; the working memory holds some
\* prior hydration occupancy in 0..BUDGET, so TLC explores both gate branches.
rhim_3__Init ==
    /\ rhim_3__hstate = "pending"
    /\ rhim_3_2__asserted = 0
    /\ rhim_5_1__wm_hydrated \in 0..rhim_5_1__BUDGET

\* @spec [RHIM.5.1.2]
\* Budget gate -- refuse: at or over budget, the engine asserts a CallError
\* ("budget_exhausted") for the correlation and does NOT dispatch to the adapter.
rhim_5_1_2__Reject ==
    /\ rhim_3__hstate = "pending"
    /\ rhim_5_1__wm_hydrated >= rhim_5_1__BUDGET
    /\ rhim_3__hstate' = "rejected"
    /\ UNCHANGED << rhim_3_2__asserted, rhim_5_1__wm_hydrated >>

\* @spec [NCBK.9]
\* Dispatch: under budget, the engine hands the hydrate_* call to the integrator over
\* the ordinary call surface (there is no dedicated hydration callback).
ncbk_9__Dispatch ==
    /\ rhim_3__hstate = "pending"
    /\ rhim_5_1__wm_hydrated < rhim_5_1__BUDGET
    /\ rhim_3__hstate' = "asserting"
    /\ UNCHANGED << rhim_3_2__asserted, rhim_5_1__wm_hydrated >>

\* @spec [RHIM.3.2]
\* The adapter asserts the next hydrated fact (tagged with the correlation). The gate
\* already read wm_hydrated pre-dispatch ([RHIM.5.1.2]), so it is unchanged here.
rhim_3_2__AssertFact ==
    /\ rhim_3__hstate = "asserting"
    /\ rhim_3_2__asserted < rhim_3_2__TARGET
    /\ rhim_3_2__asserted' = rhim_3_2__asserted + 1
    /\ UNCHANGED << rhim_3__hstate, rhim_5_1__wm_hydrated >>

\* @spec [RHIM.3.4]
\* Completion: the adapter emits the single HydrationComplete -- but ONLY once every
\* fact is asserted (guard asserted = TARGET), so a rule matching it sees the full
\* hydrated set first ([LHYD.5.3]).
rhim_3_4__Complete ==
    /\ rhim_3__hstate = "asserting"
    /\ (rhim_3__ENGINE = "completes_early" \/ rhim_3_2__asserted = rhim_3_2__TARGET)
    /\ IF rhim_3__ENGINE = "never_completes"
         THEN UNCHANGED rhim_3__vars
         ELSE /\ rhim_3__hstate' = "completed"
              /\ UNCHANGED << rhim_3_2__asserted, rhim_5_1__wm_hydrated >>

\* @spec [RHIM.3.6]
\* Query failure: the backing query can fail at any point in the batch. The adapter
\* MUST assert a CallError rather than completing silently, so a waiting rule observes
\* the failure -- enabled regardless of how many facts already landed.
rhim_3_6__Fail ==
    /\ rhim_3__hstate = "asserting"
    /\ rhim_3__hstate' = "failed"
    /\ UNCHANGED << rhim_3_2__asserted, rhim_5_1__wm_hydrated >>

\* @spec [RHIM.3]
\* A resolved hydration takes no further action -- explicit terminal stutter so a
\* terminal outcome is a legitimate end state, not a TLC deadlock.
rhim_3__Terminated ==
    /\ rhim_3__hstate \in rhim_3__Terminal
    /\ UNCHANGED rhim_3__vars

\* @spec [RHIM.3]
\* Next: gate (reject | dispatch), then assert / complete / fail; else terminal idle.
rhim_3__Next ==
    \/ rhim_5_1_2__Reject
    \/ ncbk_9__Dispatch
    \/ rhim_3_2__AssertFact
    \/ rhim_3_4__Complete
    \/ rhim_3_6__Fail
    \/ rhim_3__Terminated

\* @spec [RHIM.3]
\* The behavior spec. WEAK FAIRNESS on the gate, on each fact assertion, and on
\* completion is what turns "the hydration eventually resolves" into a guarantee.
\* Fail carries NO fairness -- a query MAY fail but is never forced to (like an
\* adapter that never answers is allowed on a general call).
rhim_3__Spec ==
    /\ rhim_3__Init
    /\ [][rhim_3__Next]_rhim_3__vars
    /\ WF_rhim_3__vars(rhim_5_1_2__Reject \/ ncbk_9__Dispatch)
    /\ WF_rhim_3__vars(rhim_3_2__AssertFact)
    /\ WF_rhim_3__vars(rhim_3_4__Complete)

\* @spec [RHIM.3]
\* Type-correctness -- a state invariant true at every reachable state.
rhim_3__TypeOK ==
    /\ rhim_3__hstate \in rhim_3__Hstate
    /\ rhim_3_2__asserted \in 0..rhim_3_2__TARGET
    /\ rhim_5_1__wm_hydrated \in 0..rhim_5_1__BUDGET
    /\ rhim_3__ENGINE \in { "clause", "completes_early", "never_completes" }

\* @derives [RHIM.3.4]
\* COMPLETE AFTER ALL (safety): HydrationComplete is emitted strictly after every
\* fact -- whenever the hydration is "completed", all TARGET facts are already
\* asserted ([LHYD.5.3]). NO counterexample.
rhim_3_4__complete_after_all ==
    (rhim_3__hstate = "completed") => (rhim_3_2__asserted = rhim_3_2__TARGET)

\* @derives [LHYD.5]
\* EVENTUALLY RESOLVES (liveness): every hydration eventually reaches a terminal
\* outcome -- it completes or fails cleanly, never parking half-hydrated. Holds only
\* under weak fairness on the gate / assertion / completion (see TEETH). NO
\* counterexample.
lhyd_5__eventually_resolves ==
    <>(rhim_3__hstate \in rhim_3__Terminal)

\* PROBES. `complete_after_all` is of the form "whenever
\* the hydration is completed, ...", and holds of a model in which none ever
\* completes. `eventually_resolves` names three outcomes and is as true of a
\* model that reaches one of them as of one that reaches all three. Each
\* definition below says an outcome never happens; its `.probe.` config runs
\* THIS engine, with the constants of hydration_completion.cfg, and
\* scripts/formal/check_tla.py requires TLC to end in a violation.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no hydration completes. The run that breaks
\* it dispatches, asserts every fact and emits the completion.
probe__never_completes ==
    rhim_3__hstate # "completed"

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no hydration fails with some of its facts
\* asserted and some not. The run that breaks it is the half-hydrated state
\* the header says cannot be parked in, left by a failure that is signalled.
probe__never_fails_part_way ==
    ~( /\ rhim_3__hstate = "failed"
       /\ rhim_3_2__asserted > 0
       /\ rhim_3_2__asserted < rhim_3_2__TARGET )

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no hydration is refused at the budget gate.
\* The run that breaks it starts at the budget and is rejected undispatched.
probe__never_refused ==
    rhim_3__hstate # "rejected"

=============================================================================

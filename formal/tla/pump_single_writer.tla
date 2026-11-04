----------------------------- MODULE pump_single_writer -----------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS pump -- single-writer exclusion + drain-to-exhaustion, as a          *)
(* SAFETY+LIVENESS spec (TLA+ / TLC). This extends formal/tla/determinism  *)
(* (two-copy lockstep firing) with the two things a pump boundary adds:    *)
(* the pump is the ONLY writer ([NLFC.3.3]) -- an external assert may       *)
(* interleave BETWEEN pumps but never DURING one -- and a pump runs the     *)
(* agenda to EXHAUSTION before it returns ([NLFC.2.2] / [NLFC.2.4]), even   *)
(* though firing an activation can cascade new activations onto the agenda. *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the `\* @spec [ID]` / `\* @derives [ID]` line above   *)
(* it repeats the clause so the checker confirms the id exists AND matches. *)
(*                                                                         *)
(* THE GUARANTEE. Two writers never overlap ([NLFC.3.3]: concurrent pump +  *)
(* assert is undefined behaviour, so the integrator serialises externally); *)
(* a pump returns ONLY with the agenda drained ([NLFC.2.2]); and under weak *)
(* fairness on firing every pump eventually returns -- it cannot stall      *)
(* mid-drain. TLC proves the exclusion invariant and the returns-only-when- *)
(* drained safety over every interleaving, plus the eventual-return         *)
(* liveness over fair runs.                                                 *)
(*                                                                         *)
(* TEETH. Exclusion holds only because both `*Begin` actions require the    *)
(* other writer idle. Drop `~nlfc_2_2__pumping` from `nlfc_3_3__ExternBegin` *)
(* and `nlfc_3_3__single_writer` fails -- TLC returns a state with a pump    *)
(* and an external assert both live, the exact race [NLFC.3.3] forbids.     *)
(***************************************************************************)
EXTENDS Naturals

\* @spec [NLFC.2.2]
\* Cap on activations queued on the agenda -- bounds the state graph.
CONSTANT nlfc_2_2__CAP

\* @spec [NLFC.2.2]
\* Cascade budget: how many times firing an activation may spawn a new one. Bounds
\* the cascade so the drain terminates (real refraction stops re-firing).
CONSTANT nlfc_2_2__SPAWN

\* @spec [NLFC.2.2]
\* Which engine this run is of. "clause" is the clause's, and
\* pump_single_writer.cfg runs it. The others are engines the clauses rule out,
\* each modelled so that a property can be SEEN to fail:
\* each `.teeth.` config beside this module is a run scripts/formal/check_tla.py
\* requires to end in a violation, on every run of the lane.
\*   "unserialised"  the integrator takes the writer while a pump runs: the
\*                   header's TEETH, as an engine
\*   "stalls"        a pump with activations on its agenda fires none of them
CONSTANT nlfc_2_2__ENGINE

\* @spec [NLFC.2.2]
\* Whether a pump is currently in progress (ds_engine_pump has not yet returned).
VARIABLE nlfc_2_2__pumping

\* @spec [NLFC.3.3]
\* Whether the integrator currently holds the writer to assert externally. Pump and
\* extern are the two writers that [NLFC.3.3] forbids from overlapping.
VARIABLE nlfc_3_3__externing

\* @spec [NLFC.2.2]
\* Fireable activations pending on the agenda.
VARIABLE nlfc_2_2__agenda

\* @spec [NLFC.2.2]
\* Remaining cascade spawns -- decremented each time a firing enqueues a new
\* activation, so the agenda cannot regenerate forever.
VARIABLE nlfc_2_2__spawn_budget

\* @spec [NLFC.2.2]
\* The state tuple -- the variables a step may change.
nlfc_2_2__vars ==
    << nlfc_2_2__pumping, nlfc_3_3__externing, nlfc_2_2__agenda,
       nlfc_2_2__spawn_budget >>

\* @spec [NLFC.2.2]
\* Initially no writer is active; the agenda holds some pending activations; the full
\* cascade budget is available.
nlfc_2_2__Init ==
    /\ nlfc_2_2__pumping = FALSE
    /\ nlfc_3_3__externing = FALSE
    /\ nlfc_2_2__agenda \in 0..nlfc_2_2__CAP
    /\ nlfc_2_2__spawn_budget = nlfc_2_2__SPAWN

\* @spec [NLFC.3.3]
\* The integrator acquires the single-writer role to assert -- allowed only when NO
\* writer is active (no pump running, not already externing). This is the external
\* serialisation [NLFC.3.3] requires.
nlfc_3_3__ExternBegin ==
    /\ (nlfc_2_2__ENGINE = "unserialised" \/ nlfc_2_2__pumping = FALSE)
    /\ nlfc_3_3__externing = FALSE
    /\ nlfc_3_3__externing' = TRUE
    /\ UNCHANGED << nlfc_2_2__pumping, nlfc_2_2__agenda, nlfc_2_2__spawn_budget >>

\* @spec [NLFC.3.3]
\* While holding the writer, the integrator asserts a fact -- a new activation lands
\* on the agenda. Only ever runs between pumps, never during one.
nlfc_3_3__ExternAssert ==
    /\ nlfc_3_3__externing = TRUE
    /\ nlfc_2_2__agenda < nlfc_2_2__CAP
    /\ nlfc_2_2__agenda' = nlfc_2_2__agenda + 1
    /\ UNCHANGED << nlfc_2_2__pumping, nlfc_3_3__externing, nlfc_2_2__spawn_budget >>

\* @spec [NLFC.3.3]
\* The integrator releases the writer.
nlfc_3_3__ExternEnd ==
    /\ nlfc_3_3__externing = TRUE
    /\ nlfc_3_3__externing' = FALSE
    /\ UNCHANGED << nlfc_2_2__pumping, nlfc_2_2__agenda, nlfc_2_2__spawn_budget >>

\* @spec [NLFC.2.2]
\* ds_engine_pump is called -- the pump acquires the single-writer role. Allowed only
\* when no writer is active.
nlfc_2_2__PumpBegin ==
    /\ nlfc_2_2__pumping = FALSE
    /\ nlfc_3_3__externing = FALSE
    /\ nlfc_2_2__pumping' = TRUE
    /\ UNCHANGED << nlfc_3_3__externing, nlfc_2_2__agenda, nlfc_2_2__spawn_budget >>

\* @spec [NLFC.2.2]
\* Fire one activation. It may cascade a new activation onto the agenda (consuming a
\* spawn from the budget) or not; either way the pump keeps going until the agenda is
\* empty ("runs the agenda to exhaustion").
nlfc_2_2__PumpFire ==
    /\ nlfc_2_2__pumping = TRUE
    /\ nlfc_2_2__agenda > 0
    /\ IF nlfc_2_2__ENGINE = "stalls"
         THEN UNCHANGED nlfc_2_2__vars
         ELSE /\ \E spawn \in {0, 1} :
                   /\ (spawn = 1) => (nlfc_2_2__spawn_budget > 0)
                   /\ nlfc_2_2__agenda' = nlfc_2_2__agenda - 1 + spawn
                   /\ nlfc_2_2__spawn_budget' = nlfc_2_2__spawn_budget - spawn
              /\ UNCHANGED << nlfc_2_2__pumping, nlfc_3_3__externing >>

\* @spec [NLFC.2.2]
\* The pump returns DS_OK -- allowed ONLY once the agenda is drained ([NLFC.2.4]:
\* "the agenda is drained"). Releases the single-writer role.
nlfc_2_2__PumpReturn ==
    /\ nlfc_2_2__pumping = TRUE
    /\ nlfc_2_2__agenda = 0
    /\ nlfc_2_2__pumping' = FALSE
    /\ UNCHANGED << nlfc_3_3__externing, nlfc_2_2__agenda, nlfc_2_2__spawn_budget >>

\* @spec [NLFC.2.2]
\* Next: an external writer acquires / asserts / releases, or a pump begins / fires /
\* returns. Every state can begin a writer, so there is no deadlock.
nlfc_2_2__Next ==
    \/ nlfc_3_3__ExternBegin
    \/ nlfc_3_3__ExternAssert
    \/ nlfc_3_3__ExternEnd
    \/ nlfc_2_2__PumpBegin
    \/ nlfc_2_2__PumpFire
    \/ nlfc_2_2__PumpReturn

\* @spec [NLFC.2.2]
\* The behavior spec. WEAK FAIRNESS on firing and on the return turns "a pump drains
\* and eventually returns" into a guarantee. The external writer and PumpBegin carry
\* NO fairness -- asserting and pumping are the integrator's choice, never forced.
nlfc_2_2__Spec ==
    /\ nlfc_2_2__Init
    /\ [][nlfc_2_2__Next]_nlfc_2_2__vars
    /\ WF_nlfc_2_2__vars(nlfc_2_2__PumpFire)
    /\ WF_nlfc_2_2__vars(nlfc_2_2__PumpReturn)

\* @spec [NLFC.2.2]
\* Type-correctness -- a state invariant true at every reachable state.
nlfc_2_2__TypeOK ==
    /\ nlfc_2_2__pumping \in BOOLEAN
    /\ nlfc_3_3__externing \in BOOLEAN
    /\ nlfc_2_2__agenda \in 0..nlfc_2_2__CAP
    /\ nlfc_2_2__spawn_budget \in 0..nlfc_2_2__SPAWN
    /\ nlfc_2_2__ENGINE \in { "clause", "unserialised", "stalls" }

\* @derives [NLFC.3.3]
\* SINGLE WRITER (safety): a pump and an external write are never both active -- the
\* concurrent pump+assert that [NLFC.3.3] declares undefined behaviour is unreachable.
\* NO counterexample.
nlfc_3_3__single_writer ==
    ~(nlfc_2_2__pumping = TRUE /\ nlfc_3_3__externing = TRUE)

\* @spec [NLFC.2.2]
\* RETURNS ONLY WHEN DRAINED (safety): a pump goes from in-progress to returned only
\* in a state whose agenda is empty -- it never returns mid-drain ([NLFC.2.4]). NO
\* counterexample.
\*
\* TAGGED `spec`, NOT `derives`: `nlfc_2_2__PumpReturn` is the only action that
\* takes `pumping` from TRUE to FALSE, and `agenda = 0` is its guard, so this
\* property restates the guard. A transcription check, not a derivation;
\* `nlfc_2_2__pump_drains` is the derived property.
nlfc_2_2__return_only_when_drained ==
    [][ (nlfc_2_2__pumping = TRUE /\ nlfc_2_2__pumping' = FALSE)
          => nlfc_2_2__agenda = 0 ]_nlfc_2_2__vars

\* @derives [NLFC.2.2]
\* PUMP DRAINS (liveness): every pump in progress eventually returns -- it cannot
\* stall mid-drain. With returns-only-when-drained, this is "runs the agenda to
\* exhaustion". Holds under weak fairness on firing / return (see TEETH). NO
\* counterexample.
nlfc_2_2__pump_drains ==
    [](nlfc_2_2__pumping = TRUE => <>(nlfc_2_2__pumping = FALSE))

\* PROBES. `return_only_when_drained` and `pump_drains` are
\* of the form "whenever a pump ...", and hold of a model in which no pump
\* runs; the header's claim is about a pump whose firings CASCADE. And
\* `single_writer` says two writers never overlap, which is as true of a model
\* with one writer as of one with two that take turns. Each definition below
\* says one of these never happens; its `.probe.` config runs THIS engine, with
\* the constants of pump_single_writer.cfg, and scripts/formal/check_tla.py
\* requires TLC to end in a violation.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: once a firing has put a new activation on the
\* agenda, the pump never returns. The run that breaks it is a pump that
\* fires, cascades, drains what the cascade added, and returns.
probe__a_cascade_never_returns ==
    []( nlfc_2_2__spawn_budget < nlfc_2_2__SPAWN
          => [](nlfc_2_2__pumping = TRUE) )

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: once the integrator has held the writer, no
\* pump ever runs. The run that breaks it has the two writers in turn: the
\* integrator takes the writer and releases it, and a pump begins after. It
\* need assert nothing while it holds the writer, and in the shortest such run
\* it does not.
probe__after_a_write_no_pump ==
    []( nlfc_3_3__externing = TRUE
          => [](nlfc_2_2__pumping = FALSE) )

=============================================================================

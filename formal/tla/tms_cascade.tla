---------------------------------- MODULE tms_cascade ----------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS truth maintenance -- the retract-propagation CASCADE, as a temporal  *)
(* spec (TLA+ / TLC). The behavioral sibling of                            *)
(* formal/alloy/tms_justification.als: the Alloy model proves "a logical   *)
(* fact is live IFF it is justified" AT THE FIXPOINT (a snapshot); this     *)
(* models the CASCADE that reaches that fixpoint -- retract a supporting    *)
(* fact, justif_count drops, facts that hit zero are retracted, and the     *)
(* retraction propagates ([IRET.12.2]) -- and proves it terminates in a     *)
(* consistent state without leaking or over-retracting.                     *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* is named <lowercased-clause-id>__<Tag> after the paragraph it           *)
(* formalizes, and the `\* @spec [ID]` / `\* @derives [ID]` line above it    *)
(* repeats the clause so the checker confirms the id exists AND matches.    *)
(*                                                                         *)
(* THE GUARANTEE. Base facts (inputs) are externally asserted; derived      *)
(* facts are supported while at least one justification has all its         *)
(* antecedents live -- justif_count > 0, modelled without Int as "some      *)
(* active justifier." The support graph is acyclic (DS forbids self-        *)
(* deriving cycles), with f2 carrying TWO justifications (a multi-justifier)*)
(* and f3 chained off f2. TLC proves the SAFETY property -- a fact with a   *)
(* live justifier is never retracted ([IRET.12.3], multi-justifier         *)
(* survival) -- and the LIVENESS property -- every fact left without a      *)
(* justifier is eventually retracted, so the cascade completes and never    *)
(* leaks an unsupported fact ([IRET.12.2]).                                 *)
(*                                                                         *)
(* TEETH. Liveness holds ONLY under weak fairness on the cascade. Drop      *)
(* `WF_..(iret_12_2__Cascade(f))` and TLC returns a behavior where an       *)
(* unsupported fact lingers live forever -- the TMS failing to retract a    *)
(* fact whose entire support was withdrawn.                                 *)
(*                                                                         *)
(* MODEL <-> MODEL. This is the COUNT's                                    *)
(* mechanism as a cascade: `iret_12_2__Cascade` retracts a derived fact     *)
(* whose every justification has lost an antecedent, and what it leaves is  *)
(* the greatest self-supported set below the live facts --                  *)
(* formal/idris/Rete/Refcount.idr's `iret_12_2__cascade`                    *)
(* (`iret_12_2__cascade_greatest`), one fact per step. On an unfounded      *)
(* cycle that set KEEPS the cycle, as the count does; the obligation's      *)
(* answer, Refcount.idr's `llog_2_5__well_founded`, drops it                *)
(* (`iret_12_2__witness_refcount` / `llog_2_5__witness_well_founded`: P ->  *)
(* Q, Q -> R, R -> Q, retract P). Both graphs are drawn here, chosen by     *)
(* `iret_12__GRAPH`, and the obligation is stated beside the count as the   *)
(* invariant `iret_12_2__quiescent_is_well_founded` over the least fixpoint *)
(* `llog_2_5__WellFounded`: tms_cascade.cfg holds it on the ranked graph    *)
(* over every behaviour (`iret_12_2__tla_retract_f1` is two of its states), *)
(* and tms_cascade.teeth.cycle.cfg requires its violation on the cycle,     *)
(* where the count keeps Q and R. So `no_unsupported_forever` is the count  *)
(* reaching its fixpoint, on acyclic support the contract's fixpoint        *)
(* (well-founded support is the                                             *)
(* contract) and on cyclic support not; its tie carries `verdict: partial`  *)
(* for that reason. The two                                                 *)
(* configs and `instances.stamp` hold this comparison on every lane run.   *)
(*                                                                         *)
(* POSITIVE PROGRAMS ONLY. "Supported while some                           *)
(* justification has every antecedent live" is the count's reading for a   *)
(* rule whose match ends only when a matched fact dies. A `no` pattern     *)
(* ends an activation with every antecedent still live: the blocker binds  *)
(* nothing and is in no justification, so the count drops to zero and a    *)
(* conforming engine retracts, where this model still reads the fact as    *)
(* supported and `multi_justifier_survives` forbids the retraction. The    *)
(* model draws no `no` pattern, so it says nothing of one: its ties read   *)
(* on positive programs, the scope of Rete/TmsBridge.idr's                 *)
(* `Iret_7_9__positive`.                                                   *)
(***************************************************************************)

\* @spec [IRET.12]
\* Which engine this run is of. "clause" is the clause's, and tms_cascade.cfg
\* runs it. The other is an engine the clause rules out, modelled so that a
\* property can be SEEN to fail: the `.teeth.` config beside
\* this module is a run scripts/formal/check_tla.py requires to end in a
\* violation, on every run of the lane.
\*   "no_cascade"  a derived fact left without support is not retracted: the
\*                 header's TEETH, as an engine
CONSTANT iret_12__ENGINE

\* @spec [IRET.12]
\* Which support graph the run is over. "ranked" is the clause's instance, and
\* tms_cascade.cfg runs it: acyclic, so a ranking exists and the count is the
\* obligation (Rete/Refcount.idr's `iret_12_3__ranked_agree`). The other is the
\* graph [LCYC.3.1.1] rules out, modelled so that [IRET.12.2]'s own sentence --
\* "on a support cycle it keeps every member's count above zero with no
\* well-founded justification left" -- can be SEEN to happen: the
\* `.teeth.cycle.` config runs it and scripts/formal/check_tla.py requires the
\* obligation to be violated there, on every run of the lane.
\*   "cycle"  Rete/Refcount.idr's `llog_2_5__witness_js`: P base; Q <- {P},
\*            R <- {Q}, Q <- {R}. Q and R each justify the other.
CONSTANT iret_12__GRAPH

\* @spec [IRET.12]
\* The facts. On the ranked graph f1, f4 are base (external inputs) and f2, f3
\* are derived; on the cycle P is base and Q, R are derived.
iret_12__Fact ==
    IF iret_12__GRAPH = "cycle" THEN { "P", "Q", "R" } ELSE { "f1", "f2", "f3", "f4" }

\* @spec [IRET.12]
\* Base facts: externally asserted, retracted only by an external retract -- never by
\* the cascade. Their support lies outside the TMS.
iret_12__Base ==
    IF iret_12__GRAPH = "cycle" THEN { "P" } ELSE { "f1", "f4" }

\* @spec [IRET.12]
\* The justifications. Each record [ante |-> antecedent facts, target |-> derived fact]:
\* the target has this justifier active while ALL its antecedents are live. Ranked:
\* f2 <- {f1} and f2 <- {f4} (a multi-justifier, justif_count up to 2), f3 <- {f2}.
\* Cycle: Q <- {P}, R <- {Q}, Q <- {R}.
\* Written again as Rete/Refcount.idr's `iret_12_3__tla_js` (f1..f4 -> 1..4) and
\* `llog_2_5__witness_js` (P, Q, R -> 0, 1, 2), which its witnesses execute;
\* scripts/formal/check_instances.py (`instances.stamp`) holds the two copies one,
\* with `iret_12__Fact` and `iret_12__Base`, on every run of the lane.
iret_12__Justif ==
    IF iret_12__GRAPH = "cycle"
    THEN { [ ante |-> { "P" }, target |-> "Q" ],
           [ ante |-> { "Q" }, target |-> "R" ],
           [ ante |-> { "R" }, target |-> "Q" ] }
    ELSE { [ ante |-> { "f1" }, target |-> "f2" ],
           [ ante |-> { "f4" }, target |-> "f2" ],
           [ ante |-> { "f2" }, target |-> "f3" ] }

\* @spec [IRET.12]
\* Working-memory liveness: which facts are currently asserted.
VARIABLE iret_12__live

\* @spec [IRET.12]
\* The state tuple -- the variable a step may change.
iret_12__vars == iret_12__live

\* @spec [IRET.12]
\* A derived fact is SUPPORTED iff some justification targeting it has every antecedent
\* live -- i.e. it has at least one active justifier (justif_count > 0), without Int.
iret_12__supported(f) ==
    \E j \in iret_12__Justif : j.target = f /\ \A g \in j.ante : iret_12__live[g]

\* @spec [IRET.12]
\* Initially every fact is asserted -- a consistent state: every derived fact has a
\* live justifier.
iret_12__Init ==
    iret_12__live = [ f \in iret_12__Fact |-> TRUE ]

\* @spec [IRET.12]
\* An external retract of a base (input) fact -- arbitrary, so it carries no fairness.
iret_12__RetractBase(f) ==
    /\ f \in iret_12__Base
    /\ iret_12__live[f] = TRUE
    /\ iret_12__live' = [ iret_12__live EXCEPT ![f] = FALSE ]

\* @spec [IRET.12.2]
\* The cascade step: a derived fact whose justif_count has reached 0 (no active
\* justifier) is retracted. Retracting it withdraws it as an antecedent, which may
\* leave further derived facts unsupported -- so the retraction propagates.
iret_12_2__Cascade(f) ==
    /\ f \notin iret_12__Base
    /\ iret_12__live[f] = TRUE
    /\ ~iret_12__supported(f)
    /\ IF iret_12__ENGINE = "no_cascade"
         THEN UNCHANGED iret_12__vars
         ELSE iret_12__live' = [ iret_12__live EXCEPT ![f] = FALSE ]

\* @spec [IRET.12]
\* Quiescence: no derived fact is live-but-unsupported -- an explicit terminal stutter
\* so the settled fixpoint is a legitimate end state, not a TLC deadlock.
iret_12__Done ==
    /\ \A f \in iret_12__Fact :
         \/ iret_12__live[f] = FALSE
         \/ f \in iret_12__Base
         \/ iret_12__supported(f)
    /\ UNCHANGED iret_12__vars

\* @spec [IRET.12]
\* Next: an external base retract, a cascade step, or quiescent idle.
iret_12__Next ==
    \/ \E f \in iret_12__Fact : iret_12__RetractBase(f) \/ iret_12_2__Cascade(f)
    \/ iret_12__Done

\* @spec [IRET.12]
\* The behavior spec. WEAK FAIRNESS on the cascade per fact: the engine always runs the
\* retraction cascade to completion. Base retracts are external, hence unfair.
iret_12__Spec ==
    /\ iret_12__Init
    /\ [][iret_12__Next]_iret_12__vars
    /\ \A f \in iret_12__Fact : WF_iret_12__vars(iret_12_2__Cascade(f))

\* @spec [IRET.12]
\* Type-correctness -- a state invariant true at every reachable state.
iret_12__TypeOK ==
    /\ iret_12__live \in [ iret_12__Fact -> BOOLEAN ]
    /\ iret_12__ENGINE \in { "clause", "no_cascade" }
    /\ iret_12__GRAPH \in { "ranked", "cycle" }

\* @spec [IRET.12.3]
\* MULTI-JUSTIFIER SURVIVES (safety): a derived fact with at least one live justifier is
\* never retracted -- withdrawing one justifier of a two-justifier fact leaves it live
\* (justif_count 2 -> 1, not retracted). So a supported derived fact stays live across
\* every step. NO counterexample.
\*
\* TAGGED `spec`, NOT `derives`: a derived fact leaves `live` only through
\* `iret_12_2__Cascade(f)`, whose guard is `~supported(f)`, so this property
\* restates that guard. A transcription check, not a derivation;
\* `iret_12_2__no_unsupported_forever` is the derived property.
iret_12_3__multi_justifier_survives ==
    [][ \A f \in iret_12__Fact :
          (f \notin iret_12__Base /\ iret_12__live[f] /\ iret_12__supported(f))
            => iret_12__live'[f] ]_iret_12__vars

\* @derives [IRET.12.2]
\* CASCADE COMPLETES (liveness): every derived fact left without a live justifier is
\* eventually retracted -- the cascade runs to completion and never leaks an
\* unsupported fact. Holds only under weak fairness on the cascade (see TEETH). NO
\* counterexample.
iret_12_2__no_unsupported_forever ==
    \A f \in iret_12__Fact :
        [] ( (f \notin iret_12__Base /\ iret_12__live[f] /\ ~iret_12__supported(f))
               => <>(iret_12__live[f] = FALSE) )

\* THE OBLIGATION, beside the mechanism. Everything above is the COUNT:
\* `Cascade` retracts a derived fact whose every justification has lost an
\* antecedent, and what it leaves is the greatest self-supported set below the
\* live facts (Rete/Refcount.idr's `iret_12_2__cascade`). [IRET.12.2]'s first
\* sentence asks for something else -- retract exactly what [LLOG.2.5] leaves
\* unsupported, a fact surviving while it has a WELL-FOUNDED justification --
\* and the two definitions below state it as the least fixpoint of support from
\* the live base facts, Refcount.idr's `llog_2_5__well_founded`. On the ranked
\* graph the count is the obligation (tms_cascade.cfg checks it, over every
\* behaviour); on the cycle it is not, as the clause says, and the
\* `.teeth.cycle.` config requires the violation.

\* @spec [LLOG.2.5]
\* One derivation round over what is known: a live base fact, or a fact some
\* justification derives from known facts alone.
llog_2_5__Derive(known) ==
    { f \in iret_12__Fact :
        \/ (f \in iret_12__Base /\ iret_12__live[f])
        \/ (\E j \in iret_12__Justif : j.target = f /\ j.ante \subseteq known) }

\* @spec [LLOG.2.5]
\* The least fixpoint from nothing: what [LLOG.2.5], read well-foundedly, keeps
\* live. Four rounds: a productive round adds at least one of at most four
\* facts, so the fourth is the fixpoint on either graph, and
\* `llog_2_5__well_founded_is_fixed` holds the bound on every reachable state
\* rather than assuming it.
llog_2_5__WellFounded ==
    llog_2_5__Derive(llog_2_5__Derive(llog_2_5__Derive(llog_2_5__Derive({}))))

\* @derives [LLOG.2.5]
\* THE BOUND IS NOT ASSUMED: the unrolling has reached its fixpoint. A fifth
\* fact would fail this before it could make `WellFounded` wrong.
llog_2_5__well_founded_is_fixed ==
    llog_2_5__Derive(llog_2_5__WellFounded) = llog_2_5__WellFounded

\* @spec [IRET.12.2]
\* THE OBLIGATION as a state invariant: once the cascade has nothing left to do,
\* every live fact is well-founded. A live base fact is its own ground; only a
\* derived fact can fail it. On the ranked graph it HOLDS over every behaviour
\* (tms_cascade.cfg); on the cycle it is VIOLATED two states in -- Init, then
\* RetractBase("P"): Q and R live, each the other's justification, nothing to
\* cascade, and the well-founded set empty (tms_cascade.teeth.cycle.cfg).
iret_12_2__quiescent_is_well_founded ==
    (\A f \in iret_12__Fact :
        \/ iret_12__live[f] = FALSE
        \/ f \in iret_12__Base
        \/ iret_12__supported(f))
      => (\A f \in iret_12__Fact : iret_12__live[f] => f \in llog_2_5__WellFounded)

\* PROBES. `multi_justifier_survives` is named for a fact
\* that LOSES a justifier and lives, and holds of a model in which none loses
\* one. `no_unsupported_forever` is of the form "whenever a derived fact is
\* left without support, ...", and the header's claim is that the retraction
\* PROPAGATES. Each definition below says one of these never happens; its
\* `.probe.` config runs THIS engine, with the constant of tms_cascade.cfg, and
\* scripts/formal/check_tla.py requires TLC to end in a violation.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no fact is live and supported with one of its
\* justifications broken. The run that breaks it retracts one of the two base
\* facts that justify the multi-justifier, which stays live on the other.
probe__no_fact_outlives_a_justifier ==
    ~( \E j \in iret_12__Justif :
         /\ \E g \in j.ante : ~iret_12__live[g]
         /\ iret_12__live[j.target]
         /\ iret_12__supported(j.target) )

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: the fact at the end of the chain is never
\* retracted. It is derived, so only the cascade retracts it, and only after
\* the fact it rests on: the run that breaks it retracts both base facts, and
\* the cascade takes the multi-justifier and then the fact chained off it.
probe__the_cascade_stops_at_one ==
    iret_12__live["f3"]

=============================================================================

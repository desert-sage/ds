----------------------------- MODULE pump_atomicity -----------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS pump -- the fine-grained pump REFINES one atomic step, under the     *)
(* observable interface [RARC.13.16] bounds (TLA+ / TLC). The clause says  *)
(* the engine core is a pure function of its inputs through four           *)
(* observables -- the return value, the effect list, the event stream the  *)
(* callbacks receive, and any ds_engine_* read -- and names the lemma that *)
(* carries it: the pump's cycle, which mutates heavily and hands control   *)
(* to the integrator's callback after every event, refines a single step.  *)
(* formal/tla/pump_single_writer.tla proves two writers never overlap and  *)
(* that a pump returns drained; formal/tla/determinism.tla proves two      *)
(* copies fire in lockstep. Neither has an OBSERVER. This model does:      *)
(* between any two steps of the pump the integrator's callback may try a   *)
(* read and may try an assert on the engine that called it, and the        *)
(* question is whether what the caller holds when the pump returns is what *)
(* the atomic step gives.                                                  *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the `\* @spec [ID]` / `\* @derives [ID]` line above   *)
(* it repeats the clause so the checker confirms the id exists AND matches. *)
(*                                                                         *)
(* THE MODEL. One rule, written once: a fact f matches and its firing      *)
(* emits f + STEP; an emitted fact at most MAXF is a fact the rule matches, *)
(* one above it is not. Working memory is a set of facts, the agenda the   *)
(* facts whose activation has not fired, the next to fire the least        *)
(* ([LDET.5.1]'s order stands in by a strict total order on naturals; that *)
(* it IS total is firing_order.als's and determinism.tla's, not this        *)
(* model's). THE ATOMIC STEP is `rarc_13_16__Drain`: the firing iterated to *)
(* an empty agenda, a function of working memory and the agenda alone,     *)
(* returning the working memory it leaves and the events it delivers, in   *)
(* order. THE FINE-GRAINED PUMP fires through the same one-firing function *)
(* in three steps -- select and deliver rule_fire_begin, apply the emit and *)
(* deliver its event, deliver rule_fire_end ([RARC.5.8.11]) -- and after    *)
(* every delivery the callback may run: it may try one read and one assert *)
(* per pump, at any of those points. The clause's engine refuses both with *)
(* DS_ERR_STATE, and the refusal is not an observation of state: it is a   *)
(* constant that depends on nothing the engine holds, which is what the    *)
(* clause's "a torn snapshot is worse than a refusal" turns on. The         *)
(* integrator's own asserts run between pumps ([NLFC.3.3], assumed here as *)
(* the clause says it is assumed).                                         *)
(*                                                                         *)
(* THE GUARANTEE (`rarc_13_16__pump_refines_step`). At every return of a    *)
(* pump, in every interleaving of its steps with the callback's attempts:  *)
(* the events the caller received since the pump began are exactly the    *)
(* atomic step's, in its order, and working memory is the atomic step's.   *)
(* With the mid-pump reads refused that is the whole of what the four      *)
(* observables can show of a pump: the return value is DS_OK throughout    *)
(* (no fault in this fragment), a read between pumps sees the working      *)
(* memory the property fixes, and the effect list and the event stream are *)
(* one channel here. Checked as an action property on the return step.     *)
(*                                                                         *)
(* TEETH, run on every run of the lane (the `.teeth.` configs): the        *)
(* engines the clause rules out, each breaking the refinement.             *)
(*   "torn_reads"        serves a mid-pump read:                            *)
(*                       the observation log carries a working              *)
(*                       memory no atomic state has                         *)
(*   "reentrant_assert"  accepts a callback's assert into the engine that   *)
(*                       called it: the pump returns a working memory the   *)
(*                       atomic step, over the inputs the integrator        *)
(*                       queued, never reaches                              *)
(*   "late_delivery"     delivers an action's event after the firing's      *)
(*                       rule_fire_end instead of at its site               *)
(*                       ([RARC.5.8.11]): the same events, another order    *)
(*                                                                         *)
(* SCOPE, for the verdict. No fault, cap, clock, TTL, retraction, `no`     *)
(* pattern or truth maintenance: a pump that returns anything but DS_OK is *)
(* outside this fragment, and so is [RARC.5.8.9]'s "before an in-language  *)
(* fact it produces is asserted", which no channel here can observe while  *)
(* reads are refused. One read and one assert attempt per pump, anywhere   *)
(* in it: the integrator's behaviour, bounded for the state space. The     *)
(* [RARC.13.16] tie is `partial` and says so. The single-writer premise is *)
(* pump_single_writer.tla's and is assumed here: `nlfc_3_3__InputAssert`   *)
(* runs between pumps by its guard.                                        *)
(***************************************************************************)
EXTENDS Naturals, Sequences

\* @spec [RARC.13.16]
\* Which engine this run is of. "clause" is the clause's, and pump_atomicity.cfg
\* runs it. The others are engines the clause rules out, each modelled so that
\* the refinement can be SEEN to fail: each `.teeth.` config beside this module
\* is a run scripts/formal/check_tla.py requires to end in a violation.
\*   "torn_reads"        a callback's read of the engine that called it is served
\*   "reentrant_assert"  a callback's assert into the engine that called it is
\*                       accepted
\*   "late_delivery"     an action's event is delivered after the firing's end
\*                       event, not at its site
CONSTANT rarc_13_16__ENGINE

\* @spec [RARC.5.6.4]
\* The facts the integrator may assert: 1..MAXF. An emitted fact may lie above.
CONSTANT rarc_5_6_4__MAXF

\* @spec [RARC.5.6.6]
\* The one rule: a fact f matches, and its firing emits f + STEP.
CONSTANT rarc_5_6_6__STEP

\* @spec [RARC.5.6.4]
\* Working memory: the set of live facts.
VARIABLE rarc_5_6_4__wm

\* @spec [RARC.5.6.6]
\* The agenda: the facts whose activation has not fired.
VARIABLE rarc_5_6_6__agenda

\* @spec [RARC.13.16]
\* Whether a pump is in progress (ds_engine_pump has not returned).
VARIABLE rarc_13_16__pumping

\* @spec [RARC.5.6.6]
\* Where in a firing the pump is: "idle" between firings, "begun" once the
\* activation is selected and rule_fire_begin delivered, "applied" once its emit
\* is in working memory and the action's event delivered.
VARIABLE rarc_5_6_6__phase

\* @spec [RARC.5.6.6]
\* The activation being fired; 0 between firings.
VARIABLE rarc_5_6_6__cur

\* @spec [RARC.13.16]
\* What the caller has observed since the pump began: the events delivered to
\* its stream callback, in delivery order, and the result of any read the engine
\* served. Reset when a pump begins; kept after it returns, for the property.
VARIABLE rarc_13_16__observed

\* @spec [RARC.13.16]
\* Ghost: the atomic step's result, fixed when the pump began -- the working
\* memory it leaves and the events it delivers.
VARIABLE rarc_13_16__expected

\* @spec [RARC.13.16]
\* Ghost: which of the callback's attempts, "read" and "assert", have been made
\* in this pump. One of each per pump: the integrator's behaviour, bounded.
VARIABLE rarc_13_16__tried

\* @spec [RARC.13.16]
\* Ghost: which attempts the engine has refused, ever. What the probes read.
VARIABLE rarc_13_16__refused

\* @spec [RARC.13.16]
\* The state tuple -- the variables a step may change.
rarc_13_16__vars ==
    << rarc_5_6_4__wm, rarc_5_6_6__agenda, rarc_13_16__pumping, rarc_5_6_6__phase,
       rarc_5_6_6__cur, rarc_13_16__observed, rarc_13_16__expected,
       rarc_13_16__tried, rarc_13_16__refused >>

\* @spec [RARC.5.8.11]
\* An event as the stream callback receives it: its kind and what it names.
\* `pump` at a pump's entry, `begin` and `end` around each firing, `emit` for the
\* action. The clause's engine delivers each inline at the site that generates
\* it; the "late_delivery" engine does not.
rarc_5_8_11__ev(k, v) == [k |-> k, v |-> v]

\* @spec [RARC.5.6.6]
\* The next to fire: the least pending activation. A strict total order, as
\* [LDET.5.1]'s key is; which order is not this model's question.
rarc_5_6_6__Min(S) == CHOOSE m \in S : \A x \in S : m <= x

\* @spec [RARC.5.6.6]
\* What firing activation a emits.
rarc_5_6_6__emitted(a) == a + rarc_5_6_6__STEP

\* @spec [RARC.5.6.6]
\* The activation a fact entering working memory `wm` creates: the fact itself
\* when the rule matches it and it is new; none for a fact already live (a no-op
\* reassert) or for one no rule matches.
rarc_5_6_6__activates(wm, f) ==
    IF f <= rarc_5_6_4__MAXF /\ f \notin wm THEN { f } ELSE {}

\* @spec [RARC.5.6.6]
\* ONE FIRING, whole: the working memory and agenda after it and the three
\* events it delivers, in order. Written once: the atomic step iterates it and
\* the fine-grained pump takes it in three steps.
rarc_5_6_6__fire(wm, ag) ==
    LET a == rarc_5_6_6__Min(ag)
        e == rarc_5_6_6__emitted(a)
    IN [ wm  |-> wm \cup { e },
         ag  |-> (ag \ { a }) \cup rarc_5_6_6__activates(wm, e),
         evs |-> << rarc_5_8_11__ev("begin", a), rarc_5_8_11__ev("emit", e),
                    rarc_5_8_11__ev("end", a) >> ]

RECURSIVE rarc_13_16__Drain(_, _, _)
\* @spec [RARC.13.16]
\* THE ATOMIC STEP: the engine core as a pure function of its inputs. From a
\* working memory and an agenda, fire the least activation until the agenda is
\* empty; the result is the working memory left and the events delivered, after
\* those already in `evs`. Terminates: each firing removes its activation and
\* creates at most one, for a fact not yet live, of which there are MAXF.
rarc_13_16__Drain(wm, ag, evs) ==
    IF ag = {} THEN [ wm |-> wm, evs |-> evs ]
    ELSE LET f == rarc_5_6_6__fire(wm, ag)
         IN rarc_13_16__Drain(f.wm, f.ag, evs \o f.evs)

\* @spec [RARC.13.16]
\* Both machines start empty: nothing live, nothing pending, no pump, nothing
\* observed, no attempt made or refused.
rarc_13_16__Init ==
    /\ rarc_5_6_4__wm = {}
    /\ rarc_5_6_6__agenda = {}
    /\ rarc_13_16__pumping = FALSE
    /\ rarc_5_6_6__phase = "idle"
    /\ rarc_5_6_6__cur = 0
    /\ rarc_13_16__observed = << >>
    /\ rarc_13_16__expected = [ wm |-> {}, evs |-> << >> ]
    /\ rarc_13_16__tried = {}
    /\ rarc_13_16__refused = {}

\* @spec [NLFC.3.3]
\* The integrator asserts fact f, between pumps: the input enters working memory
\* and creates its activation ([RARC.5.6.4], [RARC.5.6.5]). The guard is the
\* single-writer exclusion the clause makes the integrator's duty; this model
\* assumes it, as the clause says the engine does. pump_single_writer.tla is
\* where the exclusion itself is checked.
nlfc_3_3__InputAssert(f) ==
    /\ rarc_13_16__pumping = FALSE
    /\ f \notin rarc_5_6_4__wm
    /\ rarc_5_6_4__wm' = rarc_5_6_4__wm \cup { f }
    /\ rarc_5_6_6__agenda' =
         rarc_5_6_6__agenda \cup rarc_5_6_6__activates(rarc_5_6_4__wm, f)
    /\ UNCHANGED << rarc_13_16__pumping, rarc_5_6_6__phase, rarc_5_6_6__cur,
                    rarc_13_16__observed, rarc_13_16__expected,
                    rarc_13_16__tried, rarc_13_16__refused >>

\* @spec [RARC.13.16]
\* ds_engine_pump is called. The atomic step's result is fixed here, from the
\* working memory and agenda the integrator's inputs left; the `pump` event is
\* delivered at the entry ([RARC.5.8.11]); the callback's attempts for this
\* pump are open.
rarc_13_16__PumpBegin ==
    /\ rarc_13_16__pumping = FALSE
    /\ rarc_13_16__pumping' = TRUE
    /\ rarc_13_16__observed' = << rarc_5_8_11__ev("pump", 0) >>
    /\ rarc_13_16__expected' =
         rarc_13_16__Drain(rarc_5_6_4__wm, rarc_5_6_6__agenda,
                           << rarc_5_8_11__ev("pump", 0) >>)
    /\ rarc_13_16__tried' = {}
    /\ UNCHANGED << rarc_5_6_4__wm, rarc_5_6_6__agenda, rarc_5_6_6__phase,
                    rarc_5_6_6__cur, rarc_13_16__refused >>

\* @spec [RARC.5.6.6]
\* The conflict resolver takes the least pending activation and the firing
\* begins: rule_fire_begin reaches the stream callback, on the pump's stack.
rarc_5_6_6__Select ==
    /\ rarc_13_16__pumping = TRUE
    /\ rarc_5_6_6__phase = "idle"
    /\ rarc_5_6_6__agenda # {}
    /\ LET a == rarc_5_6_6__Min(rarc_5_6_6__agenda)
       IN /\ rarc_5_6_6__cur' = a
          /\ rarc_5_6_6__agenda' = rarc_5_6_6__agenda \ { a }
          /\ rarc_13_16__observed' =
               Append(rarc_13_16__observed, rarc_5_8_11__ev("begin", a))
    /\ rarc_5_6_6__phase' = "begun"
    /\ UNCHANGED << rarc_5_6_4__wm, rarc_13_16__pumping, rarc_13_16__expected,
                    rarc_13_16__tried, rarc_13_16__refused >>

\* @spec [RARC.5.6.6]
\* The firing's action: the emit enters working memory and is propagated, its
\* activation on the agenda; the action's event is delivered as the action
\* happens ([RARC.5.8.12]) -- except by the "late_delivery" engine, which holds
\* it for the firing's end.
rarc_5_6_6__Apply ==
    /\ rarc_13_16__pumping = TRUE
    /\ rarc_5_6_6__phase = "begun"
    /\ LET e == rarc_5_6_6__emitted(rarc_5_6_6__cur)
       IN /\ rarc_5_6_4__wm' = rarc_5_6_4__wm \cup { e }
          /\ rarc_5_6_6__agenda' =
               rarc_5_6_6__agenda \cup rarc_5_6_6__activates(rarc_5_6_4__wm, e)
          /\ rarc_13_16__observed' =
               IF rarc_13_16__ENGINE = "late_delivery"
               THEN rarc_13_16__observed
               ELSE Append(rarc_13_16__observed, rarc_5_8_11__ev("emit", e))
    /\ rarc_5_6_6__phase' = "applied"
    /\ UNCHANGED << rarc_13_16__pumping, rarc_5_6_6__cur, rarc_13_16__expected,
                    rarc_13_16__tried, rarc_13_16__refused >>

\* @spec [RARC.5.6.6]
\* The firing ends: rule_fire_end is delivered -- and, in the "late_delivery"
\* engine, the action's event after it.
rarc_5_6_6__End ==
    /\ rarc_13_16__pumping = TRUE
    /\ rarc_5_6_6__phase = "applied"
    /\ rarc_13_16__observed' =
         IF rarc_13_16__ENGINE = "late_delivery"
         THEN rarc_13_16__observed
                \o << rarc_5_8_11__ev("end", rarc_5_6_6__cur),
                      rarc_5_8_11__ev("emit", rarc_5_6_6__emitted(rarc_5_6_6__cur)) >>
         ELSE Append(rarc_13_16__observed, rarc_5_8_11__ev("end", rarc_5_6_6__cur))
    /\ rarc_5_6_6__phase' = "idle"
    /\ rarc_5_6_6__cur' = 0
    /\ UNCHANGED << rarc_5_6_4__wm, rarc_5_6_6__agenda, rarc_13_16__pumping,
                    rarc_13_16__expected, rarc_13_16__tried, rarc_13_16__refused >>

\* @spec [RARC.13.16]
\* Inside a callback -- at any point of the pump, since every step above has
\* delivered an event -- the integrator calls a read on the engine that called
\* it. The clause's engine returns DS_ERR_STATE: nothing enters the observation
\* log, because a constant refusal is a function of no engine state. The
\* "torn_reads" engine serves it, and the log carries a working memory of the
\* pump in progress.
rarc_13_16__ReentrantRead ==
    /\ rarc_13_16__pumping = TRUE
    /\ "read" \notin rarc_13_16__tried
    /\ rarc_13_16__tried' = rarc_13_16__tried \cup { "read" }
    /\ IF rarc_13_16__ENGINE = "torn_reads"
       THEN /\ rarc_13_16__observed' =
                 Append(rarc_13_16__observed, rarc_5_8_11__ev("read", rarc_5_6_4__wm))
            /\ UNCHANGED rarc_13_16__refused
       ELSE /\ rarc_13_16__refused' = rarc_13_16__refused \cup { "read" }
            /\ UNCHANGED rarc_13_16__observed
    /\ UNCHANGED << rarc_5_6_4__wm, rarc_5_6_6__agenda, rarc_13_16__pumping,
                    rarc_5_6_6__phase, rarc_5_6_6__cur, rarc_13_16__expected >>

\* @spec [RARC.13.16]
\* Inside a callback the integrator asserts fact f into the engine that called
\* it. The clause's engine refuses it with DS_ERR_STATE and nothing changes. The
\* "reentrant_assert" engine accepts it: a new fact enters working memory with
\* its activation and its event is delivered, and the pump goes on to fire it; a
\* fact already live is a no-op reassert.
rarc_13_16__ReentrantAssert(f) ==
    /\ rarc_13_16__pumping = TRUE
    /\ "assert" \notin rarc_13_16__tried
    /\ rarc_13_16__tried' = rarc_13_16__tried \cup { "assert" }
    /\ IF rarc_13_16__ENGINE # "reentrant_assert"
       THEN /\ rarc_13_16__refused' = rarc_13_16__refused \cup { "assert" }
            /\ UNCHANGED << rarc_5_6_4__wm, rarc_5_6_6__agenda, rarc_13_16__observed >>
       ELSE IF f \in rarc_5_6_4__wm
            THEN UNCHANGED << rarc_5_6_4__wm, rarc_5_6_6__agenda,
                              rarc_13_16__observed, rarc_13_16__refused >>
            ELSE /\ rarc_5_6_4__wm' = rarc_5_6_4__wm \cup { f }
                 /\ rarc_5_6_6__agenda' =
                      rarc_5_6_6__agenda \cup rarc_5_6_6__activates(rarc_5_6_4__wm, f)
                 /\ rarc_13_16__observed' =
                      Append(rarc_13_16__observed, rarc_5_8_11__ev("assert", f))
                 /\ UNCHANGED rarc_13_16__refused
    /\ UNCHANGED << rarc_13_16__pumping, rarc_5_6_6__phase, rarc_5_6_6__cur,
                    rarc_13_16__expected >>

\* @spec [RARC.13.16]
\* The pump returns DS_OK: the agenda is drained ([NLFC.2.2]) and no firing is
\* open. What the caller observed stays, for the property to read on this step.
rarc_13_16__PumpReturn ==
    /\ rarc_13_16__pumping = TRUE
    /\ rarc_5_6_6__phase = "idle"
    /\ rarc_5_6_6__agenda = {}
    /\ rarc_13_16__pumping' = FALSE
    /\ UNCHANGED << rarc_5_6_4__wm, rarc_5_6_6__agenda, rarc_5_6_6__phase,
                    rarc_5_6_6__cur, rarc_13_16__observed, rarc_13_16__expected,
                    rarc_13_16__tried, rarc_13_16__refused >>

\* @spec [RARC.13.16]
\* Next: an input between pumps; a pump's entry, its firing steps and its
\* return; the callback's two attempts. A pump can always begin, so no state is
\* a deadlock.
rarc_13_16__Next ==
    \/ \E f \in 1..rarc_5_6_4__MAXF : nlfc_3_3__InputAssert(f)
    \/ rarc_13_16__PumpBegin
    \/ rarc_5_6_6__Select
    \/ rarc_5_6_6__Apply
    \/ rarc_5_6_6__End
    \/ rarc_13_16__PumpReturn
    \/ rarc_13_16__ReentrantRead
    \/ \E f \in 1..rarc_5_6_4__MAXF : rarc_13_16__ReentrantAssert(f)

\* @spec [RARC.13.16]
\* The behaviour spec. No fairness: the guarantee is safety, over every
\* interleaving; that a pump returns is pump_single_writer.tla's liveness.
rarc_13_16__Spec ==
    /\ rarc_13_16__Init
    /\ [][rarc_13_16__Next]_rarc_13_16__vars

\* @spec [RARC.13.16]
\* Type-correctness, with the shape invariants the model keeps: every pending
\* activation is a live fact the rule matches; a firing is open exactly when
\* `cur` names one.
rarc_13_16__TypeOK ==
    /\ rarc_5_6_4__wm \subseteq 1..(rarc_5_6_4__MAXF + rarc_5_6_6__STEP)
    /\ rarc_5_6_6__agenda \subseteq rarc_5_6_4__wm
    /\ rarc_5_6_6__agenda \subseteq 1..rarc_5_6_4__MAXF
    /\ rarc_13_16__pumping \in BOOLEAN
    /\ rarc_5_6_6__phase \in { "idle", "begun", "applied" }
    /\ rarc_5_6_6__cur \in 0..rarc_5_6_4__MAXF
    /\ (rarc_5_6_6__phase = "idle") <=> (rarc_5_6_6__cur = 0)
    /\ \A i \in 1..Len(rarc_13_16__observed) :
         rarc_13_16__observed[i].k \in { "pump", "begin", "emit", "end", "read", "assert" }
    /\ rarc_13_16__expected.wm \subseteq 1..(rarc_5_6_4__MAXF + rarc_5_6_6__STEP)
    /\ rarc_13_16__tried \subseteq { "read", "assert" }
    /\ rarc_13_16__refused \subseteq { "read", "assert" }
    /\ rarc_13_16__ENGINE \in { "clause", "torn_reads", "reentrant_assert", "late_delivery" }

\* @derives [RARC.13.16]
\* THE REFINEMENT (safety, an action property on the return step): whenever a
\* pump returns, what the caller observed since it began is the atomic step's
\* event sequence, and working memory is the atomic step's. In the clause's
\* engine this holds in every interleaving of the pump's steps with the
\* callback's read and assert attempts; the three engines of TEETH break it. NO
\* counterexample.
rarc_13_16__pump_refines_step ==
    [][ (rarc_13_16__pumping = TRUE /\ rarc_13_16__pumping' = FALSE)
          => /\ rarc_13_16__observed = rarc_13_16__expected.evs
             /\ rarc_5_6_4__wm = rarc_13_16__expected.wm ]_rarc_13_16__vars

\* PROBES. `pump_refines_step` is of the form "whenever a pump returns ...",
\* and holds of a model in which no callback ever tries anything, and of one
\* whose every pump fires once, where the order of delivery cannot go wrong.
\* Each definition below says one of these never happens; its `.probe.` config
\* runs THE CLAUSE'S ENGINE with pump_atomicity.cfg's constants, and
\* scripts/formal/check_tla.py requires TLC to end in a violation.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no callback ever tries a read on the engine
\* that called it. The run that breaks it is a pump whose callback reads and is
\* refused -- the refusal the clause states, reached.
probe__no_read_attempted == "read" \notin rarc_13_16__refused

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no callback ever tries an assert into the
\* engine that called it. The run that breaks it is that assert, refused.
probe__no_assert_attempted == "assert" \notin rarc_13_16__refused

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: a pump never fires more than once (the `pump`
\* event and one firing's three). The run that breaks it is a cascade, or two
\* inputs before one pump: a sequence of events whose order could go wrong.
probe__one_firing_per_pump == Len(rarc_13_16__observed) <= 4

=============================================================================

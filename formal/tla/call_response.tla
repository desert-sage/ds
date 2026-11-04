--------------------------------- MODULE call_response ---------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS async call/response -- the answer's lifetime, as a LIVENESS spec     *)
(* (TLA+ / TLC), with the schema TTL that gives the liveness its content,  *)
(* the two supersedures that are the only other way an answer goes, and    *)
(* the cooldown gate that stands before the sweep as before the request.   *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the `\* @spec [ID]` / `\* @derives [ID]` line above   *)
(* it repeats the clause so the checker confirms the id exists AND matches. *)
(*                                                                         *)
(* THE GUARANTEE. A call is strictly async ([LCRS.2.1]): the RHS returns   *)
(* and the answer arrives LATER, as exactly one response fact XOR          *)
(* `CallError` per request ([LCRS.4.2.2]) that lives in working memory     *)
(* ([LCRS.6.1]). Three things retract it, and no fourth exists: the call   *)
(* firing again with the same correlation retracts it and issues the new   *)
(* request ([LCRS.6.2.1]); an answer with the same correlation ARRIVING    *)
(* retracts it before itself going live ([LCRS.6.2.4]); otherwise it       *)
(* expires at its schema's TTL ([LCRS.6.6.1]) -- the duration the response *)
(* schema declares, 5_min for `CallError` ([LCRS.4.2.1]) -- which the      *)
(* engine applies at the pump that follows the clock reaching the deadline *)
(* ([RARC.5.2.4]), and no site setting shortens or extends. Every call     *)
(* carries a correlation ([LCRS.3.1]): the author's `as`, or, for a call   *)
(* with no `as` or whose `as` evaluates to "", a value the engine          *)
(* generates for the firing ([LCCO.3.4], [LRST.1.2]). So every issued call *)
(* sweeps ([LCRS.6.2.1]); a generated correlation is unique to its firing, *)
(* so a sweep under it finds nothing and the call supersedes nothing       *)
(* ([LRST.1.2]): its answers accumulate, one per firing, until each        *)
(* expires. A call its cooldown suppresses is not issued and retracts      *)
(* nothing ([LCRS.6.2.1], [LCRS.8.2]): the sweep stands inside the gate,   *)
(* where RLOW.7.3.8 puts it. TLC proves: a live answer carries exactly one *)
(* kind; at most one answer per correlation is live; an issued call leaves *)
(* no answer of its correlation live; a call with a generated correlation  *)
(* retracts nothing; a suppressed call issues nothing and retracts         *)
(* nothing; the sweep retracts nothing before its TTL; nothing is live at  *)
(* or past its TTL; and no answer stays live forever.                      *)
(*                                                                         *)
(* THE CASE [LCRS.6.2.4] CLOSES. A call that fires again before its first  *)
(* request is answered finds nothing live to retract, and BOTH replies     *)
(* then arrive. Until this revision the model did not let a call fire      *)
(* while a request was outstanding (its header said so), so the case was   *)
(* outside it. Now a call may fire while answers are owed, each request is *)
(* answered at most once and in any order, and the arriving answer         *)
(* supersedes: the one asserted last is the one live. Replies out of order *)
(* leave the EARLIER request's answer live, which the clause says outright *)
(* and the `out_of_order` probe shows happen.                              *)
(*                                                                         *)
(* HOW THE ENVIRONMENT IS MODELLED. The engine keeps no pending-call state *)
(* ([NCBK.6.3]); the ADAPTER does, and the model carries it for the        *)
(* adapter: `owed` is the set of requests issued and not yet answered, and *)
(* an answer is the reply to one of them (an `id`, the number of the       *)
(* firing it answers). The engine reads none of that -- its actions look   *)
(* at `corr` alone -- and the id is in the state only so a property can    *)
(* say "THIS answer is eventually gone". Each call fires at most `FIRES`   *)
(* times in a run, so the ids are bounded; `FIRES = 2` is the clause's     *)
(* case, one firing and one more while the first is unanswered. Success of *)
(* a `no response` service is silence ([LCRS.17.1]), which is no step; its *)
(* request stays owed, because a `CallError` may still arrive for it.      *)
(*                                                                         *)
(* HOW A CORRELATION IS MODELLED. A call here is one correlation space: a  *)
(* value an author writes, which every firing of the call shares, or the   *)
(* engine's generated value, one per firing. The engine reads a            *)
(* correlation only to compare it ([LCRS.6.2.1], [LCRS.6.2.4]), so the     *)
(* model keeps of each what the comparison needs: an author's `as` is one  *)
(* name for the whole call, and a generated correlation is the number of   *)
(* the request it is minted for, unique to it ([LCCO.3.4]). An answer      *)
(* carries its request's correlation; a firing carries the request's it    *)
(* issues. The same sweep, "retract every live answer whose corr is the    *)
(* firing's", then empties an author-correlated call and finds nothing     *)
(* under a generated one, which is what RLOW.7.3.8 says of it.             *)
(*                                                                         *)
(* HOW TIME IS MODELLED. One tick is one clock sample and the pump that    *)
(* follows it: every live answer ages by one, and the pump's entry sweep   *)
(* retracts each whose age has reached its TTL, in the same step           *)
(* ([RARC.5.2.4]: expired at or before the clock, retracted at the pump's  *)
(* entry; the composed tick of formal/idris/Rete/NetworkClocked.idr has    *)
(* the same order). The age counts ticks since the answer went live, so    *)
(* `age >= TTL` is `clock >= deadline`. Durations are in ticks: the        *)
(* response schema's TTL and `CallError`'s 5_min are two constants, and    *)
(* nothing orders them: a response schema declares its own TTL             *)
(* ([LCRS.4.3.2]) and may put it below or above 5_min, so an engine        *)
(* applying one TTL to both kinds sweeps a `CallError` early in one        *)
(* ordering and keeps it past 5_min in the other. call_response.cfg        *)
(* sets `CallError`'s the longer, and call_response.scope.long.cfg runs    *)
(* the clause's engine with the response schema's the longer, the same     *)
(* checks under the other ordering; the `one_ttl` and `one_ttl_long`       *)
(* teeth configs run the ruled-out engine under each, so it is told from   *)
(* the clause's under both.                                                *)
(*                                                                         *)
(* HOW THE GATE IS MODELLED. Every call states `cooldown:` or `nocooldown` *)
(* ([LCRS.8.1]); `COOLED` is the calls that carry a cooldown, and the      *)
(* configs make it the one with an author's `as`, so the gate is met where *)
(* the sweep has something to leave. A cooled call's gate is one count,    *)
(* `since`: the ticks since its last admitted firing, saturating at the    *)
(* window ([LCRS.8.2]), and at the window from the start, because a call   *)
(* that has never fired is admitted. The gate's own semantics -- the       *)
(* activation key, the stamp, the clock it reads -- are formal/k/rgate.k's *)
(* and formal/idris/Rete/RateGate.idr's, not this model's. The rule firing *)
(* with the call in its RHS is an `Attempt`: the gate admits it (`Fire`:   *)
(* the sweep, then the request, one step) or suppresses it (`Deny`: the    *)
(* call is not issued and retracts nothing, and only the count of          *)
(* denials moves, so that a denial is a step TLC can show). The sweep is   *)
(* inside the gate because the engine performs it while evaluating the     *)
(* call (RLOW.7.3.8): a firing the gate denies reaches neither the sweep   *)
(* nor the request. The window elapses by the ticks that age the answers:  *)
(* one tick is one pump, and the gate reads the pump's monotonic sample    *)
(* where the TTL reads its clock, two readings of the one tick here.       *)
(*                                                                         *)
(* NOT MODELLED. More than one service: with one, a response fact's        *)
(* supersede and a `CallError`'s reach the same answers, so the service    *)
(* scoping of [LCRS.6.2.1] and [LCRS.6.2.4] (a response leaves other       *)
(* services' responses alone; a `CallError` spans services) is outside the *)
(* model and marked as a gap below; the vectors                            *)
(* `other_service_untouched` and `error_spans_services` pin it. The gate's *)
(* activation key ([LCRS.8.2]): one call site, one key, so the per-key     *)
(* independence of RLOW.4.6.2.3 is formal/k/rgate.k's. A call refused      *)
(* before it is issued (a NaN argument, RLOW.7.3.1), which retracts        *)
(* nothing as a denied one does and is no step here. The minting of a      *)
(* generated correlation ([LCCO.3.4]'s form and counter) and the string    *)
(* itself: the model keeps what the sweeps read of it, that no two         *)
(* firings share one, and that it is never null or empty ([LCRS.3.1]) is   *)
(* the clauses' and not drawn. The pump's work between the sweep and the   *)
(* next sample; the stream order of the retractions ([RFCS.6.7]).          *)
(*                                                                         *)
(* MODEL <-> MODEL. formal/idris/Rete/NetworkCall.idr                      *)
(* states the same clauses on the engine the Idris model runs: the call's  *)
(* sweep inside the per-call gate (`lcrs_8_2__call_site`), the arrival's   *)
(* sweep before the answer enters (`lcrs_6_2_4__arrive_timed`), the TTL    *)
(* sweep at the pump. Its `lcrs_6_2_4__one_answer_per_corr_after_history`  *)
(* is the UNBOUNDED TWIN of `lcrs_6_2_4__one_answer_per_corr` here: over   *)
(* any number of services, any kind table, any site table and any history  *)
(* of ticks, inputs and pumps, two distinct live answers carrying one      *)
(* non-empty correlation are of different response schemas and neither     *)
(* is `CallError`: the per-schema reading across services that this        *)
(* module's one service cannot draw, and the three teeth engines           *)
(* keepboth, errkeeps and respkeeps are the shapes                         *)
(* `lcrs_6_2_4__survivor_kinds` excludes. Its                              *)
(* `lcrs_6_2_1__suppressed_retracts_nothing` and `lcrs_8_2__site_refused`  *)
(* are this module's `suppressed_retracts_nothing` and                     *)
(* `suppressed_not_issued` on the engine. Where the two part: the Idris    *)
(* model carries no adapter (`owed` is this module's), no generated        *)
(* correlation (C1b), and the empty text sweeping nothing where this       *)
(* module keeps a correlation never empty ([LCRS.3.1]); both take as a     *)
(* hypothesis that no rule mints an answer (here no rule emits at all).    *)
(* No tie moves for this paragraph.                                        *)
(*                                                                         *)
(* TEETH. Drop `WF_..(rarc_5_2_4__Tick)` and `no_orphan_forever` fails: a  *)
(* live answer stutters below its TTL forever. The engines the clauses     *)
(* rule out are selected by `lcrs_6_1__ENGINE`, and each is run by a       *)
(* `.teeth.` config that scripts/formal/check_tla.py requires to end in     *)
(* a violation:                                                            *)
(* "early" retracts before the TTL and fails `not_before_its_ttl`; "late"  *)
(* keeps an answer live one tick past it and fails `never_past_its_ttl`;   *)
(* "one_ttl" sweeps a `CallError` at the response schema's TTL: below      *)
(* 5_min it fails `not_before_its_ttl`, and with that TTL the longer       *)
(* ("one_ttl_long") it keeps the `CallError` past 5_min and fails          *)
(* `never_past_its_ttl`; "unswept" never sweeps and "stalled" never        *)
(* ticks, and each fails `no_orphan_forever`; "kindless" answers with no   *)
(* kind and fails `one_kind_when_live`; "keepboth" asserts an arriving     *)
(* answer beside the live one, "errkeeps" has a `CallError` retract only   *)
(* `CallError`s and "respkeeps" has a response retract only its own        *)
(* schema's facts, and each fails `one_answer_per_corr` -- the three       *)
(* engines [LCRS.6.2.4]'s two bullets rule out; "nosweep" issues a call    *)
(* and retracts nothing, the behaviour [LCRS.6.2.1] admits for no call,    *)
(* and fails `issued_call_sweeps`; "sitecorr" gives a call with no `as`    *)
(* one correlation per call site, which [LCCO.3.4] rules out, so its       *)
(* firings supersede each other, and fails `generated_supersedes_nothing`; *)
(* "ungated" has the sweep ahead of the gate, so a denied firing retracts  *)
(* the live answer and issues nothing, and fails                           *)
(* `suppressed_retracts_nothing`; "nogate" admits every firing, so one     *)
(* inside the window issues and sweeps, and fails `suppressed_not_issued`  *)
(* (and `suppressed_retracts_nothing` with it; its config names the        *)
(* first). The `.probe.` configs run the clause's engine and show each     *)
(* behaviour happen: a response fact expiring, a `CallError`               *)
(* expiring at its own TTL, a re-fired call superseding, a call firing     *)
(* while its request is owed, an arriving answer superseding a live one,   *)
(* the earlier request's answer outliving the later's, two answers of a    *)
(* call whose correlation is generated live together, one per firing, a    *)
(* cooled call denied while its answer is live, which stays live, and a    *)
(* denied call admitted again once its window has elapsed. The `.scope.`   *)
(* config beside this module runs the clause's engine under the other      *)
(* ordering of the two TTLs, with every check of call_response.cfg, and    *)
(* must pass.                                                              *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

\* @spec [LCRS.3.3]
\* The calls, one per correlation space: a value an author writes, which every
\* firing of the call shares (uniqueness is the author's responsibility), or
\* a call site whose correlation the engine generates, one value per firing
\* and never another call's ([LCCO.3.4]). Either way an answer's corr
\* identifies exactly its call.
CONSTANT lcrs_3_3__call

\* @spec [LCRS.4.3.2]
\* The TTL the service's response schema declares, in ticks. One service is
\* modelled, so one duration: the response fact of every call of it lives this
\* long.
CONSTANT lcrs_4_3_2__TTL

\* @spec [LCRS.4.2.1]
\* `CallError`'s TTL, 5_min, in ticks. Independent of the response schema's:
\* a schema declares its own ([LCRS.4.3.2]) and may put it below or above
\* 5_min. call_response.cfg sets this one the longer;
\* call_response.scope.long.cfg (the clause's engine) and the `one_ttl_long`
\* teeth config set it the shorter.
CONSTANT lcrs_4_2_1__ERROR_TTL

\* @spec [LCCO.3.4]
\* The calls whose correlation the engine generates, one value per firing: a
\* call with no `as`, or whose `as` evaluates to "" and takes the same value
\* ([LRST.1.2]). A subset of the calls; the configs make it one of the two,
\* the one with no cooldown.
CONSTANT lcco_3_4__GENERATED

\* @spec [LCRS.6.2.4]
\* How many times a call's firing is admitted in a run, at most. Each admitted
\* firing issues a request the adapter answers at most once, so this bounds the
\* answers a correlation can ever have. 2 is the clause's case: a firing, and
\* one more before its request is answered.
CONSTANT lcrs_6_2_4__FIRES

\* @spec [LCRS.8.1]
\* The calls that carry `cooldown:`; the rest carry `nocooldown`, and every
\* call carries one or the other. A subset of the calls; the configs make it
\* the one with an author's `as`, so the gate is met where the sweep has
\* something to leave.
CONSTANT lcrs_8_1__COOLED

\* @spec [LCRS.8.2]
\* The cooldown window, in ticks: a cooled call issued within this many ticks
\* is suppressed. One window for every cooled call.
CONSTANT lcrs_8_2__WINDOW

\* @spec [LCRS.8.2]
\* How many times a cooled call may be suppressed in a run, at most. A bound
\* on the state and nothing in the clause: a denial changes nothing but its
\* count, and the count is what makes a denial a step TLC can show.
CONSTANT lcrs_8_2__DENIALS

\* @spec [LCRS.6.1]
\* Which engine this run is of. "clause" is the clauses', and call_response.cfg
\* runs it, as call_response.scope.long.cfg does under the other ordering of
\* the two TTLs. The others are engines the clauses rule out, each modelled so
\* that a property can be SEEN to fail; each `.teeth.` config beside this
\* module runs one, and scripts/formal/check_tla.py requires that run to end in
\* a violation.
\*   "kindless"  the adapter's answer carries no kind
\*   "early"     the sweep retracts an answer before its TTL
\*   "late"      the sweep retracts an answer one tick after its TTL
\*   "one_ttl"   the sweep applies the response schema's TTL to a `CallError`;
\*               run under both orderings of the two TTLs (`one_ttl`,
\*               `one_ttl_long`), since it errs differently in each
\*   "unswept"   there is no TTL sweep
\*   "stalled"   the clock never ticks
\*   "keepboth"  an arriving answer is asserted beside the live one
\*   "errkeeps"  an arriving `CallError` retracts `CallError`s only
\*   "respkeeps" an arriving response retracts its own schema's facts only
\*   "nosweep"   a call is issued without retracting the answers of its
\*               correlation
\*   "sitecorr"  a call with no `as` takes one correlation per call site, not
\*               per firing, so its firings share it
\*   "ungated"   the sweep is compiled ahead of the cooldown gate, so a
\*               denied firing retracts what an admitted one would
\*   "nogate"    the cooldown gate admits every firing
CONSTANT lcrs_6_1__ENGINE

\* @spec [LCRS.4.2.2]
\* The two mutually-exclusive answer kinds -- exactly one is asserted per request.
lcrs_4_2_2__Kind == { "response", "error" }

\* @spec [LCRS.6.6.1]
\* The age past which nothing more can happen to an answer: one past the longer
\* TTL, so that the "late" and "unswept" engines have a state to be caught in.
lcrs_6_6_1__MAXAGE ==
    (IF lcrs_4_3_2__TTL > lcrs_4_2_1__ERROR_TTL
       THEN lcrs_4_3_2__TTL
       ELSE lcrs_4_2_1__ERROR_TTL) + 1

\* @spec [LCRS.6.1]
\* Working memory, per call: the set of live answers of that call, each
\* carrying its request's correlation. An answer is the reply to one request
\* (`id`, the firing it answers), of one kind, at one age. The clauses' engine
\* keeps at most one per correlation; the model holds a set so that an engine
\* keeping two can be run and seen to fail, and so that a call whose
\* correlation is generated can hold one answer per firing.
VARIABLE lcrs_6_1__wm

\* @spec [LCRS.4.2.2]
\* @derives [NCBK.6.3]
\* Per call, the requests issued and not yet answered, by firing number. This is
\* the ADAPTER's bookkeeping, not the engine's ([NCBK.6.3]: the engine tracks no
\* in-flight call); it is what makes "exactly one answer per request" a bound
\* on the adapter rather than a hope. Any owed request may be answered next, so
\* replies arrive in any order.
VARIABLE lcrs_4_2_2__owed

\* @spec [LCRS.6.2.4]
\* Per call, how many times its firing has been admitted, bounded by `FIRES`.
VARIABLE lcrs_6_2_4__fired

\* @spec [LCRS.17.1]
\* @derives [LCRS.4.2.2]
\* Whether the call is to a `no response` service: success asserts nothing, so
\* its only possible answer is a `CallError`. The program's choice, fixed at Init.
VARIABLE lcrs_17_1__silent

\* @spec [LCRS.8.2]
\* Per cooled call, the ticks since its last admitted firing, saturating at the
\* window; at the window from the start, because a call that has never fired is
\* admitted. The gate's whole state here: at the window the window has elapsed
\* and the call is admitted, below it the call is suppressed.
VARIABLE lcrs_8_2__since

\* @spec [LCRS.8.2]
\* Per cooled call, how many times the gate has suppressed it.
VARIABLE lcrs_8_2__denied

\* @spec [LCRS.6.1]
\* The state tuple -- the variables a step may change.
lcrs_6_1__vars ==
    << lcrs_6_1__wm, lcrs_4_2_2__owed, lcrs_6_2_4__fired, lcrs_17_1__silent,
       lcrs_8_2__since, lcrs_8_2__denied >>

\* @spec [LCRS.4.2.2]
\* An answer's kind: a response fact or a `CallError` ("none" only in the
\* "kindless" engine, which the clause rules out).
lcrs_4_2_2__kind(a) == a.kind

\* @spec [LCRS.6.6.1]
\* An answer's age: ticks since it went live, saturating at MAXAGE -- the
\* deadline, counted from the assertion instead of on the clock.
lcrs_6_6_1__age(a) == a.age

\* @spec [LCRS.6.1]
\* Initially no call has fired: nothing is live, nothing is owed, every cooled
\* call's window has elapsed and none has been suppressed. Which calls are to a
\* `no response` service is the program's choice, so every assignment is
\* explored.
lcrs_6_1__Init ==
    /\ lcrs_6_1__wm = [ c \in lcrs_3_3__call |-> {} ]
    /\ lcrs_4_2_2__owed = [ c \in lcrs_3_3__call |-> {} ]
    /\ lcrs_6_2_4__fired = [ c \in lcrs_3_3__call |-> 0 ]
    /\ lcrs_17_1__silent \in [ lcrs_3_3__call -> BOOLEAN ]
    /\ lcrs_8_2__since = [ c \in lcrs_8_1__COOLED |-> lcrs_8_2__WINDOW ]
    /\ lcrs_8_2__denied = [ c \in lcrs_8_1__COOLED |-> 0 ]

\* @spec [LCRS.6.6.1]
\* The TTL a live answer expires at: its schema's -- the response schema's for a
\* response fact, 5_min for a `CallError`. Per kind; nothing else decides it.
lcrs_6_6_1__ttl_of(a) ==
    IF lcrs_4_2_2__kind(a) = "error" THEN lcrs_4_2_1__ERROR_TTL ELSE lcrs_4_3_2__TTL

\* @spec [LCRS.6.6.1]
\* The age at which this run's engine sweeps an answer. The clause's engine sweeps
\* at the TTL; the teeth engines sweep early, late, at one TTL for both kinds, or
\* never (an age no live answer reaches).
lcrs_6_6_1__sweeps_at(a) ==
    CASE lcrs_6_1__ENGINE = "early"   -> 1
      [] lcrs_6_1__ENGINE = "late"    -> lcrs_6_6_1__ttl_of(a) + 1
      [] lcrs_6_1__ENGINE = "one_ttl" -> lcrs_4_3_2__TTL
      [] lcrs_6_1__ENGINE = "unswept" -> lcrs_6_6_1__MAXAGE + 1
      [] OTHER                        -> lcrs_6_6_1__ttl_of(a)

\* @spec [LCRS.3.1]
\* @derives [LCCO.3.4]
\* The correlation of call c's request number i, as the engine compares it: an
\* author's `as` is one value every firing of c shares (0 here, a name for the
\* author's string); a generated correlation is unique to the firing it is
\* minted for ([LCCO.3.4]), so it is the request's own number. An answer's
\* correlation is its request's, and a firing's is the request's it issues.
\* Every call has one ([LCRS.3.1]); that it is never null or empty is the
\* clause's and not drawn. The "sitecorr" engine, which [LCCO.3.4] rules out,
\* gives a generated call one value per call site, as an author's `as` is.
lcrs_3_1__corr(c, i) ==
    IF c \in lcco_3_4__GENERATED /\ lcrs_6_1__ENGINE # "sitecorr" THEN i ELSE 0

\* @spec [LCRS.6.2.1]
\* The live answers of call c that the sweep of c's next firing leaves: those
\* whose correlation is not the firing's. Under an author's `as` every answer
\* of c shares it and none is left -- with one service, every response fact
\* and every `CallError` with that corr goes; under a generated correlation
\* none shares it and all are left: the sweep runs and finds nothing
\* (RLOW.7.3.8).
lcrs_6_2_1__after_sweep(c) ==
    { a \in lcrs_6_1__wm[c] :
        lcrs_3_1__corr(c, a.id) # lcrs_3_1__corr(c, lcrs_6_2_4__fired[c] + 1) }

\* @spec [LCRS.6.2.4]
\* The live answers of call c that an ARRIVING answer to request i, of kind k,
\* leaves live. The clause's engine leaves those whose correlation is not the
\* arriving answer's: under an author's `as` none -- with one service, a
\* response fact retracts every response fact and every `CallError` with its
\* corr, and a `CallError` retracts the same -- and under a generated
\* correlation all, since no other answer carries the request's. The three
\* teeth engines each leave something of what shares it: all of it, the
\* response facts when a `CallError` arrives, the `CallError`s when a response
\* arrives.
lcrs_6_2_4__survivors(c, i, k) ==
    LET shared == { a \in lcrs_6_1__wm[c] :
                      lcrs_3_1__corr(c, a.id) = lcrs_3_1__corr(c, i) }
        kept   == lcrs_6_1__wm[c] \ shared
    IN  CASE lcrs_6_1__ENGINE = "keepboth"  -> lcrs_6_1__wm[c]
          [] lcrs_6_1__ENGINE = "errkeeps"  ->
               kept \cup (IF k = "error"
                            THEN { a \in shared : lcrs_4_2_2__kind(a) = "response" }
                            ELSE {})
          [] lcrs_6_1__ENGINE = "respkeeps" ->
               kept \cup (IF k = "response"
                            THEN { a \in shared : lcrs_4_2_2__kind(a) = "error" }
                            ELSE {})
          [] OTHER -> kept

\* @spec [LCRS.8.2]
\* Whether the gate admits call c's firing: c carries no cooldown, or its window
\* has elapsed. The "nogate" engine, which the clauses rule out, admits every
\* firing. An IF and not a disjunction: TLC branches on a disjunction inside an
\* action and would read `since` of a call it is not defined on.
lcrs_8_2__admits(c) ==
    IF c \notin lcrs_8_1__COOLED \/ lcrs_6_1__ENGINE = "nogate"
      THEN TRUE
      ELSE lcrs_8_2__since[c] = lcrs_8_2__WINDOW

\* @spec [LCRS.6.2.1]
\* The gate admits the call and it fires `call S ... as c`: the engine first
\* retracts every live answer with that correlation -- every response fact of
\* S's schema and every `CallError`, which with one service is all of them --
\* and only then issues the request, which the adapter now owes an answer to.
\* The sweep and the request are one step, both inside the gate: the engine
\* performs the sweep while evaluating the call (RLOW.7.3.8), so what the gate
\* denies gets neither. A cooled call's window closes again. Whether an earlier
\* request is still owed does not matter: that is [LCRS.6.2.4]'s case, and
\* nothing here prevents it. Every call has a correlation ([LCRS.3.1]), so every
\* admitted firing sweeps; under a generated one the sweep finds nothing, since
\* no earlier answer carries the firing's ([LCCO.3.4]). The "nosweep" engine,
\* which the clause rules out, issues the request and retracts nothing.
\* Opportunistic, so it carries no fairness: a correlation may never be
\* refreshed.
lcrs_6_2_1__Fire(c) ==
    /\ lcrs_6_2_4__fired[c] < lcrs_6_2_4__FIRES
    /\ lcrs_8_2__admits(c)
    /\ lcrs_6_1__wm' = [ lcrs_6_1__wm EXCEPT ![c] =
                           IF lcrs_6_1__ENGINE = "nosweep" THEN @
                           ELSE lcrs_6_2_1__after_sweep(c) ]
    /\ lcrs_4_2_2__owed' =
         [ lcrs_4_2_2__owed EXCEPT ![c] = @ \cup { lcrs_6_2_4__fired[c] + 1 } ]
    /\ lcrs_6_2_4__fired' = [ lcrs_6_2_4__fired EXCEPT ![c] = @ + 1 ]
    /\ lcrs_8_2__since' =
         IF c \in lcrs_8_1__COOLED THEN [ lcrs_8_2__since EXCEPT ![c] = 0 ]
                                   ELSE lcrs_8_2__since
    /\ UNCHANGED << lcrs_17_1__silent, lcrs_8_2__denied >>

\* @spec [LCRS.8.2]
\* @derives [LCRS.6.2.1]
\* The gate suppresses call c's firing: c carries a cooldown and its window has
\* not elapsed. The call is not issued and retracts nothing ([LCRS.6.2.1]);
\* only the count of denials moves. The "ungated" engine, which the clauses
\* rule out, has the sweep compiled ahead of the gate: its denied firing
\* retracts what an admitted one would, and still issues nothing.
lcrs_8_2__Deny(c) ==
    /\ c \in lcrs_8_1__COOLED
    /\ ~lcrs_8_2__admits(c)
    /\ lcrs_8_2__denied[c] < lcrs_8_2__DENIALS
    /\ lcrs_8_2__denied' = [ lcrs_8_2__denied EXCEPT ![c] = @ + 1 ]
    /\ lcrs_6_1__wm' =
         IF lcrs_6_1__ENGINE = "ungated"
           THEN [ lcrs_6_1__wm EXCEPT ![c] = lcrs_6_2_1__after_sweep(c) ]
           ELSE lcrs_6_1__wm
    /\ UNCHANGED << lcrs_4_2_2__owed, lcrs_6_2_4__fired, lcrs_17_1__silent,
                    lcrs_8_2__since >>

\* @spec [LCRS.8.2]
\* The rule fires with the call in its RHS: the gate admits the firing, or
\* suppresses it. What the two cooldown properties quantify over.
lcrs_8_2__Attempt(c) == lcrs_6_2_1__Fire(c) \/ lcrs_8_2__Deny(c)

\* @spec [LCRS.4.2.2]
\* @derives [LCRS.17.1]
\* @derives [LCRS.6.2.4]
\* The adapter answers one of call c's owed requests: it asserts exactly one
\* response fact XOR `CallError` for it, with the request's correlation, and the
\* request is owed no more. A call to a `no response` service can only fail: its
\* answer is a `CallError`, or silence, which is no step at all. On arrival the
\* engine applies the supersede again ([LCRS.6.2.4]): the live answers with that
\* corr the engine does not keep are retracted, and the arriving one goes live
\* at age zero -- so the answer asserted last is the one live, whichever request
\* it answers.
lcrs_4_2_2__Respond(c) ==
    \E i \in lcrs_4_2_2__owed[c] :
      \E k \in (IF lcrs_6_1__ENGINE = "kindless" THEN { "none" } ELSE lcrs_4_2_2__Kind) :
        /\ lcrs_17_1__silent[c] => k # "response"
        /\ lcrs_6_1__wm' =
             [ lcrs_6_1__wm EXCEPT ![c] =
                 lcrs_6_2_4__survivors(c, i, k) \cup { [ id |-> i, kind |-> k, age |-> 0 ] } ]
        /\ lcrs_4_2_2__owed' = [ lcrs_4_2_2__owed EXCEPT ![c] = @ \ { i } ]
        /\ UNCHANGED << lcrs_6_2_4__fired, lcrs_17_1__silent,
                        lcrs_8_2__since, lcrs_8_2__denied >>

\* @spec [RARC.5.2.4]
\* @derives [LCRS.6.6.1]
\* @derives [LCRS.8.2]
\* The clock advances and the pump that follows sweeps: every live answer ages by
\* one, and each whose age has reached the age this engine sweeps at is expired
\* and retracted at the pump's entry, in the same step. The tick is the only
\* thing that can expire an answer. It is also the only thing that elapses a
\* cooled call's window: the pump's monotonic sample is what the gate reads,
\* and it moves with the clock.
rarc_5_2_4__Tick ==
    /\ lcrs_6_1__ENGINE # "stalled"
    /\ lcrs_6_1__wm' =
         [ c \in lcrs_3_3__call |->
             LET aged == { [ a EXCEPT !.age = IF a.age < lcrs_6_6_1__MAXAGE
                                                THEN a.age + 1 ELSE a.age ]
                           : a \in lcrs_6_1__wm[c] }
             IN  { a \in aged : lcrs_6_6_1__age(a) < lcrs_6_6_1__sweeps_at(a) } ]
    /\ lcrs_8_2__since' =
         [ c \in lcrs_8_1__COOLED |->
             IF lcrs_8_2__since[c] < lcrs_8_2__WINDOW THEN lcrs_8_2__since[c] + 1
                                                     ELSE lcrs_8_2__since[c] ]
    /\ UNCHANGED << lcrs_4_2_2__owed, lcrs_6_2_4__fired, lcrs_17_1__silent,
                    lcrs_8_2__denied >>

\* @spec [LCRS.6.1]
\* Next: some call fires or is suppressed or is answered, or the clock ticks and
\* the pump that follows it sweeps.
lcrs_6_1__Next ==
    \/ \E c \in lcrs_3_3__call :
         \/ lcrs_6_2_1__Fire(c)
         \/ lcrs_8_2__Deny(c)
         \/ lcrs_4_2_2__Respond(c)
    \/ rarc_5_2_4__Tick

\* @spec [LCRS.6.1]
\* The behavior spec. WEAK FAIRNESS on the tick is what turns "a live answer is
\* eventually gone" into a guarantee: the clock keeps moving, and the pump that
\* follows each sample sweeps. Fire, Deny and Respond are deliberately NOT fair
\* -- an adapter may never answer (silence, or the timeout the author writes)
\* and a correlation may never be refreshed; both are allowed, and the second is
\* the case the TTL exists for.
lcrs_6_1__Spec ==
    /\ lcrs_6_1__Init
    /\ [][lcrs_6_1__Next]_lcrs_6_1__vars
    /\ WF_lcrs_6_1__vars(rarc_5_2_4__Tick)

\* @spec [LCRS.6.1]
\* Type-correctness -- a state invariant true at every reachable state. Two
\* answers of one call never answer the same request: an owed request is
\* answered once, so the ids in a call's working memory are distinct.
lcrs_6_1__TypeOK ==
    /\ \A c \in lcrs_3_3__call :
         /\ \A a \in lcrs_6_1__wm[c] :
              a \in [ id: 1 .. lcrs_6_2_4__FIRES,
                      kind: lcrs_4_2_2__Kind \cup { "none" },
                      age: 0 .. lcrs_6_6_1__MAXAGE ]
         /\ \A a, b \in lcrs_6_1__wm[c] : a.id = b.id => a = b
         /\ lcrs_4_2_2__owed[c] \subseteq 1 .. lcrs_6_2_4__FIRES
         /\ lcrs_6_2_4__fired[c] \in 0 .. lcrs_6_2_4__FIRES
         /\ \A i \in lcrs_4_2_2__owed[c] : i <= lcrs_6_2_4__fired[c]
         /\ \A a \in lcrs_6_1__wm[c] : a.id \notin lcrs_4_2_2__owed[c]
    /\ lcrs_17_1__silent \in [ lcrs_3_3__call -> BOOLEAN ]
    /\ lcco_3_4__GENERATED \subseteq lcrs_3_3__call
    /\ lcrs_8_1__COOLED \subseteq lcrs_3_3__call
    /\ lcrs_8_2__since \in [ lcrs_8_1__COOLED -> 0 .. lcrs_8_2__WINDOW ]
    /\ lcrs_8_2__denied \in [ lcrs_8_1__COOLED -> 0 .. lcrs_8_2__DENIALS ]
    /\ lcrs_6_1__ENGINE \in { "clause", "kindless", "early", "late", "one_ttl",
                              "unswept", "stalled", "keepboth", "errkeeps",
                              "respkeeps", "nosweep", "sitecorr", "ungated",
                              "nogate" }

\* @derives [LCRS.4.2.2]
\* @derives [LCRS.17.1]
\* EXACTLY ONE KIND (safety): every live answer is a response fact XOR a
\* CallError, and a `no response` service's answer is a CallError. NO
\* counterexample.
lcrs_4_2_2__one_kind_when_live ==
    \A c \in lcrs_3_3__call : \A a \in lcrs_6_1__wm[c] :
        /\ lcrs_4_2_2__kind(a) \in lcrs_4_2_2__Kind
        /\ lcrs_17_1__silent[c] => lcrs_4_2_2__kind(a) = "error"

\* @derives [LCRS.6.2.4]
\* ONE ANSWER PER CORRELATION (safety): at most one answer with a given
\* correlation is live, however many requests that correlation has outstanding
\* and in whatever order their replies arrive. The arriving answer's supersede
\* is what makes it so once a call has fired while a request was owed. Stated
\* per correlation, as the clause's "for each correlation" is: the answers of
\* a call whose correlation is generated carry one each, so two of them live
\* together are not two under one correlation. NO counterexample.
lcrs_6_2_4__one_answer_per_corr ==
    \A c \in lcrs_3_3__call : \A a, b \in lcrs_6_1__wm[c] :
        lcrs_3_1__corr(c, a.id) = lcrs_3_1__corr(c, b.id) => a = b

\* @spec [LCRS.6.2.1]
\* @derives [RLOW.7.3.8]
\* EVERY ISSUED CALL SWEEPS (safety): after a call's admitted firing no live
\* answer carries the firing's correlation -- every response fact and
\* `CallError` with it was retracted before the request was issued. Every call
\* has a correlation ([LCRS.3.1]), so no firing is outside it: under an
\* author's `as` the sweep retracted every answer of the call, and under a
\* generated correlation no answer ever carried the firing's (RLOW.7.3.8). NO
\* counterexample.
lcrs_6_2_1__issued_call_sweeps ==
    [][ \A c \in lcrs_3_3__call :
          lcrs_6_2_1__Fire(c)
            => \A a \in lcrs_6_1__wm'[c] :
                 lcrs_3_1__corr(c, a.id) # lcrs_3_1__corr(c, lcrs_6_2_4__fired'[c])
      ]_lcrs_6_1__vars

\* @spec [LRST.1.2]
\* @derives [LCCO.3.4]
\* A GENERATED CORRELATION SUPERSEDES NOTHING (safety): a call whose
\* correlation the engine generates retracts no answer when it fires, and none
\* when its answer arrives, because the value is unique to the firing and no
\* other answer carries it -- one reply per call, as [LCCO.3.4] has it. With
\* `issued_call_sweeps`, the sweep ran and found nothing. NO counterexample.
lrst_1_2__generated_supersedes_nothing ==
    [][ \A c \in lcco_3_4__GENERATED :
          (lcrs_6_2_1__Fire(c) \/ lcrs_4_2_2__Respond(c))
            => lcrs_6_1__wm[c] \subseteq lcrs_6_1__wm'[c]
      ]_lcrs_6_1__vars

\* @spec [LCRS.6.2.1]
\* @derives [RLOW.7.3.8]
\* A SUPPRESSED CALL RETRACTS NOTHING (safety): a cooled call's firing inside
\* its window leaves every live answer of its correlation live. The sweep is
\* inside the gate -- the engine performs it while evaluating the call, and a
\* gate that denies the call leaves the call unevaluated (RLOW.7.3.8) -- so a
\* denied firing reaches neither the sweep nor the request. Stated over the
\* window and not over `Deny`, so that an engine with no gate is caught as well
\* as one with the sweep ahead of it. NO counterexample.
lcrs_6_2_1__suppressed_retracts_nothing ==
    [][ \A c \in lcrs_8_1__COOLED :
          (lcrs_8_2__Attempt(c) /\ lcrs_8_2__since[c] < lcrs_8_2__WINDOW)
            => lcrs_6_1__wm[c] \subseteq lcrs_6_1__wm'[c]
      ]_lcrs_6_1__vars

\* @spec [LCRS.8.2]
\* @derives [LCRS.6.2.1]
\* A SUPPRESSED CALL IS NOT ISSUED (safety): a cooled call's firing inside its
\* window owes the adapter nothing new -- no request is issued. With
\* `suppressed_retracts_nothing` this is [LCRS.6.2.1]'s cooldown sentence
\* whole: not issued, and retracts nothing. NO counterexample.
lcrs_8_2__suppressed_not_issued ==
    [][ \A c \in lcrs_8_1__COOLED :
          (lcrs_8_2__Attempt(c) /\ lcrs_8_2__since[c] < lcrs_8_2__WINDOW)
            => lcrs_4_2_2__owed'[c] = lcrs_4_2_2__owed[c]
      ]_lcrs_6_1__vars

\* @derives [LCRS.6.6.1]
\* @derives [IRET.22.6]
\* NOT BEFORE ITS TTL (safety): the SWEEP retracts an answer only once it has
\* been live for its whole TTL -- the response schema's for a response fact,
\* 5_min for a CallError. The two supersedures retract earlier by design, so the
\* property is about the tick alone: an answer the tick removes was one tick
\* short of its TTL. NO counterexample.
lcrs_6_6_1__not_before_its_ttl ==
    [][ rarc_5_2_4__Tick =>
          \A c \in lcrs_3_3__call : \A a \in lcrs_6_1__wm[c] :
            (\A b \in lcrs_6_1__wm'[c] : b.id # a.id)
              => lcrs_6_6_1__age(a) + 1 >= lcrs_6_6_1__ttl_of(a)
      ]_lcrs_6_1__vars

\* @derives [LCRS.6.6.1]
\* NEVER PAST ITS TTL (safety): no live answer is at or past its TTL -- the tick
\* that brings the deadline retracts it, so no site setting has extended it. With
\* `not_before_its_ttl` this is "expires AT its schema's TTL". NO counterexample.
lcrs_6_6_1__never_past_its_ttl ==
    \A c \in lcrs_3_3__call : \A a \in lcrs_6_1__wm[c] :
        lcrs_6_6_1__age(a) < lcrs_6_6_1__ttl_of(a)

\* @derives [LCRS.6.6.1]
\* NO ORPHAN FOREVER (liveness): every answer that goes live is eventually gone
\* -- superseded by a firing, superseded by an arrival, or expired. Per answer,
\* by the request it answers, so that a correlation kept live by a stream of
\* answers is not mistaken for one answer that never goes. Holds only under weak
\* fairness on the tick (see TEETH): the clock reaches the deadline, and the
\* pump that follows retracts. NO counterexample.
lcrs_6_6_1__no_orphan_forever ==
    \A c \in lcrs_3_3__call, i \in 1 .. lcrs_6_2_4__FIRES :
        [] ( (\E a \in lcrs_6_1__wm[c] : a.id = i)
               => <>(\A a \in lcrs_6_1__wm[c] : a.id # i) )

\* @gap
gap__lcrs_6_2_4_service_scope == TRUE

\* PROBES. Each property above is of the form "whenever an answer is live, or
\* is retracted, ...", and holds of a model in which none ever is. Each
\* definition below says that what a property is about never happens; its
\* `.probe.` config runs THIS engine, with the constants of call_response.cfg,
\* and scripts/formal/check_tla.py requires TLC to end in a violation. The trace
\* it prints is the behaviour.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no response fact ever expires. The run that
\* breaks it is a response fact that goes live and is swept at the response
\* schema's TTL: the step `not_before_its_ttl` is about, at the age
\* `never_past_its_ttl` bounds, and the end `no_orphan_forever` promises.
probe__no_response_expiry ==
    [][ rarc_5_2_4__Tick =>
          \A c \in lcrs_3_3__call : \A a \in lcrs_6_1__wm[c] :
            lcrs_4_2_2__kind(a) = "response"
              => \E b \in lcrs_6_1__wm'[c] : b.id = a.id
      ]_lcrs_6_1__vars

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no CallError ever expires. The run that breaks
\* it is a CallError swept at its own 5_min, an age past the response schema's
\* TTL in call_response.cfg's ordering: the per-kind TTL seen, and not only
\* never contradicted.
probe__no_error_expiry ==
    [][ rarc_5_2_4__Tick =>
          \A c \in lcrs_3_3__call : \A a \in lcrs_6_1__wm[c] :
            lcrs_4_2_2__kind(a) = "error"
              => \E b \in lcrs_6_1__wm'[c] : b.id = a.id
      ]_lcrs_6_1__vars

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no firing ever retracts a live answer. The
\* run that breaks it is a re-fired call retracting the live answer of its
\* correlation and issuing its request: [LCRS.6.2.1]'s retraction, before the
\* TTL, and the step `issued_call_sweeps` is about with something there to
\* sweep. Stated as a retraction and not as a firing beside a live answer:
\* under a generated correlation a call fires beside its own live answers and
\* retracts none, so the run is an author-correlated call's.
probe__no_supersedure ==
    [][ \A c \in lcrs_3_3__call :
          ~( lcrs_6_2_1__Fire(c)
             /\ \E a \in lcrs_6_1__wm[c] : a \notin lcrs_6_1__wm'[c] )
      ]_lcrs_6_1__vars

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: a call never fires while a request of its is
\* still owed. The run that breaks it is the case [LCRS.6.2.4] exists for: the
\* call fires, nothing is answered, and it fires again, so two requests are
\* owed under one correlation.
probe__no_refire_while_owed ==
    [][ \A c \in lcrs_3_3__call :
          ~( lcrs_4_2_2__owed[c] # {} /\ lcrs_6_2_1__Fire(c) )
      ]_lcrs_6_1__vars

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no arriving answer ever retracts a live one.
\* The run that breaks it is [LCRS.6.2.4]'s step: the second reply to a
\* twice-fired call arriving, retracting the first and going live in its
\* place. Stated as a retraction, as `no_supersedure` is: under a generated
\* correlation an answer arrives beside the call's live answers and retracts
\* none, so the run is an author-correlated call's.
probe__no_arrival_supersede ==
    [][ \A c \in lcrs_3_3__call :
          ~( lcrs_4_2_2__Respond(c)
             /\ \E a \in lcrs_6_1__wm[c] : a \notin lcrs_6_1__wm'[c] )
      ]_lcrs_6_1__vars

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: the answer to an earlier request never replaces
\* the answer to a later one. The run that breaks it is the clause's last
\* paragraph: two requests owed, the second's reply arrives first, then the
\* first's, and the first's is the one left live -- the engine does not know
\* which request a reply answers, so the one asserted last stays. Over the
\* calls with an author's `as`: under a generated correlation nothing replaces
\* anything, which is the next probe's.
probe__no_out_of_order ==
    [][ \A c \in lcrs_3_3__call \ lcco_3_4__GENERATED :
          \A a \in lcrs_6_1__wm[c] : \A b \in lcrs_6_1__wm'[c] :
            b.id >= a.id
      ]_lcrs_6_1__vars

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no two answers are ever live for a call whose
\* correlation is generated. The run that breaks it is such a call firing
\* twice and both replies arriving: each carries its own correlation, nothing
\* supersedes, and both stay -- one reply per call ([LCCO.3.4]), which is what
\* "supersedes nothing" comes to in working memory.
probe__no_generated_accumulation ==
    \A c \in lcco_3_4__GENERATED : Cardinality(lcrs_6_1__wm[c]) <= 1

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: the gate never suppresses a cooled call while
\* an answer of its is live. The run that breaks it is the vector
\* `LCRS.6.2.1_cooldown_suppressed_retracts_nothing`: the call fires, is
\* answered, and fires again inside its window; the gate denies it and the
\* answer stays live -- the step `suppressed_retracts_nothing` is about, with
\* something there to retract.
probe__no_suppression_with_live_answer ==
    [][ \A c \in lcrs_8_1__COOLED :
          ~( lcrs_6_1__wm[c] # {} /\ lcrs_8_2__Deny(c) )
      ]_lcrs_6_1__vars

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: a call the gate has suppressed never fires
\* again. The run that breaks it is the window elapsing: the call fires, is
\* denied, the clock ticks the window out, and the call fires again --
\* admitted, sweeping and issuing, where the denied firing did neither.
probe__no_readmission ==
    [][ \A c \in lcrs_8_1__COOLED :
          ~( lcrs_8_2__denied[c] > 0 /\ lcrs_6_2_1__Fire(c) )
      ]_lcrs_6_1__vars

=============================================================================

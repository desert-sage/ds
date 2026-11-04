--------------------------------- MODULE determinism ---------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS determinism -- the headline guarantee, as a behavioral spec          *)
(* (TLA+ / TLC). This is the model Alloy structurally cannot express:      *)
(* determinism is a statement about whole RUNS -- two executions on the    *)
(* same input produce the same trace -- not the shape of one state.        *)
(* formal/alloy/firing_order.als proves the firing order [LDET.5] is a     *)
(* strict total order (a snapshot fact); this model RUNS the consumption   *)
(* loop over an input trace and proves it deterministic ([LDET.2.4.10]).   *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the `\* @spec [ID]` / `\* @derives [ID]` line above   *)
(* it repeats the clause so the checker confirms the id exists AND matches. *)
(*                                                                         *)
(* THE MODEL (the earlier version had three activations                    *)
(* with keys hard-coded 1, 2, 3, no input and no firing effect, so its       *)
(* lockstep followed from key distinctness by construction and its tie was  *)
(* stamped `partial`). An INPUT TRACE is chosen in Init from every sequence *)
(* of length <= MAXLEN over three events: assert a fact of kind A, assert a  *)
(* fact of kind B, pump ([LFST.9.2.1]'s cadence: inputs, each followed by a  *)
(* pump to quiescence, with the pump boundary an event of the trace). Two    *)
(* engine copies consume the SAME trace. Two rules: R1 matches `A a, B b`   *)
(* (ordinal 1), R2 matches `B b` (ordinal 2). An assertion creates the      *)
(* matches it completes; a pump fires the agenda in the [LDET.5.1] order    *)
(* until it is empty; a fired activation is gone (refraction, [LDET.5.3]).  *)
(*                                                                         *)
(* THE KEY is [LDET.5.5]'s (and formal/alloy/firing_order.als's):           *)
(* the terminal ordinal, then the creation  *)
(* timetag, which is the tuple of the matched facts' assertion positions    *)
(* compared first by the latest position and then lexicographically in     *)
(* pattern-declaration order. Nothing here is hard-coded: the key is a      *)
(* function of the match and the trace.                                     *)
(*                                                                         *)
(* THE GUARANTEE. Each copy picks a maximal activation of its own agenda,   *)
(* modelled as a FREE choice so a tie would show. TLC proves, over every    *)
(* trace: the next-to-fire is unique ([LDET.5.1]); the two copies keep      *)
(* identical working memory, agenda and fired sequence at every state       *)
(* ([LDET.2.4.10]: identical trace, identical output); the run terminates. *)
(*                                                                         *)
(* TEETH, MEASURED on a host-side copy. Lockstep rests                     *)
(* on the lexicographic   *)
(* tiebreak. With `ldet_5_5__created_before` comparing completion positions *)
(* only, TLC fails `determinism` on the trace <<"A", "A", "B", "P">>: the B  *)
(* at position 3 completes two R1 matches, (1,3) and (2,3), with one key,    *)
(* `ldet_5_1__next` is no longer a singleton, and the two copies fire them   *)
(* in different orders -- the divergent state is the counterexample.        *)
(*                                                                         *)
(* SCOPE, for the verdict. No retraction, no RHS effect, no NOT pattern, no *)
(* clock: the consumption loop over asserts and pumps. The clause covers    *)
(* the whole engine, so the [LDET.2.4.10] tie stays `partial` and says so.  *)
(***************************************************************************)
EXTENDS Naturals, Sequences

\* @spec [LDET.2.4.10]
\* The bound on the input trace's length.
CONSTANT ldet_2_4_10__MAXLEN

\* @spec [LDET.5.1]
\* Which engine this run is of. "clause" is the clause's, and determinism.cfg
\* runs it. The others are engines the clauses rule out, each modelled so that a
\* property can be SEEN to fail: the header's TEETH were
\* measured once, on a copy; each `.teeth.` config beside this module is a run
\* scripts/formal/check_tla.py requires to end in a violation, on every run of
\* the lane.
\*   "completion_only"  the timetag is the completion position alone, with no
\*                      lexicographic second key
\*   "never_returns"    a pump that has drained its agenda does not return
CONSTANT ldet_5_1__ENGINE

\* @spec [LDET.2.4.10]
\* The three events an input trace is made of: assert a fact of kind A, assert a
\* fact of kind B, pump to quiescence.
ldet_2_4_10__Event == { "A", "B", "P" }

\* @spec [LDET.2.4.10]
\* Every input trace of length at most MAXLEN. Init picks one; TLC explores them all.
ldet_2_4_10__Traces ==
    UNION { [1..n -> ldet_2_4_10__Event] : n \in 0..ldet_2_4_10__MAXLEN }

\* @spec [LDET.2.4.10]
\* The input trace of this behaviour -- the same for both copies, by construction.
VARIABLE ldet_2_4_10__trace

\* @spec [LDET.2.4.10]
\* The index of the next event to consume.
VARIABLE ldet_2_4_10__pos

\* @spec [LDET.5.1]
\* The two engine copies -- two runs on the same input.
ldet_5_1__Copies == { 1, 2 }

\* @spec [LDET.5.1]
\* Per copy, the live facts: kind and assertion position (the event index).
VARIABLE ldet_5_1__live

\* @spec [LDET.5.1]
\* Per copy, the agenda: activations, each a rule (its ordinal) and its match, the
\* matched facts' assertion positions in pattern-declaration order.
VARIABLE ldet_5_1__agenda

\* @spec [LDET.5.1]
\* Per copy, the fired sequence -- the output the guarantee is about.
VARIABLE ldet_5_1__fired

\* @spec [LDET.5.1]
\* Whether a pump is draining the agenda (between a P event and quiescence).
VARIABLE ldet_5_1__pumping

\* @spec [LDET.5.1]
\* The state tuple.
ldet_5_1__vars ==
    << ldet_2_4_10__trace, ldet_2_4_10__pos, ldet_5_1__live, ldet_5_1__agenda,
       ldet_5_1__fired, ldet_5_1__pumping >>

\* @spec [LDET.5.5]
\* The position a match completed at: the latest assertion among its facts.
ldet_5_5__completed_at(m) ==
    CHOOSE p \in { m[i] : i \in 1..Len(m) } :
        \A q \in { m[i] : i \in 1..Len(m) } : q <= p

\* @spec [LDET.5.5]
\* Lexicographic order in pattern-declaration order on two equal-length matches:
\* at the first index where they differ, m's fact was asserted earlier.
ldet_5_5__lex_before(m, n) ==
    \E i \in 1..Len(m) :
        /\ \A j \in 1..(i - 1) : m[j] = n[j]
        /\ m[i] < n[i]

\* @spec [LDET.5.5]
\* THE TIMETAG ORDER: first by the position the match completed
\* at, then lexicographically. The second key, within one rule.
ldet_5_5__created_before(m, n) ==
    \/ ldet_5_5__completed_at(m) < ldet_5_5__completed_at(n)
    \/ /\ ldet_5_1__ENGINE # "completion_only"
       /\ ldet_5_5__completed_at(m) = ldet_5_5__completed_at(n)
       /\ ldet_5_5__lex_before(m, n)

\* @spec [LDET.5.1]
\* a fires before b: the lower ordinal first ([LDET.5.4], source order), then the
\* earlier timetag within one rule ([LDET.5.5]).
ldet_5_1__fires_before(a, b) ==
    \/ a.rule < b.rule
    \/ /\ a.rule = b.rule
       /\ ldet_5_5__created_before(a.match, b.match)

\* @spec [LDET.5.1]
\* The next-to-fire in an agenda: the activations nothing fires before. Under a
\* strict total order this set is a singleton.
ldet_5_1__next(agenda) ==
    { a \in agenda : \A b \in agenda : ~ldet_5_1__fires_before(b, a) }

\* @spec [LDET.5.1]
\* The matches an assertion of kind `e` at position `p` completes against the live
\* facts `wm`: R1 (`A a, B b`, ordinal 1) for each live fact of the other kind, and
\* R2 (`B b`, ordinal 2) when the new fact is a B.
ldet_5_1__Matches(wm, e, p) ==
    IF e = "A"
    THEN { [rule |-> 1, match |-> << p, f.pos >>] : f \in { g \in wm : g.kind = "B" } }
    ELSE { [rule |-> 1, match |-> << f.pos, p >>] : f \in { g \in wm : g.kind = "A" } }
         \cup { [rule |-> 2, match |-> << p >>] }

\* @spec [LDET.5.1]
\* Both copies start empty on one trace; nothing has been consumed.
ldet_5_1__Init ==
    /\ ldet_2_4_10__trace \in ldet_2_4_10__Traces
    /\ ldet_2_4_10__pos = 1
    /\ ldet_5_1__live = [ c \in ldet_5_1__Copies |-> {} ]
    /\ ldet_5_1__agenda = [ c \in ldet_5_1__Copies |-> {} ]
    /\ ldet_5_1__fired = [ c \in ldet_5_1__Copies |-> << >> ]
    /\ ldet_5_1__pumping = FALSE

\* @spec [LDET.2.4.10]
\* Consume the next input event, in both copies: an assertion enters working memory
\* at its position and creates the matches it completes; a P begins a pump.
ldet_2_4_10__Consume ==
    /\ ldet_5_1__pumping = FALSE
    /\ ldet_2_4_10__pos <= Len(ldet_2_4_10__trace)
    /\ LET e == ldet_2_4_10__trace[ldet_2_4_10__pos]
           p == ldet_2_4_10__pos
       IN IF e = "P"
          THEN /\ ldet_5_1__pumping' = TRUE
               /\ UNCHANGED << ldet_5_1__live, ldet_5_1__agenda >>
          ELSE /\ ldet_5_1__live' =
                    [ c \in ldet_5_1__Copies |->
                        ldet_5_1__live[c] \cup { [kind |-> e, pos |-> p] } ]
               /\ ldet_5_1__agenda' =
                    [ c \in ldet_5_1__Copies |->
                        ldet_5_1__agenda[c] \cup ldet_5_1__Matches(ldet_5_1__live[c], e, p) ]
               /\ UNCHANGED ldet_5_1__pumping
    /\ ldet_2_4_10__pos' = ldet_2_4_10__pos + 1
    /\ UNCHANGED << ldet_2_4_10__trace, ldet_5_1__fired >>

\* @spec [LDET.5.1]
\* One firing step of the pump: each copy independently picks a maximal activation
\* of its own agenda, fires it (appends it to its output) and drops it. Under a
\* strict total order the two picks coincide -- the choice is free to expose a tie.
ldet_5_1__FireBoth ==
    /\ ldet_5_1__pumping = TRUE
    /\ \A c \in ldet_5_1__Copies : ldet_5_1__agenda[c] # {}
    /\ \E a \in ldet_5_1__next(ldet_5_1__agenda[1]) :
         \E b \in ldet_5_1__next(ldet_5_1__agenda[2]) :
           /\ ldet_5_1__agenda' = [ ldet_5_1__agenda EXCEPT ![1] = @ \ { a }, ![2] = @ \ { b } ]
           /\ ldet_5_1__fired' = [ ldet_5_1__fired EXCEPT ![1] = Append(@, a), ![2] = Append(@, b) ]
    /\ UNCHANGED << ldet_2_4_10__trace, ldet_2_4_10__pos, ldet_5_1__live, ldet_5_1__pumping >>

\* @spec [LDET.5.1]
\* The pump reaches quiescence: both agendas empty, the pump returns.
ldet_5_1__PumpEnd ==
    /\ ldet_5_1__pumping = TRUE
    /\ \A c \in ldet_5_1__Copies : ldet_5_1__agenda[c] = {}
    /\ IF ldet_5_1__ENGINE = "never_returns"
         THEN UNCHANGED ldet_5_1__vars
         ELSE /\ ldet_5_1__pumping' = FALSE
              /\ UNCHANGED << ldet_2_4_10__trace, ldet_2_4_10__pos, ldet_5_1__live,
                              ldet_5_1__agenda, ldet_5_1__fired >>

\* @spec [LDET.5.1]
\* The trace is consumed and no pump is running -- an explicit terminal stutter so
\* the finished run is a legitimate end state, not a TLC deadlock.
ldet_5_1__Done ==
    /\ ldet_5_1__pumping = FALSE
    /\ ldet_2_4_10__pos > Len(ldet_2_4_10__trace)
    /\ UNCHANGED ldet_5_1__vars

\* @spec [LDET.5.1]
\* Next: consume an input, fire, end a pump, or the finished idle.
ldet_5_1__Next ==
    \/ ldet_2_4_10__Consume
    \/ ldet_5_1__FireBoth
    \/ ldet_5_1__PumpEnd
    \/ ldet_5_1__Done

\* @spec [LDET.5.1]
\* The behavior spec. WEAK FAIRNESS on the three engine actions so a run consumes
\* its trace and drains rather than stalling.
ldet_5_1__Spec ==
    /\ ldet_5_1__Init
    /\ [][ldet_5_1__Next]_ldet_5_1__vars
    /\ WF_ldet_5_1__vars(ldet_2_4_10__Consume)
    /\ WF_ldet_5_1__vars(ldet_5_1__FireBoth)
    /\ WF_ldet_5_1__vars(ldet_5_1__PumpEnd)

\* @spec [LDET.5.1]
\* Type-correctness -- a state invariant true at every reachable state.
ldet_5_1__TypeOK ==
    /\ ldet_2_4_10__trace \in ldet_2_4_10__Traces
    /\ ldet_2_4_10__pos \in 1..(ldet_2_4_10__MAXLEN + 1)
    /\ ldet_5_1__pumping \in BOOLEAN
    /\ ldet_5_1__ENGINE \in { "clause", "completion_only", "never_returns" }
    /\ \A c \in ldet_5_1__Copies :
         /\ ldet_5_1__live[c] \subseteq [kind : { "A", "B" }, pos : 1..ldet_2_4_10__MAXLEN]
         /\ \A a \in ldet_5_1__agenda[c] : a.rule \in { 1, 2 } /\ Len(a.match) = 3 - a.rule
         /\ \A i \in 1..Len(ldet_5_1__fired[c]) : ldet_5_1__fired[c][i].rule \in { 1, 2 }

\* @derives [LDET.5.1]
\* UNIQUE NEXT (safety): while a pump runs, each copy's next-to-fire is unique -- the
\* maximal activation is a singleton, so the engine's step is a FUNCTION of the state.
\* NO counterexample.
ldet_5_1__unique_next ==
    ldet_5_1__pumping = TRUE =>
        \A c \in ldet_5_1__Copies :
            \A a, b \in ldet_5_1__next(ldet_5_1__agenda[c]) : a = b

\* @derives [LDET.2.4.10]
\* SAME INPUT, SAME OUTPUT (the determinism guarantee): two copies consuming one
\* trace have identical working memory, identical agendas and the identical fired
\* sequence at every state. Holds because the firing key is a strict total order on
\* the matches (see TEETH). A state invariant. NO counterexample.
ldet_2_4_10__same_trace ==
    /\ ldet_5_1__live[1] = ldet_5_1__live[2]
    /\ ldet_5_1__agenda[1] = ldet_5_1__agenda[2]
    /\ ldet_5_1__fired[1] = ldet_5_1__fired[2]

\* @derives [LDET.5.1]
\* THE RUN TERMINATES (liveness): every trace is consumed and every pump drains --
\* each activation fires once, in the total order -- under weak fairness. NO
\* counterexample.
ldet_5_1__drains ==
    <>(ldet_2_4_10__pos > Len(ldet_2_4_10__trace) /\ ldet_5_1__pumping = FALSE)

\* PROBES. `same_trace` is an equality of two copies, and
\* holds where neither fires anything; `unique_next` says a set is a singleton,
\* and holds where the agenda never holds two activations a key could tie. The
\* definition below says the case the key exists for never happens; its
\* `.probe.` config runs THIS engine, with the constants of determinism.cfg,
\* and scripts/formal/check_tla.py requires TLC to end in a violation.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no copy ever fires two matches of one rule
\* that one event completed. A run that breaks it consumes three assertions of
\* which the third completes two matches of R1 at one position, and a pump that
\* fires both: the tie the second key decides, reached, with two firings in
\* each copy's output for `same_trace` to compare. The header's TEETH trace, A,
\* A, B, pump, is one such run and B, B, A, pump is another; which of them TLC
\* returns its log does not say.
probe__one_event_one_match ==
    \A i, j \in 1 .. Len(ldet_5_1__fired[1]) :
        ( /\ i # j
          /\ ldet_5_1__fired[1][i].rule = ldet_5_1__fired[1][j].rule )
          => ldet_5_5__completed_at(ldet_5_1__fired[1][i].match)
               # ldet_5_5__completed_at(ldet_5_1__fired[1][j].match)

=============================================================================

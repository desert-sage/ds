--------------------------------- MODULE stream_seq ---------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* DS event-stream sequencing -- the global `seq` order, as a TEMPORAL     *)
(* spec (TLA+ / TLC). This sits ABOVE the per-firing frame                 *)
(* formal/alloy/firing_event_frame.als: that model frames one firing's     *)
(* events; this models the whole stream, where every event -- local rule   *)
(* activations, TTL sweeps, adapter responses, cache ops -- funnels through *)
(* the engine's single consumption loop ([LFST.7.1.1]) which assigns `seq`  *)
(* in consumption order. The sources RACE (their interleaving is           *)
(* nondeterministic), but the single serialised counter                    *)
(* ([LFST.7.4.1]) makes the CONSUMPTION order total, strictly increasing    *)
(* ([NCBK.2.2]), and gap-free from 0 ([LFST.7.1.3]) -- WHATEVER the         *)
(* interleaving. The movie of the stream, not one firing's photograph.     *)
(*                                                                         *)
(* THE STREAM THIS MODELS IS THE CONSUMPTION STREAM: the sequence of `seq`  *)
(* values the engine assigns as it consumes events. AN RFCS RECORDING IS   *)
(* NOT THIS STREAM. The recorder writes only some of the events the loop   *)
(* consumes, and an event it does not write still takes its `seq`          *)
(* ([LFST.7.1.1], [NCBK.2.2]), so a recording has gaps by design:          *)
(* `[0, 1, 2, 4, 6]` is a recording in good standing. Nothing here is a    *)
(* claim about a recording; the clauses this model ties say "starting at   *)
(* 0" of the assignment and nothing of contiguity in a recording.          *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the `\* @spec [ID]` / `\* @derives [ID]` line above   *)
(* it repeats the clause so the checker confirms the id exists AND matches. *)
(*                                                                         *)
(* THE INVARIANT. `seq` is a per-engine counter assigned at consumption in  *)
(* the order the engine processes events ([LFST.7.1.1]). Because assignment *)
(* is strictly serialised through one writer ([LFST.7.4.1]), the            *)
(* consumption stream is strictly increasing ([NCBK.2.2]) and contiguous    *)
(* from 0 -- the counter stays in lockstep with the count of events         *)
(* consumed, so no seq is ever skipped or duplicated no matter how the      *)
(* event sources interleave. TLC proves all three across every reachable    *)
(* interleaving.                                                           *)
(*                                                                         *)
(* TEETH. The guarantees rest on the serialised single counter. Drop the    *)
(* `seq' = seq + 1` from `Consume` (a second writer that appends without    *)
(* advancing the shared counter) and `lfst_7_4_1__seq_counts_records` and   *)
(* `ncbk_2_2__strictly_increasing` fail -- TLC returns a stream with a       *)
(* duplicated / skipped seq, exactly the determinism breach serialisation   *)
(* exists to prevent.                                                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

\* @spec [LFST.7.1]
\* The event sources that all funnel through the one consumption loop -- local
\* activations, TTL sweeps, adapter responses, cache ops (representative set).
CONSTANT lfst_7_1__Source

\* @spec [LFST.7.1]
\* Per-source cap on queued events -- bounds the state graph.
CONSTANT lfst_7_1__CAP

\* @spec [LFST.7.1]
\* Which engine this run is of. "clause" is the clause's, and stream_seq.cfg
\* runs it. The other is the engine of the header's TEETH, modelled so that the
\* properties can be SEEN to fail: each `.teeth.` config
\* beside this module is a run scripts/formal/check_tla.py requires to end in a
\* violation, on every run of the lane.
\*   "second_writer"  a record is written and the counter is not advanced
CONSTANT lfst_7_1__ENGINE

\* @spec [LFST.7.1]
\* The most events the stream can hold: cap times the number of sources.
lfst_7_1__MAX == lfst_7_1__CAP * Cardinality(lfst_7_1__Source)

\* @spec [NCBK.2.2]
\* The per-engine seq counter: the next value to assign. Strictly increasing,
\* assigned at consumption ([LFST.7.1.1]).
VARIABLE ncbk_2_2__seq

\* @spec [LFST.7.1]
\* Events still queued at each source, waiting to be consumed by the single writer.
VARIABLE lfst_7_1__pending

\* @spec [LFST.7.1.1]
\* The consumption stream: a sequence of << seq, src >> records, one per event
\* consumed, in consumption order. Not an RFCS recording (the header).
VARIABLE lfst_7_1_1__log

\* @spec [LFST.7.1]
\* The state tuple -- the variables a consumption step may change.
lfst_7_1__vars == << ncbk_2_2__seq, lfst_7_1__pending, lfst_7_1_1__log >>

\* @spec [LFST.7.1]
\* Initially seq is 0, every source holds CAP queued events, the stream is empty.
lfst_7_1__Init ==
    /\ ncbk_2_2__seq = 0
    /\ lfst_7_1__pending = [ s \in lfst_7_1__Source |-> lfst_7_1__CAP ]
    /\ lfst_7_1_1__log = << >>

\* @spec [LFST.7.1.1]
\* The consumption loop: the single writer takes one queued event from source s,
\* stamps it with the current seq, appends it to the stream, and advances the
\* counter by exactly one. The choice of s is nondeterministic -- sources race --
\* but the stamp+advance is atomic, so the assignment is strictly serialised.
lfst_7_1_1__Consume(s) ==
    /\ lfst_7_1__pending[s] > 0
    /\ lfst_7_1_1__log' = Append(lfst_7_1_1__log, [ n |-> ncbk_2_2__seq, src |-> s ])
    /\ ncbk_2_2__seq' = (IF lfst_7_1__ENGINE = "second_writer"
                           THEN ncbk_2_2__seq
                           ELSE ncbk_2_2__seq + 1)
    /\ lfst_7_1__pending' = [ lfst_7_1__pending EXCEPT ![s] = lfst_7_1__pending[s] - 1 ]

\* @spec [LFST.7.1]
\* All sources drained -- the stream is complete, an explicit terminal stutter so
\* the drained state is a legitimate end state, not a TLC deadlock.
lfst_7_1__Drained ==
    /\ \A s \in lfst_7_1__Source : lfst_7_1__pending[s] = 0
    /\ UNCHANGED lfst_7_1__vars

\* @spec [LFST.7.1]
\* Next: consume some source's next queued event; else idle once drained.
lfst_7_1__Next ==
    \/ \E s \in lfst_7_1__Source : lfst_7_1_1__Consume(s)
    \/ lfst_7_1__Drained

\* @spec [LFST.7.1]
\* The behavior spec: Init, then stutter-closed steps of Next. A SAFETY spec -- the
\* guarantees are invariants over every reachable interleaving, so no fairness.
lfst_7_1__Spec == lfst_7_1__Init /\ [][lfst_7_1__Next]_lfst_7_1__vars

\* @spec [LFST.7.1]
\* Type-correctness -- a state invariant true at every reachable state.
lfst_7_1__TypeOK ==
    /\ ncbk_2_2__seq \in 0..lfst_7_1__MAX
    /\ lfst_7_1__pending \in [ lfst_7_1__Source -> 0..lfst_7_1__CAP ]
    /\ \A i \in DOMAIN lfst_7_1_1__log :
         /\ lfst_7_1_1__log[i].n \in 0..lfst_7_1__MAX
         /\ lfst_7_1_1__log[i].src \in lfst_7_1__Source
    /\ lfst_7_1__ENGINE \in { "clause", "second_writer" }

\* @derives [NCBK.2.2]
\* STRICTLY INCREASING (safety): the recorded seq order is strictly increasing --
\* every later record carries a strictly greater seq than every earlier one, no
\* matter how the sources interleaved. NO counterexample.
ncbk_2_2__strictly_increasing ==
    \A i, j \in DOMAIN lfst_7_1_1__log :
        (i < j) => (lfst_7_1_1__log[i].n < lfst_7_1_1__log[j].n)

\* @derives [LFST.7.1.1]
\* GAP-FREE (safety): seq is contiguous from 0 -- the k-th consumed event carries
\* seq k-1 (1-indexed), so the consumption stream is exactly 0, 1, 2, ... with no
\* gap. Assigned at consumption in order ([LFST.7.1.1]) starting at 0
\* ([LFST.7.1.3]). Of the consumption stream only: an RFCS recording, which
\* omits events, has gaps by design (the header). NO counterexample.
lfst_7_1_1__gap_free ==
    \A i \in DOMAIN lfst_7_1_1__log : lfst_7_1_1__log[i].n = i - 1

\* @derives [LFST.7.4.1]
\* SERIALISED LOCKSTEP (safety): the counter equals the number of events consumed,
\* the records of the consumption stream -- every consumed event advanced seq by
\* exactly one, so no seq is skipped and none is reused. This is the single-writer serialisation ([LFST.7.4.1]) that underwrites the
\* two properties above. NO counterexample.
lfst_7_4_1__seq_counts_records ==
    ncbk_2_2__seq = Len(lfst_7_1_1__log)

\* PROBES. The three properties above are about the order
\* of records "no matter how the sources interleaved", and hold of a model in
\* which they never interleave, or in which the stream never holds two
\* records. The definition below says they never interleave; its `.probe.`
\* config runs THIS engine, with the constants of stream_seq.cfg, and
\* scripts/formal/check_tla.py requires TLC to end in a violation.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: between two records of one source there is
\* never a record of another. The run that breaks it is the race: one source
\* is consumed, then another, then the first again, and the stream holds three
\* records for the properties to be about.
probe__sources_never_interleave ==
    \A i, j, k \in DOMAIN lfst_7_1_1__log :
        ( /\ i < j
          /\ j < k
          /\ lfst_7_1_1__log[i].src = lfst_7_1_1__log[k].src )
          => lfst_7_1_1__log[j].src = lfst_7_1_1__log[i].src

=============================================================================

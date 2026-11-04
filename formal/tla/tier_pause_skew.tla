------------------------------ MODULE tier_pause_skew ------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* Multi-tier coordinated breakpoints -- the leader/follower pause of      *)
(* [NDBG.22], as a behavioral spec (TLA+ / TLC).                           *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the other models:  *)
(* every operator / VARIABLE / CONSTANT is named <lowercased-clause-id>__  *)
(* <Tag> after the paragraph it formalizes, and the `\* @spec [ID]` line   *)
(* above it lets the spec gate's crossref confirm the id exists and that   *)
(* the clause acknowledges the tie.                                        *)
(*                                                                         *)
(* WHY THIS MODEL EXISTS. [NDBG.22.2.3] claims the leader/follower skew is *)
(* "bounded to at most one pump cycle", and [NDBG.22.3.1] claims a         *)
(* follower timeout leaves "the leader's pause state not affected". Both   *)
(* were prose that nothing verified. They are the only ordering claims in  *)
(* the introspection surface, and ordering over time is what this notation *)
(* is for.                                                                 *)
(*                                                                         *)
(* WHAT IS STRUCTURAL AND WHAT HAS TEETH -- stated rather than left for a  *)
(* reader to assume, because a model whose properties cannot fail is the   *)
(* [STYL.5.10.5] problem wearing a proof.                                  *)
(*                                                                         *)
(*   ndbg_22_2_3__skew_bounded is STRUCTURAL. A follower pauses at its     *)
(*   next pump boundary, so it cannot have crossed two. The invariant      *)
(*   pins that the transition relation admits no other path -- it would    *)
(*   fail if a future edit let a pending follower idle through a boundary. *)
(*                                                                         *)
(*   ndbg_22_3_1__leader_unaffected HAS TEETH. Let Timeout(t) also reset   *)
(*   the leader -- the obvious "abort the whole group" reading of a failed *)
(*   coordinated pause -- and TLC returns a counterexample immediately.    *)
(*   [NDBG.22.3.1] chose the other reading and nothing enforced it.        *)
(*                                                                         *)
(*   ndbg_22_3_1__every_follower_settles HAS TEETH, and they are the       *)
(*   timeout's whole justification. Drop the Timeout action and TLC finds  *)
(*   a behavior where a wedged follower stutters in "pause_pending"        *)
(*   forever -- the IDE's `pause pending` indicator never clearing, which  *)
(*   is what a 5-second timeout exists to prevent.                         *)
(***************************************************************************)
EXTENDS Naturals

\* @spec [NDBG.22.1.1]
\* The debug group -- a named set of tiers that coordinate pauses.
CONSTANT ndbg_22_1_1__tier

\* @spec [NDBG.22.3.2]
\* The per-group pause timeout, as a count of ticks a follower may fail to reach
\* a pump boundary before the leader gives up on it. The wall-clock default is
\* 5000 ms; the count is what matters to the ordering argument.
CONSTANT ndbg_22_3_2__TIMEOUT

\* @spec [NDBG.22.2.1]
\* Which engine this run is of. "clause" is the clause's, and
\* tier_pause_skew.cfg runs it. The others are engines the clauses rule out,
\* each modelled so that a property can be SEEN to fail: the
\* header says which property has teeth and which is structural, in sentences,
\* and each `.teeth.` config beside this module is the run of one, which
\* scripts/formal/check_tla.py requires to end in a violation.
\*   "aborts_group"   a follower's timeout resets the leader too
\*   "no_timeout"     there is no timeout
\*   "idles_through"  a pending follower crosses one boundary without pausing
\*                    and pauses at the next
CONSTANT ndbg_22_2_1__ENGINE

\* @spec [NDBG.22.1.2]
\* The tier whose breakpoint fired first, or "none" before any has. All others in
\* the group are followers for that pause event.
VARIABLE ndbg_22_1_2__leader

\* @spec [NDBG.22.2.2]
\* Per-tier pause state, as reported by `ds/tierPauseState`. "pause_pending" is the
\* IDE's warning indicator; "unresponsive" is [NDBG.22.3.1]'s terminal mark.
VARIABLE ndbg_22_2_2__state

\* @spec [NDBG.22.2.3]
\* Pump boundaries a follower has crossed since the pause request. The skew bound
\* is a claim about this number.
VARIABLE ndbg_22_2_3__boundaries

\* @spec [NDBG.22.3.1]
\* Ticks a follower has spent pending without reaching a boundary.
VARIABLE ndbg_22_3_1__ticks

\* @spec [NDBG.22.2.1]
\* The state tuple -- the variables a protocol step may change.
ndbg_22_2_1__vars ==
    << ndbg_22_1_2__leader, ndbg_22_2_2__state,
       ndbg_22_2_3__boundaries, ndbg_22_3_1__ticks >>

\* @spec [NDBG.22.2.2]
\* The four states a tier is reported in.
ndbg_22_2_2__States == { "running", "pause_pending", "paused", "unresponsive" }

\* @spec [NDBG.22.2.1]
\* Every tier running, no leader elected, nothing pending.
ndbg_22_2_1__Init ==
    /\ ndbg_22_1_2__leader = "none"
    /\ ndbg_22_2_2__state = [ t \in ndbg_22_1_1__tier |-> "running" ]
    /\ ndbg_22_2_3__boundaries = [ t \in ndbg_22_1_1__tier |-> 0 ]
    /\ ndbg_22_3_1__ticks = [ t \in ndbg_22_1_1__tier |-> 0 ]

\* @spec [NDBG.22.1.2]
\* A breakpoint fires in t while no leader holds. t becomes the leader for this
\* pause event, pauses immediately ([NDBG.22.2.1] step 1), and every other tier in
\* the group enters "pause_pending" ([NDBG.22.2.1] step 2).
ndbg_22_1_2__LeaderStops(t) ==
    /\ ndbg_22_1_2__leader = "none"
    /\ t \in ndbg_22_1_1__tier
    /\ ndbg_22_1_2__leader' = t
    /\ ndbg_22_2_2__state' =
           [ u \in ndbg_22_1_1__tier |->
               IF u = t THEN "paused" ELSE "pause_pending" ]
    /\ UNCHANGED << ndbg_22_2_3__boundaries, ndbg_22_3_1__ticks >>

\* @spec [NDBG.22.2.1]
\* A pending follower finishes its current pump cycle and pauses -- step 3, the
\* bounded latency window. Crossing the boundary is what ends the wait, so this is
\* the only action that takes a follower to "paused".
ndbg_22_2_1__FollowerReachesBoundary(t) ==
    /\ ndbg_22_2_2__state[t] = "pause_pending"
    /\ ndbg_22_2_2__state' =
           IF ndbg_22_2_1__ENGINE = "idles_through" /\ ndbg_22_2_3__boundaries[t] = 0
             THEN ndbg_22_2_2__state
             ELSE [ ndbg_22_2_2__state EXCEPT ![t] = "paused" ]
    /\ ndbg_22_2_3__boundaries' =
           [ ndbg_22_2_3__boundaries EXCEPT ![t] = @ + 1 ]
    /\ UNCHANGED << ndbg_22_1_2__leader, ndbg_22_3_1__ticks >>

\* @spec [NDBG.22.3.1]
\* Time passes for a follower that has not yet reached a boundary. Bounded by the
\* group timeout so the state graph stays finite.
ndbg_22_3_1__FollowerStalls(t) ==
    /\ ndbg_22_2_2__state[t] = "pause_pending"
    /\ ndbg_22_3_1__ticks[t] < ndbg_22_3_2__TIMEOUT
    /\ ndbg_22_3_1__ticks' = [ ndbg_22_3_1__ticks EXCEPT ![t] = @ + 1 ]
    /\ UNCHANGED << ndbg_22_1_2__leader, ndbg_22_2_2__state,
                    ndbg_22_2_3__boundaries >>

\* @spec [NDBG.22.3.1]
\* The follower missed its window. The leader emits `ds/tierPauseTimeout` and the
\* follower is marked "unresponsive". The leader's own state is deliberately
\* untouched -- that is the clause's claim, and the counterexample this model
\* exists to rule out is an implementation that aborts the group pause here.
ndbg_22_3_1__Timeout(t) ==
    /\ ndbg_22_2_1__ENGINE # "no_timeout"
    /\ ndbg_22_2_2__state[t] = "pause_pending"
    /\ ndbg_22_3_1__ticks[t] = ndbg_22_3_2__TIMEOUT
    /\ ndbg_22_2_2__state' =
           IF ndbg_22_2_1__ENGINE = "aborts_group"
             THEN [ ndbg_22_2_2__state EXCEPT ![t] = "unresponsive",
                                              ![ndbg_22_1_2__leader] = "running" ]
             ELSE [ ndbg_22_2_2__state EXCEPT ![t] = "unresponsive" ]
    /\ UNCHANGED << ndbg_22_1_2__leader, ndbg_22_2_3__boundaries,
                    ndbg_22_3_1__ticks >>

\* @spec [NDBG.22.2.1]
\* The user continues the group from the IDE. Every tier returns to running, the
\* leader is released, and the per-event counters reset so a later breakpoint is a
\* fresh pause event.
\*
\* This action exists because the all-paused state is where the protocol SUCCEEDS,
\* and with no way out of it TLC reports that success as a deadlock. Modelling the
\* resume rather than switching the deadlock check off also buys something: the
\* group can pause, settle and pause again, so every property below is checked
\* across repeated pause events instead of one.
ndbg_22_2_1__ResumeGroup ==
    /\ ndbg_22_1_2__leader # "none"
    /\ \A u \in ndbg_22_1_1__tier :
           ndbg_22_2_2__state[u] \in { "paused", "unresponsive" }
    /\ ndbg_22_1_2__leader' = "none"
    /\ ndbg_22_2_2__state' = [ u \in ndbg_22_1_1__tier |-> "running" ]
    /\ ndbg_22_2_3__boundaries' = [ u \in ndbg_22_1_1__tier |-> 0 ]
    /\ ndbg_22_3_1__ticks' = [ u \in ndbg_22_1_1__tier |-> 0 ]

\* @spec [NDBG.22.2.1]
\* The protocol's steps.
ndbg_22_2_1__Next ==
    \/ \E t \in ndbg_22_1_1__tier : ndbg_22_1_2__LeaderStops(t)
    \/ \E t \in ndbg_22_1_1__tier : ndbg_22_2_1__FollowerReachesBoundary(t)
    \/ \E t \in ndbg_22_1_1__tier : ndbg_22_3_1__FollowerStalls(t)
    \/ \E t \in ndbg_22_1_1__tier : ndbg_22_3_1__Timeout(t)
    \/ ndbg_22_2_1__ResumeGroup

\* @spec [NDBG.22.2.1]
\* Weak fairness on TIME PASSING for a pending follower and on its timeout, and
\* on nothing else. A follower is not obliged to reach its boundary: the clause
\* is about one that "does not reach its pause point", and the timeout is for
\* that one.
\*
\* THE FAIRNESS IS ON THE TICK, not on reaching the boundary: fairness there
\* would oblige every pending follower to pause, so `every_follower_settles`
\* would hold with the timeout dropped. With the fairness on the tick, a follower that never reaches its
\* boundary settles because its window runs out, and without a timeout it does
\* not settle.
ndbg_22_2_1__Spec ==
    /\ ndbg_22_2_1__Init
    /\ [][ndbg_22_2_1__Next]_ndbg_22_2_1__vars
    /\ \A t \in ndbg_22_1_1__tier :
           WF_ndbg_22_2_1__vars(ndbg_22_3_1__FollowerStalls(t))
    /\ \A t \in ndbg_22_1_1__tier :
           WF_ndbg_22_2_1__vars(ndbg_22_3_1__Timeout(t))

\* @spec [NDBG.22.2.2]
\* Shapes: every tier is in one of the four reported states, and the leader is a
\* group member or absent.
ndbg_22_2_2__TypeOK ==
    /\ ndbg_22_2_2__state \in [ ndbg_22_1_1__tier -> ndbg_22_2_2__States ]
    /\ ndbg_22_1_2__leader \in ndbg_22_1_1__tier \cup { "none" }
    /\ ndbg_22_2_3__boundaries \in [ ndbg_22_1_1__tier -> 0 .. 2 ]
    /\ ndbg_22_3_1__ticks \in [ ndbg_22_1_1__tier -> 0 .. ndbg_22_3_2__TIMEOUT ]
    /\ ndbg_22_2_1__ENGINE \in { "clause", "aborts_group", "no_timeout",
                                 "idles_through" }

\* @spec [NDBG.22.1.2]
\* One leader per pause event. The tier whose breakpoint fired first holds it, and
\* no second election can occur while it does.
\*
\* TAGGED `spec`, NOT `derives`: `leader = t /\ leader = u => t = u` is true of any
\* single-valued variable, so it restates the shape of `ndbg_22_1_2__leader`
\* rather than deriving anything from the protocol. It stays as a transcription
\* check -- the clause says one leader and the state carries one -- and it must
\* not be counted as a bounded refutation.
ndbg_22_1_2__at_most_one_leader ==
    \A t, u \in ndbg_22_1_1__tier :
        (ndbg_22_1_2__leader = t /\ ndbg_22_1_2__leader = u) => t = u

\* @derives [NDBG.22.2.3]
\* The skew bound. A follower that has paused crossed exactly one pump boundary
\* since the request, so the leader/follower skew never exceeds one cycle. A
\* follower that could not is "unresponsive", never "paused".
ndbg_22_2_3__skew_bounded ==
    \A t \in ndbg_22_1_1__tier :
        (ndbg_22_2_2__state[t] = "paused" /\ ndbg_22_1_2__leader # t)
            => ndbg_22_2_3__boundaries[t] <= 1

\* @derives [NDBG.22.3.1]
\* A follower timeout does not disturb the leader. Once elected, the leader is
\* paused and stays paused whatever becomes of the rest of the group.
ndbg_22_3_1__leader_unaffected ==
    \A t \in ndbg_22_1_1__tier :
        ndbg_22_1_2__leader = t => ndbg_22_2_2__state[t] = "paused"

\* @derives [NDBG.22.3.1]
\* No follower waits forever. Every pending tier eventually pauses or is marked
\* unresponsive -- the `pause pending` indicator always clears.
ndbg_22_3_1__every_follower_settles ==
    \A t \in ndbg_22_1_1__tier :
        (ndbg_22_2_2__state[t] = "pause_pending")
            ~> (ndbg_22_2_2__state[t] \in { "paused", "unresponsive" })

\* PROBES. `leader_unaffected` is tied for a follower that
\* TIMES OUT, and holds of a model in which none does; `skew_bounded` is about
\* a follower that pauses, and holds of one in which none does. And the comment
\* on `ResumeGroup` says every property is checked across repeated pause
\* events, which is true only if a second one is reached. Each definition
\* below says one of these never happens; its `.probe.` config runs THIS
\* engine, with the constants of tier_pause_skew.cfg, and
\* scripts/formal/check_tla.py requires TLC to end in a violation.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no follower is ever unresponsive while another
\* is paused. The run that breaks it is the interleaving the config keeps three
\* tiers for: a breakpoint stops one, a second reaches its boundary and pauses,
\* and the third stalls to its timeout, with the leader still paused.
probe__a_timeout_and_a_pause_never_meet ==
    ~( \E t, u \in ndbg_22_1_1__tier :
         /\ ndbg_22_2_2__state[t] = "unresponsive"
         /\ ndbg_22_2_2__state[u] = "paused"
         /\ ndbg_22_1_2__leader # u
         /\ ndbg_22_1_2__leader # "none" )

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: once a leader has been released, none is
\* elected again. The run that breaks it is a group that pauses, settles, is
\* resumed, and pauses a second time.
probe__one_pause_event_only ==
    []( ndbg_22_1_2__leader # "none"
          => []( ndbg_22_1_2__leader = "none"
                   => [](ndbg_22_1_2__leader = "none") ) )

=============================================================================

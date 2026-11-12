------------------------------ MODULE series_window ------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* THE SERIES WINDOW -- WHICH SAMPLES A READ SEES, AND WHEN, as a SAFETY   *)
(* spec (TLA+ / TLC). A series absorbs samples at the engine's monotonic   *)
(* clock ([LTIM.2.8.2]); a read at `t` is over the samples its time model  *)
(* admits ([LSER.14.1]): all of them under `all_time`, those in the        *)
(* half-open window `(t - W, t]` under `sliding W` ([LSIG.2.2.4]), the     *)
(* reservoir's bag under `sample n` ([LSMP.2.1]). Here a `sliding` backing *)
(* evicts at an absorption and a query discounts what is left out, as of   *)
(* `t`: one of the places [LSIG.2.5.1] lets an engine evict, and the same  *)
(* answer as an eviction at the query would give. A read is cold when the  *)
(* window holds no                                                         *)
(* sample ([LSER.19.8]). A rising edge is the absorption of a `true` while *)
(* the slot holds `false`, and the slot holds nothing before its first     *)
(* absorption ([LSIG.1.4.1]); `onset_rate` divides by min(W, elapsed)      *)
(* ([LSIG.1.4.2]), elapsed being the time since `t_first` ([LSER.19.7]).   *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the .als models,   *)
(* machine-checked by the spec gate's crossref: every operator / VARIABLE  *)
(* / CONSTANT is named <lowercased-clause-id>__<Tag> after the paragraph   *)
(* it formalizes, and the tag line above it repeats the clause so the      *)
(* checker confirms the id exists AND matches.                             *)
(*                                                                         *)
(* WHAT IS MODELLED. One series instance over a Bool slot. The clock       *)
(* moves forward by any amount at any time. An ABSORPTION records a        *)
(* sample at the clock, in arrival order, and the backing evicts what the  *)
(* absorption's own window has left behind (`sliding`), keeps everything   *)
(* (`all_time`), or fills a slot of the bag and, past n, replaces one slot *)
(* or discards the sample -- which one the generator decides, and this     *)
(* model leaves open, so every choice is explored. A READ at the clock     *)
(* records what the engine answers: the samples seen, whether the read is  *)
(* cold, and `onset_rate`'s denominator. Every sample ever absorbed is     *)
(* kept beside the backing as the ground truth the clauses are stated      *)
(* over, and the slot's held value is read off it.                         *)
(*                                                                         *)
(* THE GUARANTEE, in the clause's engine:                                  *)
(*   read_sees_the_window      a read at t sees exactly the samples the    *)
(*                             clause admits at t: every one under         *)
(*                             `all_time`; those with t - W < ts <= t under *)
(*                             `sliding`, a sample exactly W old outside;  *)
(*                             under `sample`, min(absorbed, n) of them,   *)
(*                             and every one while the bag is not full     *)
(*   eviction_keeps_the_window no sample inside the window at the clock    *)
(*                             has been evicted; the bag is never short    *)
(*   cold_iff_empty            a read is cold exactly when it sees nothing *)
(*   edges_are_transitions     the edges counted are exactly the           *)
(*                             absorptions of `true` after a `false`; a    *)
(*                             first `true` is none                        *)
(*   edges_share_the_sample_window                                         *)
(*                             the edges a read counts in its window are   *)
(*                             the edges among the samples it sees         *)
(*   denominator_is_elapsed_before_W                                       *)
(*                             the denominator is 0 while no time has      *)
(*                             elapsed, elapsed until W has, then W        *)
(*                                                                         *)
(* NOT MODELLED HERE, each stated so that a green is read for what it is:  *)
(* the pump ([LSER.8.6]) -- an absorption is one event at the clock and a  *)
(* read another, so the pre-sample snapshot a rule reads is outside this   *)
(* model; `capacity` ([LSER.13.14]), which the conformance corpus pins;    *)
(* `tumbling`, refused in this edition ([LSER.14.4.5]); the values the     *)
(* aggregations compute, which the clause-literal references compute and   *)
(* this model never does -- a read here is a set of samples; the           *)
(* reservoir's generator ([LSMP.2.1]), left as a free choice; several      *)
(* identities, which share nothing; the wall clock.                        *)
(*                                                                         *)
(* BOUNDS. MAXCLOCK instants, MAXABSORB absorptions, a width W and a bag   *)
(* of N, set in the configs and stated there. The model refutes within     *)
(* that scope and no further: a behaviour needing more absorptions than    *)
(* MAXABSORB, or a silence longer than MAXCLOCK, is not explored.          *)
(*                                                                         *)
(* SIX THINGS THE CLAUSES DECIDE, each a constant whose other value is an  *)
(* engine the clauses rule out, run as TEETH on every lane run (one config *)
(* each; TLC must report the violation):                                   *)
(*   .teeth.closed      LEFT = "closed": a sample exactly W old is inside  *)
(*                      the window; read_sees_the_window fails             *)
(*   .teeth.stale       READ = "stored": a query answers the stored        *)
(*                      samples with no discount, so after a silence it    *)
(*                      sees samples the window has left; the same fails   *)
(*   .teeth.newest      EVICT = "newest": an absorption keeps only the     *)
(*                      sample absorbed; eviction_keeps_the_window fails   *)
(*   .teeth.first_true  BEFORE = "false": the slot holds `false` before    *)
(*                      its first absorption, so a first `true` is an      *)
(*                      edge; edges_are_transitions fails                  *)
(*   .teeth.edge_closed EDGE_LEFT = "closed": an edge exactly W old is     *)
(*                      counted while its sample is not seen;              *)
(*                      edges_share_the_sample_window fails                *)
(*   .teeth.held        COLD = "never_warm": a read is cold only before    *)
(*                      the first absorption, the step function's rule     *)
(*                      applied to a windowed aggregation; cold_iff_empty  *)
(*                      fails                                              *)
(*   .teeth.full_window DENOM = "window": the denominator is W from the    *)
(*                      first sample; denominator_is_elapsed_before_W      *)
(*                      fails                                              *)
(*                                                                         *)
(* THE CLAUSE'S BEHAVIOUR IS SEEN TO HAPPEN (probes, the clause's engine): *)
(*   .probe.boundary    a sample is exactly W old at a read, so the        *)
(*                      half-open boundary is reached, not assumed         *)
(*   .probe.two_colds   a windowed read goes cold after the first          *)
(*                      absorption, where a step aggregation's would not   *)
(*   .probe.warmup      the denominator is below W during warm-up          *)
(*                                                                         *)
(* SCOPES. series_window.cfg runs `sliding`; .scope.all_time and           *)
(* .scope.sample run the same checks under the other two time models.     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

\* @spec [LSER.14.1]
\* The time model under check: "all_time", "sliding" or "sample".
CONSTANT lser_14_1__MODEL

\* @spec [LSER.14.1]
\* The sliding window's width, in clock units.
CONSTANT lser_14_1__W

\* @spec [LSMP.2.1]
\* The reservoir's size, n.
CONSTANT lsmp_2_1__N

\* @spec [LTIM.2.8.2]
\* The monotonic clock's horizon.
CONSTANT ltim_2_8_2__MAXCLOCK

\* @spec [LSER.14.1]
\* How many samples may be absorbed.
CONSTANT lser_14_1__MAXABSORB

\* @spec [LSIG.2.2.4]
\* The window's left boundary as the engine applies it to a sample: "open",
\* the clause's `(t - W, t]`, or "closed", `[t - W, t]`.
CONSTANT lsig_2_2_4__LEFT

\* @spec [LSIG.2.2.4]
\* The same boundary as the engine applies it to a rising edge's instant.
CONSTANT lsig_2_2_4__EDGE_LEFT

\* @spec [LSIG.2.5.1]
\* What a query returns: "discounts", the stored samples less the portion the
\* window has left as of the clock, or "stored", the stored samples as they
\* stand.
CONSTANT lsig_2_5_1__READ

\* @spec [LSIG.2.5.1]
\* What an absorption evicts under `sliding`: "window", the samples the
\* absorption's own window has left behind, or "newest", every sample but the
\* one absorbed.
CONSTANT lsig_2_5_1__EVICT

\* @spec [LSIG.1.4.1]
\* What the slot holds before its first absorption: "nothing", or "false".
CONSTANT lsig_1_4_1__BEFORE

\* @spec [LSER.19.8]
\* When a read is cold: "empty", when it sees no sample, or "never_warm", only
\* before the first absorption.
CONSTANT lser_19_8__COLD

\* @spec [LSIG.1.4.2]
\* `onset_rate`'s denominator: "min", min(W, elapsed), or "window", W.
CONSTANT lsig_1_4_2__DENOM

\* @spec [LTIM.2.8.2]
\* The monotonic clock's sample.
VARIABLE ltim_2_8_2__clock

\* @spec [LSER.14.1]
\* Every sample absorbed, in arrival order: records [t |-> instant, v |-> value].
\* The ground truth the clauses are stated over; it only grows.
VARIABLE lser_14_1__absorbed

\* @spec [LSIG.2.5.1]
\* The backing's stored samples, as indices into the absorbed sequence.
VARIABLE lsig_2_5_1__stored

\* @spec [LSIG.1.4.1]
\* The absorptions the engine counted as rising edges, as indices.
VARIABLE lsig_1_4_1__edges

\* @spec [LSER.19.8]
\* The last read: whether one was made, the clock it was made at, how many
\* samples had been absorbed, the samples seen, whether it was cold, and the
\* denominator `onset_rate` would divide by.
VARIABLE lser_19_8__read

\* @spec [LSER.14.1]
\* The state tuple.
lser_14_1__vars ==
    << ltim_2_8_2__clock, lser_14_1__absorbed, lsig_2_5_1__stored,
       lsig_1_4_1__edges, lser_19_8__read >>

\* @spec [LSER.14.1]
\* The samples absorbed so far.
lser_14_1__count == Len(lser_14_1__absorbed)

\* @spec [LSIG.2.2.4]
\* The clause's window: an instant ts is inside the window read at t when
\* t - W < ts <= t. Written without a subtraction so that it holds over Nat.
lsig_2_2_4__admits(ts, t) ==
    /\ ts + lser_14_1__W > t
    /\ ts <= t

\* @spec [LSIG.2.2.4]
\* The window as the engine applies it to a sample, by LEFT.
lsig_2_2_4__engine_admits(ts, t) ==
    IF lsig_2_2_4__LEFT = "open"
    THEN lsig_2_2_4__admits(ts, t)
    ELSE ts + lser_14_1__W >= t /\ ts <= t

\* @spec [LSIG.2.2.4]
\* The window as the engine applies it to an edge's instant, by EDGE_LEFT.
lsig_2_2_4__engine_admits_edge(ts, t) ==
    IF lsig_2_2_4__EDGE_LEFT = "open"
    THEN lsig_2_2_4__admits(ts, t)
    ELSE ts + lser_14_1__W >= t /\ ts <= t

\* @spec [LSIG.1.4.1]
\* What the slot holds: the value it last absorbed, through any silence and
\* whatever the window has discarded; before its first absorption, nothing --
\* or `false`, in the engine BEFORE selects.
lsig_1_4_1__holds ==
    IF lser_14_1__count = 0
    THEN IF lsig_1_4_1__BEFORE = "false" THEN "false" ELSE "none"
    ELSE lser_14_1__absorbed[lser_14_1__count].v

\* @spec [LSIG.1.4.2]
\* The lesser of two naturals.
lsig_1_4_2__min(a, b) == IF a < b THEN a ELSE b

\* @spec [LSER.19.7]
\* `t_first`: the instant of the first sample absorbed. Read only when one has
\* been.
lser_19_7__t_first == lser_14_1__absorbed[1].t

\* @spec [LSIG.1.4.2]
\* `onset_rate`'s denominator at a read at t, for an instance that has absorbed:
\* 0 while elapsed is 0, else min(W, elapsed) -- or W, in the engine DENOM
\* selects.
lsig_1_4_2__denominator(t) ==
    LET e == t - lser_19_7__t_first
    IN  IF lsig_1_4_2__DENOM = "window" THEN lser_14_1__W
        ELSE IF e = 0 THEN 0
        ELSE lsig_1_4_2__min(lser_14_1__W, e)

\* @spec [LSER.19.8]
\* No read made yet.
lser_19_8__no_read ==
    [made |-> FALSE, at |-> 0, upto |-> 0, seen |-> {}, cold |-> TRUE,
     denom |-> 0]

\* @spec [LSER.14.1]
\* Nothing absorbed, nothing stored, no edge, no read; the clock at its zero,
\* which the model places at 0 since every instant here is read relative to
\* another.
lser_14_1__Init ==
    /\ ltim_2_8_2__clock = 0
    /\ lser_14_1__absorbed = << >>
    /\ lsig_2_5_1__stored = {}
    /\ lsig_1_4_1__edges = {}
    /\ lser_19_8__read = lser_19_8__no_read

\* @spec [LTIM.2.8.2]
\* The monotonic clock moves forward, by any amount, at any time.
ltim_2_8_2__Tick ==
    /\ \E c \in (ltim_2_8_2__clock + 1)..ltim_2_8_2__MAXCLOCK :
         ltim_2_8_2__clock' = c
    /\ UNCHANGED << lser_14_1__absorbed, lsig_2_5_1__stored, lsig_1_4_1__edges,
                    lser_19_8__read >>

\* @spec [LSMP.2.1]
\* The bags the reservoir may hold after its i-th absorption: while i <= n the
\* sample fills slot i; past n it replaces one slot or is discarded, and which
\* the generator decides -- every outcome is a bag here.
lsmp_2_1__bags_after(i) ==
    IF i <= lsmp_2_1__N
    THEN { lsig_2_5_1__stored \cup {i} }
    ELSE { lsig_2_5_1__stored }
           \cup { (lsig_2_5_1__stored \ {j}) \cup {i} : j \in lsig_2_5_1__stored }

\* @spec [LSIG.2.5.1]
\* What a `sliding` backing stores after absorbing sample i at the clock: the
\* stored samples and the new one, less those the window read at the clock
\* has left behind -- or the new one alone, in the engine EVICT selects.
lsig_2_5_1__sliding_after(i, seq) ==
    IF lsig_2_5_1__EVICT = "newest"
    THEN {i}
    ELSE { j \in lsig_2_5_1__stored \cup {i} :
             lsig_2_2_4__engine_admits(seq[j].t, ltim_2_8_2__clock) }

\* @spec [LSER.14.1]
\* A sample with value v is absorbed at the clock. The backing stores what its
\* time model keeps; the engine counts an edge when a `true` arrives while the
\* slot holds `false` ([LSIG.1.4.1]).
lser_14_1__Absorb(v) ==
    LET i   == lser_14_1__count + 1
        seq == Append(lser_14_1__absorbed, [t |-> ltim_2_8_2__clock, v |-> v])
    IN
    /\ lser_14_1__count < lser_14_1__MAXABSORB
    /\ lser_14_1__absorbed' = seq
    /\ lsig_2_5_1__stored' \in
         CASE lser_14_1__MODEL = "all_time" -> { lsig_2_5_1__stored \cup {i} }
           [] lser_14_1__MODEL = "sliding"  -> { lsig_2_5_1__sliding_after(i, seq) }
           [] OTHER                         -> lsmp_2_1__bags_after(i)
    /\ lsig_1_4_1__edges' =
         IF v = "true" /\ lsig_1_4_1__holds = "false"
         THEN lsig_1_4_1__edges \cup {i}
         ELSE lsig_1_4_1__edges
    /\ UNCHANGED << ltim_2_8_2__clock, lser_19_8__read >>

\* @spec [LSIG.2.5.1]
\* What a query at the clock returns: under `sliding`, the stored samples less
\* the portion the window has left as of the clock -- this model's query
\* discounts and leaves the store as it is, which answers as a query that evicts
\* first would -- or the stored samples as they stand, in the engine READ
\* selects; under the other models, the stored samples.
lsig_2_5_1__seen ==
    IF lser_14_1__MODEL = "sliding" /\ lsig_2_5_1__READ = "discounts"
    THEN { j \in lsig_2_5_1__stored :
             lsig_2_2_4__engine_admits(lser_14_1__absorbed[j].t, ltim_2_8_2__clock) }
    ELSE lsig_2_5_1__stored

\* @spec [LSER.19.8]
\* Whether a read that sees `seen` is cold: when it sees no sample -- or only
\* before the first absorption, in the engine COLD selects.
lser_19_8__cold_of(seen) ==
    IF lser_19_8__COLD = "empty" THEN seen = {} ELSE lser_14_1__count = 0

\* @spec [LSER.19.8]
\* The cold of `active_fraction` and `integral`: they aggregate a step
\* function, in which the last absorbed value reaches into every later window,
\* so their read is cold only before the first absorption.
lser_19_8__step_cold == lser_14_1__count = 0

\* @spec [LSER.19.8]
\* A read at the clock, recorded: what it saw, whether it was cold, and the
\* denominator `onset_rate` would divide by (0 before any absorption).
lser_19_8__Read ==
    LET seen == lsig_2_5_1__seen
    IN
    /\ lser_19_8__read' =
         [made  |-> TRUE,
          at    |-> ltim_2_8_2__clock,
          upto  |-> lser_14_1__count,
          seen  |-> seen,
          cold  |-> lser_19_8__cold_of(seen),
          denom |-> IF lser_14_1__count = 0 THEN 0
                    ELSE lsig_1_4_2__denominator(ltim_2_8_2__clock)]
    /\ UNCHANGED << ltim_2_8_2__clock, lser_14_1__absorbed, lsig_2_5_1__stored,
                    lsig_1_4_1__edges >>

\* @spec [LSER.14.1]
\* The horizon is reached -- an explicit terminal stutter, not a TLC deadlock.
lser_14_1__Idle ==
    /\ ltim_2_8_2__clock = ltim_2_8_2__MAXCLOCK
    /\ lser_14_1__count = lser_14_1__MAXABSORB
    /\ UNCHANGED lser_14_1__vars

\* @spec [LSER.14.1]
\* Next: the clock moves, a sample is absorbed, a read is made.
lser_14_1__Next ==
    \/ ltim_2_8_2__Tick
    \/ lser_14_1__Absorb("true")
    \/ lser_14_1__Absorb("false")
    \/ lser_19_8__Read
    \/ lser_14_1__Idle

\* @spec [LSER.14.1]
\* The behavior spec. A SAFETY model: no fairness is needed.
lser_14_1__Spec ==
    lser_14_1__Init /\ [][lser_14_1__Next]_lser_14_1__vars

\* @spec [LSER.14.1]
\* Type-correctness -- a state invariant true at every reachable state.
lser_14_1__TypeOK ==
    /\ ltim_2_8_2__clock \in 0..ltim_2_8_2__MAXCLOCK
    /\ lser_14_1__absorbed \in
         Seq([t : 0..ltim_2_8_2__MAXCLOCK, v : {"true", "false"}])
    /\ lser_14_1__count <= lser_14_1__MAXABSORB
    /\ lsig_2_5_1__stored \subseteq 1..lser_14_1__count
    /\ lsig_1_4_1__edges \subseteq 1..lser_14_1__count
    /\ lser_19_8__read.made \in BOOLEAN
    /\ lser_19_8__read.at \in 0..ltim_2_8_2__MAXCLOCK
    /\ lser_19_8__read.upto \in 0..lser_14_1__count
    /\ lser_19_8__read.seen \subseteq 1..lser_19_8__read.upto
    /\ lser_19_8__read.cold \in BOOLEAN
    /\ lser_19_8__read.denom \in 0..lser_14_1__W
    /\ lser_14_1__MODEL \in { "all_time", "sliding", "sample" }
    /\ lsig_2_2_4__LEFT \in { "open", "closed" }
    /\ lsig_2_2_4__EDGE_LEFT \in { "open", "closed" }
    /\ lsig_2_5_1__READ \in { "discounts", "stored" }
    /\ lsig_2_5_1__EVICT \in { "window", "newest" }
    /\ lsig_1_4_1__BEFORE \in { "nothing", "false" }
    /\ lser_19_8__COLD \in { "empty", "never_warm" }
    /\ lsig_1_4_2__DENOM \in { "min", "window" }

\* @derives [LSER.14.1]
\* A READ SEES THE WINDOW (safety): a read made at t over the first `upto`
\* samples saw exactly what the clause admits at t -- every sample under
\* `all_time`; under `sliding`, those with t - W < ts <= t, so a sample exactly
\* W old is outside; under `sample`, min(upto, n) of them, and every one while
\* the bag is not full ([LSER.19.8], [LSMP.2.1]). Which n the bag holds past
\* that is the generator's, and not stated. NO counterexample. Nothing outside
\* the window survives a read: that is the `sliding` equality's other half.
lser_14_1__read_sees_the_window ==
    LET r      == lser_19_8__read
        clause == { i \in 1..r.upto :
                      lsig_2_2_4__admits(lser_14_1__absorbed[i].t, r.at) }
    IN  r.made =>
          CASE lser_14_1__MODEL = "all_time" -> r.seen = 1..r.upto
            [] lser_14_1__MODEL = "sliding"  -> r.seen = clause
            [] OTHER ->
                 /\ r.seen \subseteq 1..r.upto
                 /\ Cardinality(r.seen) = lsig_1_4_2__min(r.upto, lsmp_2_1__N)
                 /\ (r.upto <= lsmp_2_1__N => r.seen = 1..r.upto)

\* @derives [LSIG.2.5.1]
\* EVICTION KEEPS THE WINDOW (safety): under `sliding`, every absorbed sample
\* inside the window read at the clock is still stored -- eviction, driven by
\* absorptions, has removed only what no later window can admit; under
\* `all_time` everything is stored; under `sample` the bag is never short of
\* min(absorbed, n), and holds every sample while it is not full. NO
\* counterexample.
lsig_2_5_1__eviction_keeps_the_window ==
    CASE lser_14_1__MODEL = "all_time" -> lsig_2_5_1__stored = 1..lser_14_1__count
      [] lser_14_1__MODEL = "sliding" ->
           \A i \in 1..lser_14_1__count :
             lsig_2_2_4__admits(lser_14_1__absorbed[i].t, ltim_2_8_2__clock)
               => i \in lsig_2_5_1__stored
      [] OTHER ->
           /\ lsig_2_5_1__stored \subseteq 1..lser_14_1__count
           /\ Cardinality(lsig_2_5_1__stored)
                = lsig_1_4_2__min(lser_14_1__count, lsmp_2_1__N)
           /\ (lser_14_1__count <= lsmp_2_1__N
                 => lsig_2_5_1__stored = 1..lser_14_1__count)

\* @derives [LSER.19.8]
\* COLD IFF EMPTY (safety): a read is cold exactly when it saw no sample --
\* before the first absorption, and once every absorbed sample has left the
\* window. The clause's definition in the model's terms; its teeth is the step
\* function's rule applied to a windowed aggregation. NO counterexample.
lser_19_8__cold_iff_empty ==
    lser_19_8__read.made => (lser_19_8__read.cold <=> lser_19_8__read.seen = {})

\* @spec [LSIG.1.4.1]
\* The rising edges the clause defines, read off the ground truth: the
\* absorptions of a `true` whose predecessor is a `false`. The first sample
\* has no predecessor and the slot held nothing, which is not `false`.
lsig_1_4_1__transitions ==
    { i \in 1..lser_14_1__count :
        /\ lser_14_1__absorbed[i].v = "true"
        /\ i > 1
        /\ lser_14_1__absorbed[i - 1].v = "false" }

\* @derives [LSIG.1.4.1]
\* EDGES ARE TRANSITIONS (safety): the edges the engine counted are exactly the
\* clause's, so an edge is counted once per `false`-to-`true` transition, a
\* `true` after a `true` is none, and a first `true` is none. NO
\* counterexample.
lsig_1_4_1__edges_are_transitions ==
    lsig_1_4_1__edges = lsig_1_4_1__transitions

\* @derives [LSIG.2.2.4]
\* EDGES SHARE THE SAMPLE WINDOW (safety): under `sliding`, the edges a read
\* counts -- those whose instant the edge window admits at the read -- are the
\* edges among the samples the read saw, so N+(t, W) and the window compose
\* over identical bounds. NO counterexample.
lsig_2_2_4__edges_share_the_sample_window ==
    LET r       == lser_19_8__read
        counted == { i \in lsig_1_4_1__edges :
                       /\ i <= r.upto
                       /\ lsig_2_2_4__engine_admits_edge(lser_14_1__absorbed[i].t, r.at) }
    IN  r.made /\ lser_14_1__MODEL = "sliding"
          => counted = lsig_1_4_1__edges \cap r.seen

\* @derives [LSIG.1.4.2]
\* THE DENOMINATOR IS ELAPSED BEFORE W (safety): at a read made after the first
\* absorption, the denominator is 0 while no time has elapsed since `t_first`,
\* the elapsed time until W of it has passed, and W from then on. The quotient
\* itself is not computed here. NO counterexample.
lsig_1_4_2__denominator_is_elapsed_before_W ==
    LET r == lser_19_8__read
        e == r.at - lser_19_7__t_first
    IN  r.made /\ r.upto > 0 =>
          /\ (e = 0 => r.denom = 0)
          /\ (0 < e /\ e < lser_14_1__W => r.denom = e)
          /\ (e >= lser_14_1__W => r.denom = lser_14_1__W)

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: it says no sample is ever exactly W old at a
\* read. FALSE of the clause's engine, and series_window.probe.boundary.cfg
\* requires TLC to say so: the behaviour it returns is the boundary case the
\* half-open window decides, so .teeth.closed fails for the reason its comment
\* gives and not for another ([LSIG.2.2.4]).
probe__no_sample_is_exactly_W_old_at_a_read ==
    lser_19_8__read.made =>
      \A i \in 1..lser_19_8__read.upto :
        lser_14_1__absorbed[i].t + lser_14_1__W # lser_19_8__read.at

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: it says a windowed read is cold exactly when a
\* step aggregation's would be. FALSE of the clause's engine, and
\* series_window.probe.two_colds.cfg requires TLC to say so: after a silence
\* of W the windowed read is cold while the instance has absorbed, which is
\* the exception [LSER.19.8] carves out for `active_fraction` and `integral`.
probe__the_two_colds_agree ==
    lser_19_8__read.made /\ lser_19_8__read.upto = lser_14_1__count
      => (lser_19_8__read.cold <=> lser_19_8__step_cold)

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: it says the denominator is W whenever time has
\* elapsed. FALSE of the clause's engine, and series_window.probe.warmup.cfg
\* requires TLC to say so: during the instance's first W the denominator is the
\* elapsed time, the warm-up correction [LSIG.1.4.2] states.
probe__the_denominator_is_the_window ==
    lser_19_8__read.made /\ lser_19_8__read.upto > 0
      /\ lser_19_8__read.at > lser_19_7__t_first
      => lser_19_8__read.denom = lser_14_1__W

=============================================================================

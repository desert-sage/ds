/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS derivation graph — support is acyclic on every admitted program (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lcyc_3_1_1__<tag>):
 *      <lowercased-clause-id>__<snake_tag>, e.g. `rarc_5_6_6__firing` formalizes
 *      [RARC.5.6.6]. A satisfiability probe (tied to no clause) carries the
 *      `probe__` marker instead.
 *   2. TAG. The line above each element repeats the clause in bracket form so
 *      the checker can confirm the id exists in the normative tree AND matches
 *      the name:
 *        //@spec [ID]      — this element formalizes normative clause [ID] (1:1).
 *        //@derives [ID]   — this check proves a consequence of [ID].
 *        //@probe          — a satisfiability/consistency probe, tied to no clause.
 *
 * THE INVARIANT. [IRET.12.2]: "on every program [LCYC.3.1.1] admits, support is
 * acyclic -- no SCC both emits and matches a schema -- so a count of live
 * justifications decides it." This model derives the first half from the
 * second. Rules read and emit kinds ([LCYC.3.2.1]; [LCYC.3.2.2]'s emit edge);
 * a firing matches facts of the kinds its rule reads and produces facts of
 * the kinds it emits ([RARC.5.6.6]); support is fact -> firing -> fact,
 * collapsed. Under condition (a) of [LCYC.3.1.1] -- no kind both emitted by a
 * rule of an SCC and matched by a rule of the same SCC -- no fact lies in its
 * own ancestor cone. The argument, in the three checks below:
 *   1. the kind graph is acyclic (`lcyc_3_1_1__admitted_kind_graph_acyclic`,
 *      scope 6): a kind cycle k1 -> ... -> kn -> k1 names rules r1..rn with ri
 *      reading ki and emitting ki+1, so ri -> ri+1 and rn -> r1 are rule edges,
 *      the ri share one SCC, and k1 is emitted by rn and read by r1 inside it;
 *   2. support projects onto the kind graph
 *      (`rarc_5_6_6__derives_projects_onto_kinds`, scope 6): a support edge
 *      between two facts is a kind edge between their kinds, by the firing's
 *      rule, so a fact cycle is a closed walk of kinds -- a kind in its own
 *      closure -- which 1 excludes;
 *   3. the conclusion itself, directly (`iret_12_2__admitted_support_acyclic`,
 *      scope 4): no fact in its own ancestor cone. 1 and 2 together are the
 *      proof at scope 6; 3 is the statement executed where SAT4J proves it in
 *      seconds -- the closure over facts through firings is what makes the
 *      direct check slow at a larger scope, and 1 and 2 are what carry it there.
 *
 * THE WITHDRAW EDGE IS DRAWN: `lcyc_3_2_2__withdraw_edge`,
 * the clause's fourth and fifth forms, which no literal breaks, and
 * `lcyc_3_2_2__graph` is the emit and withdraw edges together -- the graph
 * `dsc.cycle` takes its SCCs over. `lcyc_3_1_1__admitted_graph` is condition
 * (a) over those SCCs; check 4 proves it implies `lcyc_3_1_1__admitted` (the
 * emit-edge SCCs only coarsen), so checks 1 and 3 hold of what the compiler
 * admits; check 5 proves the clause's last sentence, that every internal edge
 * of an admitted SCC is a withdraw edge.
 *
 * WHAT IS NOT DRAWN, and why the checks survive it. The call and cache edge
 * forms of [LCYC.3.2.2]: each adds edges, so the full graph's SCCs are unions
 * of the SCCs here, and a program admitted over the full graph is admitted
 * here -- the argument check 4 makes for the withdraw form, kept as an
 * argument for these two. Conditions (b) and (c) of [LCYC.3.1.1]
 * (`call` / `cache` / `cache_delete`; `latest` / `then`): they only restrict
 * further. Literal precision ([LCYC.6.1], cycle_detection.als) DROPS edges,
 * which is the other direction: a program admitted only because the break
 * dropped an edge is NOT admitted here, and the Idris termination certificate,
 * kind-level like this model, does not cover it either. Over positive matches the support
 * relation is [IRET.12.4]'s
 * justification, antecedent to target; a `no` match binds nothing and
 * justifies nothing, so counting it widens the relation, and acyclicity of
 * the wider relation is acyclicity of the narrower.
 *
 * TEETH: the admission condition is load-bearing. `probe__unadmitted_cycle`
 * is SAT -- one rule that reads and emits the same kind puts a fact in its own
 * ancestor cone -- so dropping `lcyc_3_1_1__admitted` from the antecedent of
 * check 1 or check 3 makes it fail with that instance. For check 5, make
 * `lcyc_3_1_1__admitted_graph` test `some a.emits & b.emits` (emitted twice)
 * instead of `some a.emits & b.reads` (emitted and read): a two-rule emit
 * cycle over two kinds is then admitted with an emit edge inside, and the
 * check fails with it. Check 4 rests on the SCCs of the drawn graph being
 * coarser than the emit-edge SCCs, which adding edges guarantees whatever the
 * edges are, so its teeth are the antecedent alone; what it is for is to make
 * the header's argument a checked one. `probe__withdraw_scc_admitted` is what
 * shows the admission over the drawn graph admits a cycle at all.
 */
module ds/derivation_graph

//@spec [LCYC.3.2.2]
// A fact schema (kind): what `emit X` writes and an `X` pattern, positive or
// under `no`, reads.
sig lcyc_3_2_2__kind {}

//@spec [LCYC.3.2.1]
// A rule: the kinds its LHS matches -- positive and `no` alike, since
// [LCYC.3.1.1] counts both -- and the kinds its RHS emits.
sig lcyc_3_2_1__rule {
  reads:     set lcyc_3_2_2__kind,
  emits:     set lcyc_3_2_2__kind,
  withdraws: set lcyc_3_2_2__kind
} {
  // `withdraw <binding>` names a bound positive pattern, so a withdrawn kind
  // is one the rule reads.
  withdraws in reads
}

//@spec [LCYC.3.2.2]
// The emit edge, the clause's first form: A -> B when A emits a kind B matches.
fun lcyc_3_2_2__edge : lcyc_3_2_1__rule -> lcyc_3_2_1__rule {
  { a, b: lcyc_3_2_1__rule | some a.emits & b.reads }
}

//@derives [LCYC.3.2.2]
// The emit edge lifted to kinds: k1 -> k2 when some rule matches k1 and emits k2.
fun lcyc_3_2_2__kind_edge : lcyc_3_2_2__kind -> lcyc_3_2_2__kind {
  { k1, k2: lcyc_3_2_2__kind | some r: lcyc_3_2_1__rule | k1 in r.reads and k2 in r.emits }
}

//@spec [LCYC.3.2.2]
// The withdraw edge, the clause's fourth and fifth forms: A -> B when A
// withdraws a kind B matches, positively or under `no`. Never broken by
// [LCYC.6.1]: a withdraw carries no slot value to compare (dsc.cycle).
fun lcyc_3_2_2__withdraw_edge : lcyc_3_2_1__rule -> lcyc_3_2_1__rule {
  { a, b: lcyc_3_2_1__rule | some a.withdraws & b.reads }
}

//@derives [LCYC.3.2.2]
// The drawn forms together -- the graph the compiler's SCCs are over: emit
// and withdraw edges. The call and cache forms are not drawn.
fun lcyc_3_2_2__graph : lcyc_3_2_1__rule -> lcyc_3_2_1__rule {
  lcyc_3_2_2__edge + lcyc_3_2_2__withdraw_edge
}

//@spec [LCYC.3.1.1]
// Two rules of one SCC of the emit-edge graph: each reaches the other, or
// they are one rule.
pred lcyc_3_1_1__same_scc [a, b: lcyc_3_2_1__rule] {
  a = b or (b in a.^lcyc_3_2_2__edge and a in b.^lcyc_3_2_2__edge)
}

//@spec [LCYC.3.1.1]
// THE ADMISSION, condition (a), over emit-edge SCCs: no kind is both emitted
// by a rule of an SCC and matched by a rule of the same SCC. (Conditions (b)
// and (c) are not drawn.) The compiler's SCCs are the drawn graph's, below.
pred lcyc_3_1_1__admitted {
  no a, b: lcyc_3_2_1__rule | lcyc_3_1_1__same_scc[a, b] and some a.emits & b.reads
}

//@spec [LCYC.3.1.1]
// Two rules of one SCC of the drawn graph -- the compiler's SCC (dsc.cycle,
// `refused_sccs`): each reaches the other through emit or withdraw edges, or
// they are one rule.
pred lcyc_3_1_1__same_scc_graph [a, b: lcyc_3_2_1__rule] {
  a = b or (b in a.^lcyc_3_2_2__graph and a in b.^lcyc_3_2_2__graph)
}

//@spec [LCYC.3.1.1]
// THE ADMISSION over the compiler's SCCs: condition (a) with the SCCs of the
// drawn graph, as `dsc.cycle.lcyc_3_1_1_admitted` tests it over schemas.
pred lcyc_3_1_1__admitted_graph {
  no a, b: lcyc_3_2_1__rule | lcyc_3_1_1__same_scc_graph[a, b] and some a.emits & b.reads
}

//@spec [IDAT.4.3]
// A fact, of one kind. Its identity (schema + slot tuple) and its `fact_id`
// are not drawn: the graph below reads only the kind.
sig idat_4_3__fact { kind: one lcyc_3_2_2__kind }

//@spec [RARC.5.6.6]
// A rule firing (the conflict resolver firing an activation): its rule, the
// facts it matched -- of kinds the rule reads -- and the facts it produced --
// of kinds the rule emits.
sig rarc_5_6_6__firing {
  rule:    one lcyc_3_2_1__rule,
  inputs:  set idat_4_3__fact,
  outputs: set idat_4_3__fact
} {
  inputs.kind in rule.reads
  outputs.kind in rule.emits
}

//@derives [RARC.5.6.6]
// Support: A -> B when some firing matched A and produced B (input-fact ->
// firing -> output-fact, collapsed to fact -> fact).
fun rarc_5_6_6__derives : idat_4_3__fact -> idat_4_3__fact {
  { a, b: idat_4_3__fact | some f: rarc_5_6_6__firing | a in f.inputs and b in f.outputs }
}

//@probe
// An admitted program with a rule edge and a derivation is satisfiable: the
// admission admits something.
run probe__consistent {
  lcyc_3_1_1__admitted and some lcyc_3_2_2__edge and some rarc_5_6_6__derives
} for 5

//@probe
// WITHOUT THE ADMISSION a support cycle is reachable: a rule that reads and
// emits one kind, two facts of it, each produced from the other. The TEETH.
run probe__unadmitted_cycle {
  not lcyc_3_1_1__admitted and some f: idat_4_3__fact | f in f.^rarc_5_6_6__derives
} for 5

// 1. THE KIND GRAPH IS ACYCLIC ON EVERY ADMITTED PROGRAM: rules and kinds
// alone. NO counterexample.
assert lcyc_3_1_1__admitted_kind_graph_acyclic {
  lcyc_3_1_1__admitted implies no k: lcyc_3_2_2__kind | k in k.^lcyc_3_2_2__kind_edge
}
//@derives [LCYC.3.1.1]
check lcyc_3_1_1__admitted_kind_graph_acyclic for 6

// 2. SUPPORT PROJECTS ONTO THE KIND GRAPH: a support edge between two facts is
// a kind edge between their kinds, by the firing's rule. No closure. NO
// counterexample.
assert rarc_5_6_6__derives_projects_onto_kinds {
  all a, b: idat_4_3__fact |
    a -> b in rarc_5_6_6__derives implies a.kind -> b.kind in lcyc_3_2_2__kind_edge
}
//@derives [RARC.5.6.6]
check rarc_5_6_6__derives_projects_onto_kinds for 6

// 3. SUPPORT IS ACYCLIC ON EVERY ADMITTED PROGRAM: [IRET.12.2]'s sentence,
// derived from condition (a) of [LCYC.3.1.1] alone -- no fact lies in its own
// ancestor cone, so backward unfolding terminates at base facts and a count of
// live justifications is exact (Rete/Refcount.idr, iret_12_3__ranked_agree).
// The direct statement, at the scope SAT4J proves it in seconds; checks 1 and 2
// are its proof at scope 6. NO counterexample.
assert iret_12_2__admitted_support_acyclic {
  lcyc_3_1_1__admitted implies no f: idat_4_3__fact | f in f.^rarc_5_6_6__derives
}
//@derives [LCYC.3.1.1]
//@derives [IRET.12.2]
check iret_12_2__admitted_support_acyclic for 4

//@probe
// A WITHDRAW SCC IS ADMITTED: a rule that withdraws its own match is a
// one-rule SCC through its own withdraw edge (`X x -> withdraw x`, the verb's
// canonical use), and the admission admits it. SAT, so the admission over the
// drawn graph admits something a cycle runs through.
run probe__withdraw_scc_admitted {
  lcyc_3_1_1__admitted_graph and some a: lcyc_3_2_1__rule | a in a.^lcyc_3_2_2__graph
} for 4

// 4. THE ADMISSION OVER THE COMPILER'S SCCs IMPLIES THE ADMISSION OVER THE
// EMIT-EDGE SCCs: withdraw edges only coarsen the SCCs, so every result derived
// from `lcyc_3_1_1__admitted` (checks 1 and 3) holds of what the compiler
// admits. The header's "a program admitted over the full graph is admitted
// here", as a check for the withdraw form; the call and cache forms keep it as
// an argument. NO counterexample.
assert lcyc_3_1_1__admitted_graph_implies_admitted {
  lcyc_3_1_1__admitted_graph implies lcyc_3_1_1__admitted
}
//@derives [LCYC.3.1.1]
check lcyc_3_1_1__admitted_graph_implies_admitted for 6

// 5. THE CLAUSE'S LAST SENTENCE: "Every internal edge of an admitted SCC is
// then a `withdraw` edge." An internal emit edge is a kind emitted by one rule
// of the SCC and read by another, which the admission forbids; what remains
// inside is withdraw. NO counterexample.
assert lcyc_3_1_1__internal_edges_are_withdraw {
  lcyc_3_1_1__admitted_graph implies
    all a, b: lcyc_3_2_1__rule |
      (lcyc_3_1_1__same_scc_graph[a, b] and a -> b in lcyc_3_2_2__graph)
        implies a -> b in lcyc_3_2_2__withdraw_edge
}
//@derives [LCYC.3.1.1]
check lcyc_3_1_1__internal_edges_are_withdraw for 6

/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS rule-firing order — determinism total-order model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_ldet_5_1__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. When several activations match at one clock instant, the order
 * they fire in is a spec-defined TOTAL order ([LDET.5.1]): the terminal ordinal
 * ([LDET.5.4], which is SOURCE ORDER), then the creation timetag WITHIN ONE RULE
 * ([LDET.5.5]). This model proves the lexicographic pair is a strict TOTAL order —
 * irreflexive, transitive, total, NO ties — so the conflict resolver has exactly
 * one deterministic order.
 *
 * TWO KEYS, NOT FOUR. The priority band and refraction history were the first two
 * keys of the retired model. The band is gone with the `priority_band` grammar.
 * Refraction never belonged: it is SUPPRESSION APPLIED AFTER SELECTION
 * ([LDET.5.3]) — a refracted activation is not eligible, so it never reaches the
 * comparator and cannot be an axis of it.
 *
 * THE TIMETAG IS A FUNCTION OF THE MATCH, NOT A COUNTER ([LDET.5.5]):
 * among activations of one rule, the creation timetag is the tuple of the
 * matched facts' assertion positions, compared first by the latest position
 * and then lexicographically in pattern-declaration order. This model states
 * that key (`ldet_5_5__created_before`) and DERIVES what every earlier version
 * ASSUMED. The four-key model asserted `ldet_5_5__creation_unique` as a fact;
 * the two-key model asserted `ldet_5_5__one_activation_per_rule_per_timetag`
 * as a fact and its header admitted it was the old assumption at the right
 * granularity, one a join-sharing or CSE optimisation in the compiler could
 * void silently. It is now a CHECK, and it holds because two distinct matches
 * of one rule are two distinct tuples of facts, distinct facts hold distinct
 * assertion positions, and a lexicographic order on distinct equal-length
 * tuples of a total order is strict and total. This is the Alloy form of
 * `Rete/NetworkOrder.idr`'s `ldet_5_5__before_total` and
 * `rarc_5_4_9__unique_after_history`, which prove the same key unique over
 * every history of the network model.
 *
 * WHAT IS STILL A FACT, AND WHY EACH IS ABOUT CONSTRUCTION, NOT THE ENGINE.
 *   - `ldet_5_4__ordinal_injective`: canonical source order assigns each rule
 *     a distinct terminal ordinal (RLOW.14.3) — the compiler's emission.
 *   - `ldet_5_5__positions_are_a_sequence`: facts are asserted one at a time,
 *     so no two live facts share an assertion position — what "assertion
 *     position" means, not something an optimisation can change.
 *   - `ldet_5_5__match_is_its_tuple`: a match atom names a tuple, so two atoms
 *     with one tuple are one match — representation, so that the agenda's set
 *     semantics is set semantics over tuples.
 *   - `ldet_5_1__match_has_the_rules_arity`: a match binds one fact per
 *     positive pattern, so every match of one rule has the same index set.
 * A join-sharing or CSE pass changes which nodes COMPUTE a match; it changes
 * neither which facts the match binds nor when they were asserted, so none of
 * these is the assumption the earlier headers warned about.
 *
 * THE ACTIVATION IS A PAIR, NOT AN ATOM. An activation is (rule, match) with
 * the match on the rule's agenda, and the agenda is a SET of matches. Set
 * semantics is what gives one activation per match; the earlier model's
 * `ldet_5_1__activation` atoms could carry one (rule, timetag) twice and needed
 * a fact to forbid it. Here nothing forbids it because nothing can express it.
 *
 * TEETH, MEASURED on two host-side copies (the alloy lane run with
 * one fact's body disabled; 123/126 commands passed in one run and 124/126 in
 * the other):
 *   disable `ldet_5_5__positions_are_a_sequence` -> two facts share a position,
 *     two distinct matches share a key:
 *       check ldet_5_5__one_activation_per_rule_per_timetag  FAIL
 *       check ldet_5_1__keys_are_jointly_injective            FAIL
 *       check ldet_5_1__firing_order_is_strict_total          FAIL
 *       check ldet_5_5__created_before_is_transitive          PASS  <- a partial order still
 *       check ldet_5_4__source_order_dominates                PASS  <- control
 *   disable `ldet_5_4__ordinal_injective` -> two rules share an ordinal, and
 *     their matches are ordered by the timetag alone across rules:
 *       check ldet_5_1__keys_are_jointly_injective            FAIL
 *       check ldet_5_1__firing_order_is_strict_total          FAIL
 *       check ldet_5_5__one_activation_per_rule_per_timetag  PASS  <- within one rule
 *       check ldet_5_5__created_before_is_transitive          PASS
 *       check ldet_5_4__source_order_dominates                PASS  <- control
 * The control passing is what makes the measurement worth anything: it follows
 * from the comparator's definition alone, so a probe that broke every check
 * would say nothing about which fact carries the order.
 *
 * VERDICT. The derived check is `proven` on [LDET.5.5]: the key this model
 * states is the key the clause states.
 */
module ds/firing_order

open util/ordering[ldet_5_5__position] as posord
open util/ordering[ldet_5_4__ordinal]  as ordord

//@spec [LDET.5.5]
// An assertion position in the working-memory sequence. Facts enter one at a
// time, so the positions are totally ordered.
sig ldet_5_5__position {}

//@spec [LDET.5.5]
// A live fact, at the position it was asserted.
sig ldet_5_5__fact { pos: one ldet_5_5__position }

//@spec [LDET.5.5]
// A sequence holds one fact per position: two facts cannot share an assertion
// position, by what a sequence is. THE FACT THE OLD ASSUMPTION BECOMES — see
// the header; disabling it is the first TEETH measurement.
fact ldet_5_5__positions_are_a_sequence {
  all disj f, g: ldet_5_5__fact | f.pos != g.pos
}

//@spec [LDET.5.5]
// A match: the matched facts in pattern-declaration order. Its timetag is a
// function of this tuple and of nothing else ([LDET.5.9]).
sig ldet_5_5__match { facts: seq ldet_5_5__fact }

//@spec [LDET.5.5]
// A match atom names a tuple: two atoms with one tuple are one match.
// Representation, not an engine property.
fact ldet_5_5__match_is_its_tuple {
  all disj m, n: ldet_5_5__match | m.facts != n.facts
}

//@spec [LDET.5.4]
// The terminal ordinal: the rule's zero-based index in canonical source order.
// THE FIRST KEY — this is source order, and it is the whole of the author's control.
sig ldet_5_4__ordinal {}

//@spec [LDET.5.1]
// A rule: its terminal ordinal and its agenda — the SET of matches currently
// activating it. An activation is a (rule, match) pair with the match on the
// agenda; the ordinal is a property of the RULE, which is what makes two
// activations of one rule share it and forces the timetag to separate them.
sig ldet_5_1__rule {
  ordinal: one ldet_5_4__ordinal,
  agenda:  set ldet_5_5__match
}

//@spec [LDET.5.1]
// A match on a rule's agenda binds one fact per positive pattern: every match
// of one rule has the same, non-empty, index set. Stated on the index sets
// rather than with `#` so the solver carries no cardinality circuit.
fact ldet_5_1__match_has_the_rules_arity {
  all r: ldet_5_1__rule | all m, n: r.agenda |
    some m.facts and m.facts.inds = n.facts.inds
}

//@spec [LDET.5.4]
// The ordinal is injective on rules: canonical source order assigns each rule a
// distinct index ([RLOW.14.3]). This is a property of the compiler's emission,
// not an assumption about activations. Disabling it is the second TEETH
// measurement.
fact ldet_5_4__ordinal_injective {
  all disj r, s: ldet_5_1__rule | r.ordinal != s.ordinal
}

//@spec [LDET.5.5]
// The position a match completed at: the latest assertion among its facts.
fun ldet_5_5__completed_at [m: ldet_5_5__match] : ldet_5_5__position {
  posord/max[m.facts.elems.pos]
}

//@spec [LDET.5.5]
// Lexicographic order in pattern-declaration order: at the first index where
// two tuples differ, m's fact was asserted earlier. The first differing index
// is the minimum of the differing ones — one integer expression, no nested
// quantifier, which is what keeps the triple check below tractable.
pred ldet_5_5__lex_before [m, n: ldet_5_5__match] {
  let d = { k: m.facts.inds & n.facts.inds | m.facts[k] != n.facts[k] } |
    some d and posord/lt[m.facts[min[d]].pos, n.facts[min[d]].pos]
}

//@spec [LDET.5.5]
// THE TIMETAG ORDER: first by the position the match
// completed at, then lexicographically in pattern order. THE SECOND KEY, and
// only within one rule.
pred ldet_5_5__created_before [m, n: ldet_5_5__match] {
  posord/lt[ldet_5_5__completed_at[m], ldet_5_5__completed_at[n]]
  or (ldet_5_5__completed_at[m] = ldet_5_5__completed_at[n]
      and ldet_5_5__lex_before[m, n])
}

//@spec [LDET.5.1]
// The firing order over activations (r, m), (s, n): lexicographic by
// (ordinal, timetag).
pred ldet_5_1__fires_before [r: ldet_5_1__rule, m: ldet_5_5__match,
                             s: ldet_5_1__rule, n: ldet_5_5__match] {
  m in r.agenda and n in s.agenda
  ordord/lt[r.ordinal, s.ordinal]
    or (r.ordinal = s.ordinal and ldet_5_5__created_before[m, n])
}

//@probe
// A non-trivial agenda — several matches on one rule, several rules — is
// satisfiable.
run probe__consistent {
  some r: ldet_5_1__rule | #r.agenda >= 3
  #ldet_5_1__rule >= 2
} for 5 but 3 seq

// DERIVED, NOT ASSUMED: two distinct matches of one rule are strictly ordered
// by the timetag, so no two activations of one rule share one. This was a FACT
// in every earlier version of this model. NO counterexample.
assert ldet_5_5__one_activation_per_rule_per_timetag {
  all r: ldet_5_1__rule | all disj m, n: r.agenda |
    ldet_5_5__created_before[m, n] or ldet_5_5__created_before[n, m]
}
//@derives [LDET.5.5]
check ldet_5_5__one_activation_per_rule_per_timetag for 5 but 3 seq

// DERIVED, NOT ASSUMED: the two keys jointly separate any two distinct
// activations — different rules by the ordinal, one rule's by the timetag. NO
// counterexample.
assert ldet_5_1__keys_are_jointly_injective {
  all r, s: ldet_5_1__rule | all m: r.agenda, n: s.agenda |
    (r != s or m != n) implies
      (r.ordinal != s.ordinal
       or ldet_5_5__created_before[m, n] or ldet_5_5__created_before[n, m])
}
//@derives [LDET.5.1]
check ldet_5_1__keys_are_jointly_injective for 5 but 3 seq

// THE SECOND KEY IS TRANSITIVE within a rule, over three matches at the wide
// scope. The pair-level checks above and the triple check below are all the
// order needs; this one carries the transitivity of the timetag at the scope the
// composite check cannot afford (three activations of the composite order at
// `for 5 but 3 seq` ran past the lane's hour; the composite order's transitivity
// is checked at `for 3 but 3 seq` below and follows from this one and the
// ordinal's built-in ordering). NO counterexample.
assert ldet_5_5__created_before_is_transitive {
  all m, n, o: ldet_5_5__match |
    (m.facts.inds = n.facts.inds and n.facts.inds = o.facts.inds
     and ldet_5_5__created_before[m, n] and ldet_5_5__created_before[n, o])
      implies ldet_5_5__created_before[m, o]
}
//@derives [LDET.5.5]
check ldet_5_5__created_before_is_transitive for 5 but 3 seq

// DETERMINISM: the firing order is a strict TOTAL order — irreflexive,
// asymmetric, transitive, and total (any two distinct activations are strictly
// ordered, no ties). So the conflict resolver has one deterministic order, no
// selectable strategy. NO counterexample. Three activations, so scoped to three
// of everything; the pair-level conjuncts are re-checked at the wide scope by
// the two checks above.
assert ldet_5_1__firing_order_is_strict_total {
  all r: ldet_5_1__rule, m: r.agenda | not ldet_5_1__fires_before[r, m, r, m]
  all r, s: ldet_5_1__rule, m: r.agenda, n: s.agenda |
    ldet_5_1__fires_before[r, m, s, n] implies not ldet_5_1__fires_before[s, n, r, m]
  all r, s, t: ldet_5_1__rule, m: r.agenda, n: s.agenda, o: t.agenda |
    (ldet_5_1__fires_before[r, m, s, n] and ldet_5_1__fires_before[s, n, t, o])
      implies ldet_5_1__fires_before[r, m, t, o]
  all r, s: ldet_5_1__rule, m: r.agenda, n: s.agenda |
    (r != s or m != n) implies
      (ldet_5_1__fires_before[r, m, s, n] or ldet_5_1__fires_before[s, n, r, m])
}
//@derives [LDET.5.1]
check ldet_5_1__firing_order_is_strict_total for 3 but 3 seq

// SOURCE ORDER DOMINATES: a lower-ordinal rule's activation fires before a
// higher-ordinal rule's, whatever their timetags — the first key is first, and
// the timetag never overrides source order. NO counterexample.
assert ldet_5_4__source_order_dominates {
  all r, s: ldet_5_1__rule, m: r.agenda, n: s.agenda |
    ordord/lt[r.ordinal, s.ordinal] implies ldet_5_1__fires_before[r, m, s, n]
}
//@spec [LDET.5.4]
check ldet_5_4__source_order_dominates for 5 but 3 seq

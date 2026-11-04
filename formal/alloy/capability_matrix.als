/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS capabilities — the combination matrix of [LCAP.5], row by row (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lcap_5__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE MATRIX. [LCAP.5] takes the five settings with engine consequences for cost
 * -- `realtime`, `constspace`, `linear_scan`, `logical`, `dynamic_ttl` -- and says
 * that of their 32 combinations the 8 with `realtime: true` and
 * `constspace: false` violate [LCAP.3.7], and it lists the other 24, each with
 * seven property cells, some of them footnoted. Three things are transcribed
 * here, separately:
 *   - THE TABLE, `lcap_5__table`: each printed row, as the settings that are
 *     `true` in it, the cells that carry a tick, and the footnote each cell
 *     carries;
 *   - THE COLUMN RULES, `lcap_5__columns`: what decides each column, read from
 *     the clause's property list and from the clauses the columns summarise:
 *       Alloc-free   <=>  constspace                       [LCAP.2.6]
 *       Join O(1)    <=>  NOT linear_scan                  [LCAP.2.2], [LCAP.4]
 *       No TMS       <=>  NOT logical                      [LCAP.2.3]
 *       TTL O(1)     <=>  NOT dynamic_ttl                  [LCAP.2.4], [LDTL.1.1], [LCAP.3.3]
 *       String O(1)  <=>  NOT linear_scan                  [LCAP.2.2], [LCAP.4]
 *       T_wcet fixed <=>  realtime                         [LCAP.4], [LCAP.2.1]
 *       Alpha-only   <=>  NOT linear_scan AND NOT logical  [LCAP.3.1]
 *   - THE FOOTNOTE RULES, `lcap_5__footnotes`: which cell carries which
 *     footnote, read from the footnotes' own text:
 *       1 on T_wcet fixed  <=>  NOT realtime
 *       2 on TTL O(1)      <=>  dynamic_ttl
 *       3 on Alloc-free    <=>  constspace AND NOT realtime
 *       4 on T_wcet fixed  <=>  realtime AND (linear_scan OR dynamic_ttl)
 *
 * WHERE EACH RULE COMES FROM. Every column rule rests on a clause and none on
 * the rows. The TTL queue is chosen by `dynamic_ttl` alone: [LCAP.2.4] and
 * [LDTL.1.1] give the per-schema FIFO to `dynamic_ttl: false`, [LCAP.3.3] gives
 * the deadline heap to `dynamic_ttl: true`, and [LCAP.2.1] keeps the FIFO under
 * `realtime` whatever `linear_scan` is. A fixed T_wcet is `realtime`'s alone:
 * [LCAP.4] has `realtime` bound every parameter so the formula becomes finite,
 * and the column's definition asks for a number from the program and its
 * declared bounds, not for a number constant in N_max; that distinction is
 * footnote 4's, and [LCAP.2.1] is where a scanning join under `realtime` is
 * bounded by the capacity rather than constant. The footnote rules are the
 * footnotes' own first sentences: a footnote marks the cause, on every row
 * that has it. Footnote 2 therefore sits on all twelve `dynamic_ttl` rows,
 * the heap being their TTL cross's cause; its second sentence, that under
 * `realtime` with `linear_scan: false` the compiler should warn, is
 * [LCAP.3.9]'s, deferred with `realtime`, places no mark and is not modelled
 * here.
 *
 * WHAT IS CHECKED. That the three transcriptions agree, and that the table is
 * the table the clause says it is:
 *   - the rows are exactly the admissible combinations: each is admissible, no
 *     combination is listed twice, and every admissible combination is listed.
 *     With 24 rows that is the clause's count, and the 8 left out are the ones
 *     [LCAP.3.7] refuses;
 *   - every cell of every row is what its column's rule gives, and every
 *     footnote mark is where its rule puts it;
 *   - what the footnotes say, read off the cells: no fixed WCET without
 *     `realtime` (footnote 1); no O(1) TTL with `dynamic_ttl: true` (footnote
 *     2); footnote 4 sits exactly on a fixed-WCET tick whose row has a crossed
 *     Join, String or TTL cell -- a term that grows with the bounds -- so only
 *     a plain tick has every term O(1), as the footnote's last sentence says;
 *     footnotes 1 and 2 qualify crosses, 3 and 4 qualify ticks; and a
 *     footnote that explains a cross is on every cross it explains: 1 on
 *     every crossed T_wcet cell, 2 on every crossed TTL cell. None of these
 *     restates a rule: each joins a column rule to a footnote rule;
 *   - a row with a fixed WCET is alloc-free. No column rule says so: it follows
 *     from `realtime` needing `constspace`.
 *
 * DISCLOSED ABSTRACTION -- READ THIS BEFORE TRUSTING A FOOTNOTE. The model reads
 * where a footnote sits and not what it says. Footnote 3 tells the plain
 * alloc-free tick under `realtime` from the pooled guarantee under `constspace`
 * alone, which [LCSP.2.1] bounds to boot-sized pools with three paths outside
 * them; footnote 4 names the terms that grow with the bounds. A footnote here is
 * one mark on one cell, so the model checks that the mark is on the row and the
 * cell its rule names, and nothing about the pools or the terms.
 *
 * TEETH, each run once on a copy with one line changed:
 *   - without the line that gives row 6 its cells: the cell check, the two
 *     footnote-reading checks on cells, the footnote-4 check, the
 *     cross-footnote check, the mark-qualifies check and the alloc-free check
 *     fail, each naming row 6; the three row checks and the footnote-placement
 *     check hold;
 *   - without the line that gives row 24 its settings: the three row checks,
 *     the cell check, the footnote-placement check and the fixed-WCET-needs-
 *     realtime check fail; the other five hold;
 *   - with row 17's footnote 4 moved onto row 21: the footnote-placement check
 *     fails naming row 17 and the footnote-4 check fails naming row 21; the
 *     other nine hold;
 *   - with row 9's footnote 1 replaced by a footnote 4 (a 4 on a cross): the
 *     footnote-placement, cross-footnote and mark-qualifies checks fail, naming
 *     row 9; the other eight hold;
 *   - with the T_wcet rule given a `NOT linear_scan` conjunct: the
 *     cell check fails, naming one of rows 17 to 20; the other ten hold;
 *   - with row 2's footnote 2 dropped:
 *     the footnote-placement check and the cross-footnote check fail, naming
 *     row 2; the other nine hold.
 */
module ds/capability_matrix

//@spec [LCAP.5]
// The five settings the matrix combines, under their stable names.
abstract sig lcap_5__setting {}
one sig realtime, constspace, linear_scan, logical, dynamic_ttl extends lcap_5__setting {}

//@spec [LCAP.5]
// The seven property columns.
abstract sig lcap_5__property {}
one sig AllocFree, JoinO1, NoTMS, TTLO1, StringO1, TwcetFixed, AlphaOnly extends lcap_5__property {}

//@spec [LCAP.5]
// The four footnotes a cell may carry, by their printed numbers.
abstract sig lcap_5__footnote {}
one sig footnote1, footnote2, footnote3, footnote4 extends lcap_5__footnote {}

//@spec [LCAP.5]
// Admissible: the combination, given as the settings that are `true`, satisfies
// the fundamental constraints. The one among these five is [LCAP.3.7]'s:
// `realtime` needs `constspace`.
pred lcap_5__admissible[t: set lcap_5__setting] { realtime in t implies constspace in t }

//@spec [LCAP.5]
// The column rules: the properties a combination has, by the header's table.
fun lcap_5__columns[t: set lcap_5__setting]: set lcap_5__property {
  { p: lcap_5__property |
         (p = AllocFree  and constspace in t)
      or (p = JoinO1     and linear_scan not in t)
      or (p = NoTMS      and logical not in t)
      or (p = TTLO1      and dynamic_ttl not in t)
      or (p = StringO1   and linear_scan not in t)
      or (p = TwcetFixed and realtime in t)
      or (p = AlphaOnly  and linear_scan not in t and logical not in t) }
}

//@spec [LCAP.5]
// The footnote rules: the footnote each cell of a combination carries, by the
// header's table. A cell carries at most one, and most carry none.
fun lcap_5__footnotes[t: set lcap_5__setting]: lcap_5__property -> lcap_5__footnote {
  { p: lcap_5__property, n: lcap_5__footnote |
         (p = TwcetFixed and n = footnote1 and realtime not in t)
      or (p = TTLO1      and n = footnote2 and dynamic_ttl in t)
      or (p = AllocFree  and n = footnote3 and constspace in t and realtime not in t)
      or (p = TwcetFixed and n = footnote4 and realtime in t and (linear_scan in t or dynamic_ttl in t)) }
}

//@spec [LCAP.5]
// A row of the matrix as the clause prints it: the settings that are `true` in
// the row, the property cells that carry a tick, and the footnote on each cell
// that carries one.
abstract sig lcap_5__row {
  at: set lcap_5__setting,
  marks: set lcap_5__property,
  notes: lcap_5__property -> lcap_5__footnote
}
one sig row01, row02, row03, row04, row05, row06, row07, row08 extends lcap_5__row {}
one sig row09, row10, row11, row12, row13, row14, row15, row16 extends lcap_5__row {}
one sig row17, row18, row19, row20, row21, row22, row23, row24 extends lcap_5__row {}

//@spec [LCAP.5]
// The table, in the clause's order: three lines a row, its settings, its cells
// and its footnotes.
fact lcap_5__table {
  row01.at = linear_scan + logical
  row01.marks = TTLO1
  row01.notes = TwcetFixed -> footnote1
  row02.at = linear_scan + logical + dynamic_ttl
  no row02.marks
  row02.notes = TTLO1 -> footnote2 + TwcetFixed -> footnote1
  row03.at = linear_scan
  row03.marks = NoTMS + TTLO1
  row03.notes = TwcetFixed -> footnote1
  row04.at = linear_scan + dynamic_ttl
  row04.marks = NoTMS
  row04.notes = TTLO1 -> footnote2 + TwcetFixed -> footnote1
  row05.at = logical
  row05.marks = JoinO1 + TTLO1 + StringO1
  row05.notes = TwcetFixed -> footnote1
  row06.at = logical + dynamic_ttl
  row06.marks = JoinO1 + StringO1
  row06.notes = TTLO1 -> footnote2 + TwcetFixed -> footnote1
  no row07.at
  row07.marks = JoinO1 + NoTMS + TTLO1 + StringO1 + AlphaOnly
  row07.notes = TwcetFixed -> footnote1
  row08.at = dynamic_ttl
  row08.marks = JoinO1 + NoTMS + StringO1 + AlphaOnly
  row08.notes = TTLO1 -> footnote2 + TwcetFixed -> footnote1
  row09.at = constspace + linear_scan + logical
  row09.marks = AllocFree + TTLO1
  row09.notes = AllocFree -> footnote3 + TwcetFixed -> footnote1
  row10.at = constspace + linear_scan + logical + dynamic_ttl
  row10.marks = AllocFree
  row10.notes = AllocFree -> footnote3 + TTLO1 -> footnote2 + TwcetFixed -> footnote1
  row11.at = constspace + linear_scan
  row11.marks = AllocFree + NoTMS + TTLO1
  row11.notes = AllocFree -> footnote3 + TwcetFixed -> footnote1
  row12.at = constspace + linear_scan + dynamic_ttl
  row12.marks = AllocFree + NoTMS
  row12.notes = AllocFree -> footnote3 + TTLO1 -> footnote2 + TwcetFixed -> footnote1
  row13.at = constspace + logical
  row13.marks = AllocFree + JoinO1 + TTLO1 + StringO1
  row13.notes = AllocFree -> footnote3 + TwcetFixed -> footnote1
  row14.at = constspace + logical + dynamic_ttl
  row14.marks = AllocFree + JoinO1 + StringO1
  row14.notes = AllocFree -> footnote3 + TTLO1 -> footnote2 + TwcetFixed -> footnote1
  row15.at = constspace
  row15.marks = AllocFree + JoinO1 + NoTMS + TTLO1 + StringO1 + AlphaOnly
  row15.notes = AllocFree -> footnote3 + TwcetFixed -> footnote1
  row16.at = constspace + dynamic_ttl
  row16.marks = AllocFree + JoinO1 + NoTMS + StringO1 + AlphaOnly
  row16.notes = AllocFree -> footnote3 + TTLO1 -> footnote2 + TwcetFixed -> footnote1
  row17.at = realtime + constspace + linear_scan + logical
  row17.marks = AllocFree + TTLO1 + TwcetFixed
  row17.notes = TwcetFixed -> footnote4
  row18.at = realtime + constspace + linear_scan + logical + dynamic_ttl
  row18.marks = AllocFree + TwcetFixed
  row18.notes = TTLO1 -> footnote2 + TwcetFixed -> footnote4
  row19.at = realtime + constspace + linear_scan
  row19.marks = AllocFree + NoTMS + TTLO1 + TwcetFixed
  row19.notes = TwcetFixed -> footnote4
  row20.at = realtime + constspace + linear_scan + dynamic_ttl
  row20.marks = AllocFree + NoTMS + TwcetFixed
  row20.notes = TTLO1 -> footnote2 + TwcetFixed -> footnote4
  row21.at = realtime + constspace + logical
  row21.marks = AllocFree + JoinO1 + TTLO1 + StringO1 + TwcetFixed
  no row21.notes
  row22.at = realtime + constspace + logical + dynamic_ttl
  row22.marks = AllocFree + JoinO1 + StringO1 + TwcetFixed
  row22.notes = TTLO1 -> footnote2 + TwcetFixed -> footnote4
  row23.at = realtime + constspace
  row23.marks = AllocFree + JoinO1 + NoTMS + TTLO1 + StringO1 + TwcetFixed + AlphaOnly
  no row23.notes
  row24.at = realtime + constspace + dynamic_ttl
  row24.marks = AllocFree + JoinO1 + NoTMS + StringO1 + TwcetFixed + AlphaOnly
  row24.notes = TTLO1 -> footnote2 + TwcetFixed -> footnote4
}

//@spec [LCAP.5]
// Any combination of the five settings, as the settings that are `true`: what
// the checks that range over all 32 range over.
sig lcap_5__combination { sets: set lcap_5__setting }

//@probe
// The transcribed table is consistent with itself: it has a row with a plain
// fixed-WCET tick and a row with a footnoted one, and there is a combination
// the matrix leaves out.
run probe__table {
  some r: lcap_5__row | TwcetFixed in r.marks and no r.notes
  some r: lcap_5__row | (TwcetFixed -> footnote4) in r.notes
  some c: lcap_5__combination | not lcap_5__admissible[c.sets]
} for 4

// EVERY ROW IS ADMISSIBLE: no listed row has `realtime: true` with
// `constspace: false`. NO counterexample.
assert lcap_5__every_row_is_admissible {
  all r: lcap_5__row | lcap_5__admissible[r.at]
}
//@derives [LCAP.5]
check lcap_5__every_row_is_admissible for 4

// NO COMBINATION IS LISTED TWICE. NO counterexample.
assert lcap_5__no_combination_is_listed_twice {
  all disj r, s: lcap_5__row | r.at != s.at
}
//@derives [LCAP.5]
check lcap_5__no_combination_is_listed_twice for 4

// EVERY ADMISSIBLE COMBINATION IS LISTED: with the two checks above, the 24 rows
// are the admissible combinations exactly. NO counterexample.
assert lcap_5__every_admissible_combination_is_listed {
  all c: lcap_5__combination |
    lcap_5__admissible[c.sets] implies (some r: lcap_5__row | r.at = c.sets)
}
//@derives [LCAP.5]
check lcap_5__every_admissible_combination_is_listed for 4

// EVERY CELL FOLLOWS ITS COLUMN: each row's ticks are what the column rules give
// for its settings. A cell that disagrees is named by its row. NO counterexample.
assert lcap_5__each_cell_follows_its_column {
  all r: lcap_5__row | r.marks = lcap_5__columns[r.at]
}
//@derives [LCAP.5]
check lcap_5__each_cell_follows_its_column for 4

// EVERY FOOTNOTE FOLLOWS ITS RULE: each row's footnote marks are what the
// footnote rules give for its settings. A mark that disagrees is named by its
// row. NO counterexample.
assert lcap_5__each_footnote_follows_its_rule {
  all r: lcap_5__row | r.notes = lcap_5__footnotes[r.at]
}
//@derives [LCAP.5]
check lcap_5__each_footnote_follows_its_rule for 4

// FOOTNOTE 1, read off the cells: no row has a fixed WCET without `realtime`.
// NO counterexample.
assert lcap_5__a_fixed_wcet_needs_realtime {
  all r: lcap_5__row | TwcetFixed in r.marks implies realtime in r.at
}
//@derives [LCAP.5]
check lcap_5__a_fixed_wcet_needs_realtime for 4

// FOOTNOTE 2, read off the cells: a row with `dynamic_ttl: true` has no O(1)
// TTL. It says nothing of the row's T_wcet, which under `realtime` is fixed and
// footnoted (footnote 4). NO counterexample.
assert lcap_5__dynamic_ttl_loses_the_ttl_bound {
  all r: lcap_5__row | dynamic_ttl in r.at implies TTLO1 not in r.marks
}
//@derives [LCAP.5]
check lcap_5__dynamic_ttl_loses_the_ttl_bound for 4

// FOOTNOTE 4 MARKS A TERM THAT GROWS: a fixed-WCET cell carries footnote 4
// exactly when its row has a crossed Join, String or TTL cell -- a term of
// T_wcet that grows with the bounds -- so only a plain tick has every term O(1).
// NO counterexample.
assert lcap_5__footnote_4_marks_a_term_that_grows {
  all r: lcap_5__row | TwcetFixed in r.marks implies
    ((TwcetFixed -> footnote4) in r.notes
      iff (JoinO1 not in r.marks or StringO1 not in r.marks or TTLO1 not in r.marks))
}
//@derives [LCAP.5]
check lcap_5__footnote_4_marks_a_term_that_grows for 4

// A CROSS FOOTNOTE MARKS EVERY CROSS IT EXPLAINS: footnote 1 is on every
// crossed T_wcet cell and footnote 2 on every crossed TTL cell, and on no
// tick. Joins the column rules to the footnote rules. NO counterexample.
assert lcap_5__a_cross_footnote_marks_every_cross_it_explains {
  all r: lcap_5__row {
    (TwcetFixed -> footnote1) in r.notes iff TwcetFixed not in r.marks
    (TTLO1 -> footnote2) in r.notes iff TTLO1 not in r.marks
  }
}
//@derives [LCAP.5]
check lcap_5__a_cross_footnote_marks_every_cross_it_explains for 4

// A FOOTNOTE QUALIFIES THE MARK IT SITS ON: footnotes 1 and 2 explain a cross,
// footnotes 3 and 4 qualify a tick. NO counterexample.
assert lcap_5__a_footnote_qualifies_the_mark_it_sits_on {
  all r: lcap_5__row, p: lcap_5__property {
    ((p -> footnote1) in r.notes or (p -> footnote2) in r.notes) implies p not in r.marks
    ((p -> footnote3) in r.notes or (p -> footnote4) in r.notes) implies p in r.marks
  }
}
//@derives [LCAP.5]
check lcap_5__a_footnote_qualifies_the_mark_it_sits_on for 4

// A FIXED WCET IS ALLOC-FREE: every row with a fixed WCET is alloc-free. It is
// not a column rule; it holds because a fixed WCET needs `realtime` and an
// admissible row with `realtime` has `constspace`. NO counterexample.
assert lcap_5__a_fixed_wcet_row_is_alloc_free {
  all r: lcap_5__row | TwcetFixed in r.marks implies AllocFree in r.marks
}
//@derives [LCAP.5]
check lcap_5__a_fixed_wcet_row_is_alloc_free for 4

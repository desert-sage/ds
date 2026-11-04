/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS series — aggregation applicability (type x time-model) model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lser_17__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. A series aggregation is gated by TWO orthogonal applicability axes:
 * the per-type matrix ([LSER.17.2] — `min` needs numeric, `bool_and` needs Bool, ...)
 * and the agg x time-model matrix ([LSER.18.1] — the ✓ cells; ✗ cells are reserved for
 * v2). Per [LSER.17.7] BOTH axes must be satisfied: the compiler accepts a series
 * declaration iff its aggregation applies to the slot's value type AND has an exact
 * backing for its time model. This model proves an empty cell in EITHER matrix rejects
 * the series — no type-mismatched aggregation and no unbacked (✗) cell slips through.
 *
 * The two matrices are left uninterpreted so the invariant is the STRUCTURAL rule of
 * [LSER.17.7] (both-axes-required), not a transcription of specific cells — the proof
 * survives any matrix edit. TEETH: drop `lser_17_7__accept_iff_both_axes` and all
 * three checks fail — an accepted series could sit in an empty cell of either matrix.
 */
module ds/series_applicability

//@spec [LSER.17]
// An aggregation verb (mean, min, count, bool_and, count_distinct, ...).
sig lser_17__aggregation {}

//@spec [LSER.17.1]
// A slot value type ([LFAC]): Float, Int, Bool, String, Bytes, Json.
sig lser_17_1__value_type {}

//@spec [LSER.18]
// A time model: all_time, sliding, tumbling, sample.
sig lser_18__time_model {}

//@spec [LSER.17.2]
// The per-type applicability matrix: the (aggregation, value-type) pairs the type axis
// admits — `min`/`mean` on numeric, `bool_and` on Bool, `count` on any, etc.
one sig lser_17_2__type_matrix { admits: lser_17__aggregation -> lser_17_1__value_type }

//@spec [LSER.18.1]
// The agg x time-model support matrix: the (aggregation, time-model) pairs with an
// exact v1 backing — the ✓ cells; ✗ cells (e.g. `median` on all_time) are absent.
one sig lser_18_1__tm_matrix { supports: lser_17__aggregation -> lser_18__time_model }

//@spec [LSER.17.7]
// A series declaration: one aggregation over a slot of a value type under a time model.
sig lser_17_7__series {
  agg:        one lser_17__aggregation,
  slot_type:  one lser_17_1__value_type,
  time_model: one lser_18__time_model
}

//@spec [LSER.17.7]
// The series declarations the compiler accepts (type-check).
sig lser_17_7__accepted in lser_17_7__series {}

//@spec [LSER.17.7]
// Both axes must be satisfied: a series is accepted IFF its aggregation applies to the
// slot's value type (the [LSER.17.2] matrix) AND has an exact backing for its time
// model (the [LSER.18.1] matrix). An empty cell in EITHER matrix rejects.
fact lser_17_7__accept_iff_both_axes {
  all s: lser_17_7__series |
    s in lser_17_7__accepted iff
      ((s.agg -> s.slot_type) in lser_17_2__type_matrix.admits
       and (s.agg -> s.time_model) in lser_18_1__tm_matrix.supports)
}

//@probe
// A world where an accepted series and a rejected (empty-cell) series coexist is
// satisfiable — the matrices both admit and reject.
run probe__consistent {
  some lser_17_7__accepted
  some s: lser_17_7__series | s not in lser_17_7__accepted
} for 6

// TYPE AXIS: no accepted series applies an aggregation to a value type the [LSER.17.2]
// matrix rejects (e.g. `mean` on a String slot). NO counterexample.
assert lser_17__type_axis_enforced {
  all s: lser_17_7__accepted |
    (s.agg -> s.slot_type) in lser_17_2__type_matrix.admits
}
//@spec [LSER.17]
check lser_17__type_axis_enforced for 6

// TIME-MODEL AXIS: no accepted series lands in an empty (✗) cell of the [LSER.18]
// matrix (e.g. `median` on all_time, reserved for v2). NO counterexample.
assert lser_18__timemodel_axis_enforced {
  all s: lser_17_7__accepted |
    (s.agg -> s.time_model) in lser_18_1__tm_matrix.supports
}
//@spec [LSER.18]
check lser_18__timemodel_axis_enforced for 6

// BOTH AXES / EMPTY-CELL REJECT: a series whose aggregation fails EITHER axis is
// rejected ([LSER.17.7]) — both axes are required. NO counterexample.
assert lser_17_7__empty_cell_rejected {
  all s: lser_17_7__series |
    (((s.agg -> s.slot_type) not in lser_17_2__type_matrix.admits)
     or ((s.agg -> s.time_model) not in lser_18_1__tm_matrix.supports))
      implies s not in lser_17_7__accepted
}
//@spec [LSER.17.7]
check lser_17_7__empty_cell_rejected for 6

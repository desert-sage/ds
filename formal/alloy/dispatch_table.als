/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS dispatch table — field-order / slot-table correspondence model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_idsp_14__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. `ds_dispatch_t` is a fixed 8-slot struct whose field indices 0-7
 * must match the RAOT.6 CODE-atom slot table EXACTLY ([IDSP.14.3]); a compiled CODE
 * block calls a verb by its slot index, so a mismatch would dispatch to the wrong
 * function. This model proves the correspondence keeps compiled calls correct: a
 * call at slot index p reaches exactly the verb the slot table places at p.
 *
 * TEETH: drop `idsp_14_3__field_order_matches_slot_table` and the check fails — a
 * compiled call at slot p dispatches to a different verb than the slot table intends.
 */
module ds/dispatch_table

//@spec [IDSP.14]
// An action verb (wm_assert, publish, call, cache_set, cache_delete, log, alert;
// `record_event` is retired with its slot).
sig idsp_14__verb {}

//@spec [IDSP.14]
// A slot index (0-7) into both the dispatch struct and the AOT slot table — the
// shared index space. The field-order MATCH on it is [IDSP.14.3] (the fact below).
sig idsp_14__position {}

//@spec [RAOT.6]
// The AOT CODE-atom slot table: which verb each slot index calls.
one sig raot_6__slot_table { verb_at: idsp_14__position -> one idsp_14__verb }

//@spec [IDSP.14]
// The ds_dispatch_t struct: which verb's function pointer sits at each field index.
one sig idsp_14__dispatch { field_at: idsp_14__position -> one idsp_14__verb }

//@spec [IDSP.14.3]
// Field order is load-bearing: the dispatch field at each index equals the slot
// table's verb at that index — the two orderings match exactly.
fact idsp_14_3__field_order_matches_slot_table {
  all p: idsp_14__position |
    idsp_14__dispatch.field_at[p] = raot_6__slot_table.verb_at[p]
}

//@spec [IDSP.14]
// A compiled CODE-atom RHS call: it references a verb by slot index.
sig idsp_14__code_call { slot: one idsp_14__position }

//@probe
// A non-trivial table with a compiled call referencing a slot is satisfiable.
run probe__consistent {
  some idsp_14__code_call and some raot_6__slot_table.verb_at
} for 8

// CORRECTNESS: a compiled call at slot index p dispatches, through the struct, to
// exactly the verb the RAOT slot table places at p — compiled CODE never calls the
// wrong verb. NO counterexample.
assert idsp_14_3__call_reaches_slot_verb {
  all c: idsp_14__code_call |
    idsp_14__dispatch.field_at[c.slot] = raot_6__slot_table.verb_at[c.slot]
}
//@spec [IDSP.14.3]
check idsp_14_3__call_reaches_slot_verb for 8

// SAME INDEX: each verb sits at the same index in the dispatch struct and the slot
// table — reordering one without the other is exactly what this forbids. NO
// counterexample.
assert idsp_14_3__verb_index_matches {
  all v: idsp_14__verb |
    idsp_14__dispatch.field_at.v = raot_6__slot_table.verb_at.v
}
//@spec [IDSP.14.3]
check idsp_14_3__verb_index_matches for 8

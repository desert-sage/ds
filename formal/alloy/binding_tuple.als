/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS artefact binding — fail-closed tuple cross-check model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_rbnd_5_1__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. When two versioned artefacts load together they cross-check their
 * binding tuples element-wise ([RBND.5.1]): the dialect fields (dsc_sha256,
 * capabilities, dialect_def_sha256) and the RT-config field (rt_config_sha256) of
 * the secondary MUST equal the primary's. A mismatch on ANY field
 * is fatal — no advisory / warn-and-continue mode ([RBND.5.3]) — and raises exactly one
 * BND_* code by the field's group ([RBND.5.2]; codes in [NERR.11], band -700). This
 * model proves the load is fail-CLOSED (a single disagreement rejects — no
 * partial match slips) and that the reported code names a field that actually
 * disagreed, never an unrelated category.
 *
 * TEETH: drop `rbnd_5_3__accept_iff_all_agree` and the fail-closed checks fail (a
 * partial-match load loads); drop `rbnd_5_2__blame_is_a_real_mismatch` and the code
 * check fails (a dsc_sha256 mismatch reported as BND_DIALECT_MISMATCH).
 */
module ds/binding_tuple

//@spec [NERR.11]
// A dialect / artefact-binding reject code — BND_DSC / BND_DIALECT / BND_RT_CONFIG
// (band -700..-704).
sig nerr_11__code {}

//@spec [RBND.5.1]
// A binding-tuple field (dsc_sha256, capabilities, dialect_def_sha256,
// rt_config_sha256). `reject_code` is the BND_* code a
// disagreement on this field raises ([RBND.5.2]); two dialect fields share
// BND_DIALECT, so the map is a total function, not an injection.
sig rbnd_5_1__field { reject_code: one nerr_11__code }

//@spec [RBND.5.1]
// An abstract field value (a hash, a list of capabilities).
sig rbnd_5_1__value {}

//@spec [RBND.5.1]
// A versioned artefact: one value per binding field — its binding tuple.
sig rbnd_5_1__artefact { binds: rbnd_5_1__field -> one rbnd_5_1__value }

//@spec [RBND.5.1]
// A paired load: a secondary artefact cross-checked against a primary (the DSC), plus
// the field the loader blames when it rejects (its reported BND_* code is that field's).
sig rbnd_5_1__load {
  primary:   one rbnd_5_1__artefact,
  secondary: one rbnd_5_1__artefact,
  blame:     lone rbnd_5_1__field
}

//@spec [RBND.5.1]
// The fields on which the two artefacts disagree — element-wise inequality.
fun rbnd_5_1__mismatched[l: rbnd_5_1__load]: set rbnd_5_1__field {
  { f: rbnd_5_1__field | l.primary.binds[f] != l.secondary.binds[f] }
}

//@spec [RBND.5.3]
// The paired loads that succeed.
sig rbnd_5_3__accepted in rbnd_5_1__load {}

//@spec [RBND.5.3]
// Fail-closed: a paired load is accepted IFF the artefacts agree on EVERY binding field
// ([RBND.5.1] element-wise equality; [RBND.5.3] no advisory / warn-and-continue / best-
// effort mode).
fact rbnd_5_3__accept_iff_all_agree {
  all l: rbnd_5_1__load | l in rbnd_5_3__accepted iff no rbnd_5_1__mismatched[l]
}

//@spec [RBND.5.2]
// A rejected load blames exactly one field it actually disagreed on; an accepted load
// blames none. The reported BND_* code is that field's `reject_code`.
fact rbnd_5_2__blame_is_a_real_mismatch {
  all l: rbnd_5_1__load |
    (l in rbnd_5_3__accepted implies no l.blame)
    and (l not in rbnd_5_3__accepted
         implies (one l.blame and l.blame in rbnd_5_1__mismatched[l]))
}

//@probe
// A load agreeing on all-but-one field is still rejected and blamed on the differing
// field, alongside a fully-agreeing accepted load. Satisfiable.
run probe__partial_match_still_rejects {
  some l: rbnd_5_1__load | l not in rbnd_5_3__accepted and one rbnd_5_1__mismatched[l]
  some rbnd_5_3__accepted
} for 6

// FAIL-CLOSED: any single field disagreement rejects the load — no partial match
// slips through ([RBND.5.1] / [RBND.5.3]). NO counterexample.
assert rbnd_5_3__any_mismatch_rejects {
  all l: rbnd_5_1__load |
    some rbnd_5_1__mismatched[l] implies l not in rbnd_5_3__accepted
}
//@spec [RBND.5.3]
check rbnd_5_3__any_mismatch_rejects for 6

// ACCEPTED IMPLIES FULL AGREEMENT: an accepted paired load matched element-wise on every
// binding field ([RBND.5.1]). NO counterexample.
assert rbnd_5_1__accepted_fully_agree {
  all l: rbnd_5_3__accepted | no rbnd_5_1__mismatched[l]
}
//@spec [RBND.5.1]
check rbnd_5_1__accepted_fully_agree for 6

// DIAGNOSIS NAMES A REAL MISMATCH: a rejected load's reported code is the reject_code of
// a field that actually disagreed — never an unrelated BND_* category ([RBND.5.2]).
// NO counterexample.
assert rbnd_5_2__reported_code_is_correct {
  all l: rbnd_5_1__load |
    (l not in rbnd_5_3__accepted)
      implies l.blame.reject_code in rbnd_5_1__mismatched[l].reject_code
}
//@spec [RBND.5.2]
check rbnd_5_2__reported_code_is_correct for 6

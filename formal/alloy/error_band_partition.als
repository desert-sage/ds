/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS status codes — the two-level band register as a partition (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_nerr_3_1__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. The register has two levels. The language states the bands
 * ([LERR.8.2]: -600..-699 is "native Rete loader, realtime, series-backend ABI") and
 * says they are normative and partition the value space; the integration and impl
 * registers ([NERR.3.1], [IERR.2.8.1]) claim rows inside them — -600..-610 native
 * Rete / realtime, -620..-625 series-backend ABI — each row owned by one subsystem and
 * fixing one recovery disposition ([IERR.2.1]: "each decade-range is a category").
 * The rows partition the value space too, whoever owns them, so a produced error
 * resolves to exactly one row by its value alone and its disposition is determined.
 * Sharing a value across rows of different subsystems is not a sanctioned exception
 * any more; [LERR.8.2] records that the -600 band "was handed to two families because
 * an allocation skipped the register", and the register no longer does.
 *
 * WHAT THIS MODEL USED TO SAY, and why it changed. It required
 * disjointness only WITHIN a subsystem and let two subsystems share a value,
 * resolving a produced error by a (value, originating-call) provenance key. That was
 * the register of the -600..-605 overlap, which the corpus has withdrawn; the model
 * stayed green because its checks restated its own permission. Now the partition is
 * unconditional and the error carries no provenance because it needs none.
 *
 * (The permanence law — retired ranges are never reused — is the sibling model
 * error_bands.als [NERR.3.2]; this model is the partition half.)
 *
 * TEETH: drop `nerr_3_1__rows_disjoint` and `nerr_3_1__value_resolves_uniquely` fails
 * — a value in two rows resolves to two dispositions. Drop
 * `ierr_2_8_1__row_inside_its_band` and `ierr_2_8_1__claim_never_crosses_a_band`
 * fails — a claimed row straddles two language bands.
 */
module ds/error_band_partition

//@spec [IERR.2.1]
// A numeric status-code value (e.g. -204, -400, -606).
sig ierr_2_1__value {}

//@spec [NERR.3.1]
// The subsystem a row belongs to (generic / runtime / storage / native Rete /
// series-backend / dialect binding / …).
sig nerr_3_1__subsystem {}

//@spec [NERR.3.1]
// A recovery disposition (retry, recompile, rebuild the backend, check RT config, …).
sig nerr_3_1__disposition {}

//@spec [LERR.8.2]
// A band of the language register: a value range with one category.
sig lerr_8_2__band {
  members: some ierr_2_1__value
}

//@spec [LERR.8.2]
// The language bands partition the value space.
fact lerr_8_2__bands_disjoint {
  all disj b1, b2: lerr_8_2__band | no (b1.members & b2.members)
}

//@spec [NERR.3.1]
// A row of the integration register: a value range inside one language band, owned
// by one subsystem, fixing one recovery disposition for every code in it.
sig nerr_3_1__band {
  members:     some ierr_2_1__value,
  within:      one lerr_8_2__band,
  owner:       one nerr_3_1__subsystem,
  disposition: one nerr_3_1__disposition
}

//@spec [IERR.2.8.1]
// A claimed row lies inside the language band that holds its decade.
fact ierr_2_8_1__row_inside_its_band {
  all b: nerr_3_1__band | b.members in b.within.members
}

//@spec [NERR.3.1]
// The rows partition the value space: no value sits in two rows, whoever owns them.
fact nerr_3_1__rows_disjoint {
  all disj b1, b2: nerr_3_1__band | no (b1.members & b2.members)
}

//@spec [NERR.3.1]
// A produced error: a value. It carries no provenance, because it needs none.
sig nerr_3_1__error {
  value: one ierr_2_1__value
}

//@spec [NERR.3.1]
// Resolve a produced error to its row by the value alone.
fun nerr_3_1__resolve[e: nerr_3_1__error]: set nerr_3_1__band {
  { b: nerr_3_1__band | e.value in b.members }
}

//@probe
// The -600 decade as the register now has it: two rows of different subsystems with
// different dispositions inside ONE language band, and every produced error resolving
// to a row.
run probe__two_families_one_decade {
  some disj b1, b2: nerr_3_1__band |
    b1.within = b2.within and b1.owner != b2.owner and b1.disposition != b2.disposition
  some nerr_3_1__error
  all e: nerr_3_1__error | some nerr_3_1__resolve[e]
} for 6

// THE VALUE RESOLVES UNIQUELY: a produced error's value lies in at most one row — no
// call, no provenance, no ambiguity. NO counterexample.
//
// A TRANSCRIPTION, NOT A REFUTATION: with `resolve` unfolded this is
// `nerr_3_1__rows_disjoint` read from a value's side, one fact in a second
// spelling, so it is UNSAT on any model that has the fact and is tagged `spec`
// for that reason.
assert nerr_3_1__value_resolves_uniquely {
  all e: nerr_3_1__error | lone nerr_3_1__resolve[e]
}
//@spec [NERR.3.1]
check nerr_3_1__value_resolves_uniquely for 6

// That two errors with one value resolve to rows of one owner is
// `value_resolves_uniquely` above together with `owner: one`.
// formal/alloy/error_bands.als's `nerr_10_2__origin_follows_the_value` states it
// with an origin independent of the value, where it can fail.

// DISPOSITION FOLLOWS THE ROW: a produced error that resolves has exactly one
// disposition ([IERR.2.1] "each decade-range is a category"). NO counterexample.
assert ierr_2_1__disposition_determinate {
  all e: nerr_3_1__error |
    (some nerr_3_1__resolve[e]) implies one nerr_3_1__resolve[e].disposition
}
//@derives [IERR.2.1]
check ierr_2_1__disposition_determinate for 6

// THE NUMBER DETERMINES THE CATEGORY: a value falls in at most one language band, so
// [LERR.8.2]'s table is a partition and not a list of ranges that happen not to
// overlap today — "the bands are normative, and an enum cannot express them". English
// carries the table; this carries the claim the table makes. NO counterexample.
assert lerr_8_2__bands_partition_the_value_space {
  all v: ierr_2_1__value | lone b: lerr_8_2__band | v in b.members
}
//@spec [LERR.8.2]
check lerr_8_2__bands_partition_the_value_space for 6

// A CLAIM NEVER CROSSES A BAND: a row of the integration register meets exactly one
// language band — the one it was claimed inside — so amending [IERR.2.8.1] can only
// subdivide a band, never bridge two. NO counterexample.
assert ierr_2_8_1__claim_never_crosses_a_band {
  all b: nerr_3_1__band | lone lb: lerr_8_2__band | some (b.members & lb.members)
}
//@derives [IERR.2.8.1]
check ierr_2_8_1__claim_never_crosses_a_band for 6

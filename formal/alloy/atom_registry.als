/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS atom registry — structural consistency model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_idat_4_3__<tag>):
 *      <lowercased-clause-id>__<snake_tag>, e.g. `rfcs_3_1__registry_number`
 *      formalizes [RFCS.3.1]. Two elements of one clause differ by the tag
 *      (`rfcs_3_1__registry_number` vs `rfcs_3_1__live_atom`). An element with
 *      no clause would carry a marker prefix instead: `gap__` (an
 *      invariant with no dotted home — a finding) or `probe__` (a
 *      satisfiability probe). Enumeration members inherit their parent's clause
 *      and carry no id of their own (the crossref checker exempts them, as it
 *      does their tags).
 *   2. TAG. The line above each element repeats the clause in bracket form so
 *      the checker can confirm the id exists in the normative tree AND matches
 *      the name.
 *
 * STATUS — ANCHORED. The classification core ties to [RFCS.3.4] / [RFCS.3.1] /
 * [RFCS.2.3]; reserved-never-reused ties to the [STYL.2.8.7] reserved-allocation
 * discipline; and the band geometry ties to [RFCS.16.2], the home of
 * the three-band partition (inject 1–127 / reject-don't-skip 128–255 /
 * skip-don't-reject 256–2047).
 * The numeric boundaries themselves are not this model's
 * subject: formal/cbmc/rfcs_16_2__band.c proves them over all 2^32 field
 * numbers against the C. This model carries the bands as three atoms and
 * checks what the registry does with them.
 *
 * WHAT THE ALIGNMENT FACT SAYS, read off [RFCS.3.1]'s table: every inject-class
 * stream atom (FactAssert 1, FactRetract 2, ClockAdvance 3, PumpBoundary 4,
 * ExternalAssert 5, the host input that carries a fact reference, RFCS.24,
 * CacheSeed 6, the host cache seed in the prelude, RFCS.26)
 * sits in the inject band, and every compare- or structural-class stream atom
 * (SchemaDef 256, Slot 257, StreamHeader 258, Checkpoint 259,
 * RuleFireAnnotation 261, CallIssued 262, ComputationError 325 … EngineError
 * 330) sits in the skip band. The reject-don't-skip band holds
 * DSC-container atoms (RealtimeContract 128, SeriesBackendIntervalPulse 129,
 * SeriesBackendNumericIntegral 130, InitialFact 131, InitialCacheSeed 132)
 * that carry no stream class, which is why no live atom of this model lands
 * there — the model is
 * the STREAM registry's classification, [RFCS.3.4]'s subject, not the whole
 * number space. The rows are this reading's, not instances: a registry number
 * here is an atom with a band and no value, so the census is held to the proto
 * by the registry gate, and this model holds what the registry does with the
 * bands.
 *
 * TEETH: comment out `rfcs_3_4__class_band_alignment` and the safety check
 * fails with an inject-class atom numbered in the skip band, where an old
 * reader would skip it ([RFCS.2.3]) and drop a real input.
 */
module ds/atom_registry

//@spec [RFCS.16.2]
// The number-space partition fixing the disposition of an UNKNOWN atom:
// inject 1..127 / reject-don't-skip 128..255 / skip-don't-reject 256..2047,
// modelled relationally as three atoms.
abstract sig rfcs_16_2__atom_number_bands {}
one sig inject_band extends rfcs_16_2__atom_number_bands {}  // unknown -> reject (would drop an input)
one sig reject_band extends rfcs_16_2__atom_number_bands {}  // unknown -> reject (DSC-format atoms)
one sig skip_band   extends rfcs_16_2__atom_number_bands {}  // unknown -> skip  (compare/structural)

//@spec [RFCS.3.1]
// A number in the atom field-number space (the [RFCS.3.1] registry table).
sig rfcs_3_1__registry_number { band: one rfcs_16_2__atom_number_bands }

//@spec [RFCS.3.4]
// Replay classification of a KNOWN atom: inject / compare / structural.
abstract sig rfcs_3_4__replay_class {}
one sig inject     extends rfcs_3_4__replay_class {}  // delivered on replay
one sig compare    extends rfcs_3_4__replay_class {}  // byte-compared, never delivered
one sig structural extends rfcs_3_4__replay_class {}  // framing / schema / seek

//@spec [RFCS.3.1]
// A live atom: a distinct registry number + a replay class.
sig rfcs_3_1__live_atom {
  num: one rfcs_3_1__registry_number,
  cls: one rfcs_3_4__replay_class
}

//@spec [STYL.2.8.7]
// Retired / reserved numbers: gone from service, never reused — the STYL.2.8.7
// reserved-allocation discipline (gaps=tombstones), applied to the registry.
sig styl_2_8_7__reserved_number in rfcs_3_1__registry_number {}

//@spec [RFCS.3.1]
// No two live atoms share a registry number (the oneof number space).
fact rfcs_3_1__numbers_unique { all disj a, a2: rfcs_3_1__live_atom | a.num != a2.num }

//@spec [STYL.2.8.7]
fact styl_2_8_7__reserved_never_live { no rfcs_3_1__live_atom.num & styl_2_8_7__reserved_number }

//@spec [RFCS.3.4]
//@derives [RFCS.3.1]
// Class->band alignment, as [RFCS.3.1]'s table has it: inject-class sits in the
// inject band (a new one forces a version bump — an old reader cannot skip a
// real input); compare and structural sit in the skip band.
fact rfcs_3_4__class_band_alignment {
  all a: rfcs_3_1__live_atom {
    a.cls = inject                  implies a.num.band = inject_band
    a.cls in (compare + structural) implies a.num.band = skip_band
  }
}

//@probe
// A registry with both inject and compare atoms is satisfiable.
run probe__consistent {
  some a:  rfcs_3_1__live_atom | a.cls = inject
  some a2: rfcs_3_1__live_atom | a2.cls = compare
} for 6

// SAFETY: no inject-class atom lands in the skip band, where an old reader would
// silently skip it ([RFCS.2.3]) and drop a real input. NO counterexample.
//
// A TRANSCRIPTION, NOT A REFUTATION: this restates the alignment fact's first
// conjunct against the band atoms' disjointness, so it is UNSAT on any model
// that has the fact, and is tagged `spec` for that reason.
assert rfcs_2_3__no_inject_silently_skipped {
  no a: rfcs_3_1__live_atom | a.cls = inject and a.num.band = skip_band
}
//@spec [RFCS.3.4]
//@spec [RFCS.2.3]
check rfcs_2_3__no_inject_silently_skipped for 6

/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS atom skip-safety — the unknown-atom model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_rfcs_3_4__<tag>):
 *      <lowercased-clause-id>__<snake_tag>, e.g. `rfcs_3_4__atom` formalizes
 *      [RFCS.3.4]. A satisfiability probe carries the `probe__` marker.
 *      Enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. The whole atom-registry + framing scheme rests on one safety
 * property: a reader that meets an atom it does not know SKIPS it (log+ignore,
 * [RDSC.9.4]) — and that is only safe because a skipped atom is never
 * inject-class. Skipping an inject-class atom would drop a real input
 * ([RFCS.3.4]), so an unknown inject atom must force a reject
 * ([RFCS.18.8]). This model proves: a reader that ACCEPTS a stream never
 * silently drops an inject-class atom.
 *
 * THERE IS NO VERSION TO ORDER. A reader accepts artefacts from its own
 * `<major>.<minor>.` series and rejects the rest ([LDET.1.10]), so there is no
 * ordering to walk and no introduced-at to compare.
 *
 * The property does not depend on an ordering. "Which
 * atoms does this reader know" is a plain set, which is strictly weaker
 * than the old monotonic story and therefore proves the safety result over MORE
 * readers, not fewer.
 *
 * WHAT THIS MODEL DOES NOT COVER, stated so its absence is not read as safety:
 *
 *   - **A KNOWN atom whose MEANING changed.** `ldet_1_10__unknown` is the
 *     complement of `knows`, so an atom the reader knows, and reads, and is
 *     wrong about, is outside every quantifier below. That hazard is what
 *     [LDET.1.10] answers by scoping replay determinism to a minor series —
 *     a meaning change lands with a release, and a reader from another series
 *     is refused before any atom is read. This model is silent on it.
 *
 * TEETH: comment out `rfcs_3_4__inject_never_skip_eligible` and the check fails
 * with a reader that accepts a stream while skipping an unknown inject atom.
 */
module ds/atom_skip_safety

//@spec [RFCS.3.4]
// The three replay classes an atom can carry.
abstract sig rfcs_3_4__atom_class {}
one sig inject     extends rfcs_3_4__atom_class {}  // delivered; skipping drops a real input
one sig compare    extends rfcs_3_4__atom_class {}  // re-derived + byte-compared, not delivered
one sig structural extends rfcs_3_4__atom_class {}  // framing / schema / seek, no replay-input meaning

//@spec [RDSC.9.4]
// How a reader treats an atom UNKNOWN to it: skip (log+ignore, the default) or
// reject the stream (a reject-gate carve-out, e.g. DSRT).
abstract sig rdsc_9_4__compat_mode {}
one sig skip_unknown   extends rdsc_9_4__compat_mode {}
one sig reject_unknown extends rdsc_9_4__compat_mode {}

//@spec [RFCS.3.4]
// An atom type: its replay class and its unknown-atom compat mode.
sig rfcs_3_4__atom {
  class:  one rfcs_3_4__atom_class,
  compat: one rdsc_9_4__compat_mode
}

//@spec [LDET.1.10]
// A reader, characterised by the atoms it knows. No version axis: DS carries
// one version, the DS version, and a reader outside the series is refused
// before any atom is read.
sig ldet_1_10__reader { knows: set rfcs_3_4__atom }

//@spec [LDET.1.10]
// The atoms unknown to a reader: everything outside `knows`.
fun ldet_1_10__unknown : ldet_1_10__reader -> rfcs_3_4__atom {
  { r: ldet_1_10__reader, a: rfcs_3_4__atom | a not in r.knows }
}

//@spec [RFCS.3.4]
// The load-bearing safety rule: an inject-class atom is never skip-on-unknown.
// Skipping an inject atom drops a real input ([RFCS.3.4]), so an unknown inject
// atom forces a reject ([RFCS.18.8]), not the [RDSC.9.4] default skip.
fact rfcs_3_4__inject_never_skip_eligible {
  all a: rfcs_3_4__atom | a.class = inject implies a.compat = reject_unknown
}

//@spec [LDET.1.10]
// A reader accepts a stream (the atoms it meets) iff no atom unknown to it is a
// reject-gate atom — every unknown atom is skip-safe ([RDSC.9.4]).
pred ldet_1_10__accepts[r: ldet_1_10__reader, stream: set rfcs_3_4__atom] {
  no a: stream & r.ldet_1_10__unknown | a.compat = reject_unknown
}

//@probe
// A non-trivial scenario: a reader accepts a stream while skipping a compare or
// structural atom it does not know.
run probe__consistent {
  some r: ldet_1_10__reader, stream: set rfcs_3_4__atom |
    (some stream & r.ldet_1_10__unknown) and ldet_1_10__accepts[r, stream]
} for 6

// SAFETY: whenever a reader accepts a stream, no atom it skips (unknown +
// skip_unknown) is inject-class — it never silently drops a real input. NO
// counterexample.
assert rfcs_3_4__no_inject_silently_dropped {
  all r: ldet_1_10__reader, stream: set rfcs_3_4__atom |
    ldet_1_10__accepts[r, stream] implies
      (no a: stream & r.ldet_1_10__unknown | a.class = inject)
}
//@derives [RFCS.3.4]
check rfcs_3_4__no_inject_silently_dropped for 6

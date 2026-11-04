/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS Rete refraction — two-level identity key model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_iret_11_3__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. A terminal's refraction set is keyed by TOKEN IDENTITY — the tuple of
 * participating fact ids — and the 32-bit token hash is a PRE-FILTER, not the key: an
 * activation is refracted only when its hash matches a set entry AND its fact-id tuple
 * matches that entry's ([IRET.11.3]). Keying by hash alone lets two DISTINCT activations
 * whose tokens collide on the 32-bit hash cross-suppress — the second wrongly treated as
 * already-fired, its RHS never running — which made a batched build derive fewer facts
 * than the incremental one, breaking batched=incremental confluence ([IRET.11.3.3];
 * the RETEHASH1d bug). This model proves the two-level key suppresses re-fires yet never
 * suppresses a distinct-tuple activation across a hash collision.
 *
 * TEETH: drop `iret_11_3__suppress_iff_identity_refracted` and both checks fail — a hash
 * collision cross-suppresses a distinct activation (RETEHASH1d), and a genuine re-fire
 * escapes suppression (double-fire).
 */
module ds/refraction_identity

//@spec [IRET.11.3]
// A token identity: the tuple of participating fact ids for an activation.
sig iret_11_3__tuple {}

//@spec [IRET.11.3]
// A 32-bit token hash value — the pre-filter, computed from the tuple. Distinct tuples
// MAY share a hash (a collision); the same tuple always hashes the same.
sig iret_11_3__hash {}

//@spec [IRET.11.3]
// An activation of a terminal: its token identity (tuple) and that token's hash.
sig iret_11_3__activation {
  tuple: one iret_11_3__tuple,
  hash:  one iret_11_3__hash
}

//@spec [IRET.11.3]
// The hash is determined by the tuple (same tuple => same hash). It is only a
// pre-filter, so distinct tuples may still collide on one hash.
fact iret_11_3__hash_determined_by_tuple {
  all disj a, b: iret_11_3__activation | a.tuple = b.tuple implies a.hash = b.hash
}

//@spec [IRET.11.3]
// The refraction set: activations whose token identity has already fired and not
// been re-created since ([IRET.11.3.2]; a pump boundary or a tick does not end
// that). The model is a snapshot, so the clearing is outside it.
sig iret_11_3__fired in iret_11_3__activation {}

//@spec [IRET.11.3]
// An activation is refracted only when BOTH its hash matches a fired entry AND its
// fact-id tuple matches that entry's — the two-level key, not hash alone.
pred iret_11_3__refracted[a: iret_11_3__activation] {
  some f: iret_11_3__fired | f.hash = a.hash and f.tuple = a.tuple
}

//@spec [IRET.11.3]
// The activations the engine skips at agenda-selection time.
sig iret_11_3__suppressed in iret_11_3__activation {}

//@spec [IRET.11.3]
// The engine suppresses EXACTLY the identity-refracted activations (hash + tuple),
// never the hash-only ones.
fact iret_11_3__suppress_iff_identity_refracted {
  all a: iret_11_3__activation | a in iret_11_3__suppressed iff iret_11_3__refracted[a]
}

//@probe
// A hash collision is correctly distinguished: two activations share a hash but carry
// different tuples; one has fired, yet the other is NOT suppressed (its distinct
// identity is preserved). Satisfiable.
run probe__hash_collision_distinguished {
  some disj a1, a2: iret_11_3__activation |
    a1.hash = a2.hash and a1.tuple != a2.tuple
    and a1 in iret_11_3__fired and a2 not in iret_11_3__fired
    and a2 not in iret_11_3__suppressed
} for 6

// CONFLUENCE / NO CROSS-SUPPRESSION: a suppressed activation shares its full token
// identity (tuple) with a fired one — a mere hash collision never suppresses a distinct
// activation ([IRET.11.3.3], the RETEHASH1d fix). NO counterexample.
assert iret_11_3_3__no_distinct_activation_suppressed {
  all a: iret_11_3__suppressed | some f: iret_11_3__fired | f.tuple = a.tuple
}
//@spec [IRET.11.3.3]
check iret_11_3_3__no_distinct_activation_suppressed for 6

// REFRACTION WORKS: an activation whose exact identity (hash + tuple) already fired IS
// suppressed — no double-fire ([IRET.11.3]). NO counterexample.
assert iret_11_3__refire_is_suppressed {
  all a: iret_11_3__activation |
    (some f: iret_11_3__fired | f.hash = a.hash and f.tuple = a.tuple)
      implies a in iret_11_3__suppressed
}
//@spec [IRET.11.3]
check iret_11_3__refire_is_suppressed for 6

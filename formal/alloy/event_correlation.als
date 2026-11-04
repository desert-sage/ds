/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS event_id — the deterministic, engine-local derivation (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lfst_5_6__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. An `event_id` is a DETERMINISTIC UUID derived from the key
 * (run identifier, tier identifier, seq) ([LFST.5.6]): the two identifiers are
 * what the integrator gave the engine (NLFC.1.2) and either may be absent; `seq`
 * is the FactAssert's. Distinct keys derive distinct ids ([RARC.5.8.8]), and
 * every event's id is the derivation of its OWN key: an engine takes no event_id
 * from outside, and no event_id correlates two streams.
 *
 * WHAT IS CHECKED. Three consequences, each resting on two facts jointly, none a
 * restatement of one:
 *   - rarc_5_8_8__same_key_same_id: two events with one key carry one event_id,
 *     which is what makes replay reproduce it. Rests on rarc_5_8_8__stamp and
 *     lfst_5_6__coords_are_their_key: the key IS the coordinates, so nothing but
 *     the triple reaches the derivation. A hidden input -- a clock, /dev/urandom
 *     -- is exactly what the clause forbids (LDET.6.4.2).
 *   - lfst_5_6__tiers_never_share_an_event_id: two tiers sharing a run carry
 *     distinct ids at any seq, the tier being in the key. Rests on
 *     rarc_5_8_8__stamp and lfst_5_6__derive_injective.
 *   - lfst_5_6__seq_alone_distinguishes: with neither identifier given, different
 *     seq, different ids. Rests on rarc_5_8_8__stamp and lfst_5_6__derive_injective.
 * The probes carry the consistency claim and show the antecedents satisfiable:
 * two tiers on one run at one seq; an engine given neither identifier; a
 * recording and its replay.
 *
 * WHAT IS NOT MODELLED. Engines and streams. "Means nothing outside the engine
 * that stamped it" is here the absence of any relation between events but their
 * keys: no event's id comes from another event. Whether two engines were given
 * the same identifiers is the integrator's ([LFST.5.6]); the model says nothing
 * of it, and nothing of what an equal id in two streams would mean, because the
 * clause says it means nothing.
 *
 * TEETH, each run once on a copy with one fact removed (on the unchanged model
 * every probe is an instance and every check is without counterexample):
 *   - without lfst_5_6__coords_are_their_key: same_key_same_id fails
 *     -- two coords with one triple, neither identifier and one seq, derive to
 *     two ids, a hidden input -- and the other two checks and the probes hold;
 *   - without lfst_5_6__derive_injective: tiers_never_share_an_event_id
 *     fails -- two tiers, one seq, one id -- and seq_alone_distinguishes fails --
 *     two seq, no identifier, one id -- and same_key_same_id holds;
 *   - without rarc_5_8_8__stamp: all three fail -- the ids are free
 *     of the key -- and the probes still hold.
 *
 * (`run` and `seq` are Alloy keywords, so the key's fields are `run_id`, `tier_id`
 * and `seq_no`.)
 */
module ds/event_correlation

//@spec [LFST.5.6]
// The run identifier the integrator gave the engine (NLFC.1.2); may be absent.
sig lfst_5_6__run {}

//@spec [LFST.5.6]
// The tier identifier the integrator gave the engine (NLFC.1.2); may be absent.
sig lfst_5_6__tier {}

//@spec [LFST.5.6]
// A FactAssert's seq.
sig lfst_5_6__seq {}

//@spec [LFST.5.6]
// A derivation key: the replay-reproducible triple (run identifier, tier
// identifier, seq), either identifier possibly absent.
sig lfst_5_6__coords {
  run_id:  lone lfst_5_6__run,
  tier_id: lone lfst_5_6__tier,
  seq_no:  one  lfst_5_6__seq
}

//@spec [LFST.5.6]
// The key IS the coordinates: two keys that agree on the triple are one key, so
// nothing but the triple reaches the derivation.
fact lfst_5_6__coords_are_their_key {
  all disj c1, c2: lfst_5_6__coords |
    c1.run_id != c2.run_id or c1.tier_id != c2.tier_id or c1.seq_no != c2.seq_no
}

//@spec [LFST.5.6]
// A deterministic event_id UUID.
sig lfst_5_6__event_id {}

//@spec [LFST.5.6]
// The deterministic derivation function coords -> event_id.
one sig lfst_5_6__derive { of: lfst_5_6__coords -> one lfst_5_6__event_id }

//@spec [LFST.5.6]
// Collision-safe: distinct keys derive distinct event_ids ([RARC.5.8.8]).
fact lfst_5_6__derive_injective {
  all disj c1, c2: lfst_5_6__coords | lfst_5_6__derive.of[c1] != lfst_5_6__derive.of[c2]
}

//@spec [RARC.5.8.8]
// An event: a FactAssert with its key and its stamped event_id.
sig rarc_5_8_8__event {
  coords:   one lfst_5_6__coords,
  event_id: one lfst_5_6__event_id
}

//@spec [RARC.5.8.8]
// Stamp rule: every event's event_id is the derivation of its OWN key -- a fact
// received from another tier included. No event takes an id from outside.
fact rarc_5_8_8__stamp {
  all e: rarc_5_8_8__event | e.event_id = lfst_5_6__derive.of[e.coords]
}

//@probe
// Two tiers sharing one run, each at the same seq, each with its own event_id.
run probe__two_tiers_one_run {
  some disj a, b: rarc_5_8_8__event {
    some a.coords.run_id
    a.coords.run_id = b.coords.run_id
    some a.coords.tier_id
    some b.coords.tier_id
    a.coords.tier_id != b.coords.tier_id
    a.coords.seq_no = b.coords.seq_no
    a.event_id != b.event_id
  }
} for 6

//@probe
// An engine given neither identifier: two events at different seq, two ids.
run probe__neither_identifier {
  some disj a, b: rarc_5_8_8__event {
    no a.coords.run_id
    no a.coords.tier_id
    no b.coords.run_id
    no b.coords.tier_id
    a.coords.seq_no != b.coords.seq_no
    a.event_id != b.event_id
  }
} for 6

//@probe
// A recording and its replay: two events with one key carry one event_id.
run probe__replay {
  some disj a, b: rarc_5_8_8__event | a.coords = b.coords and a.event_id = b.event_id
} for 6

// REPLAY REPRODUCES THE ID. Two events with one key carry one event_id: the
// derivation reads the key and nothing else. Rests on rarc_5_8_8__stamp and
// lfst_5_6__coords_are_their_key jointly. NO counterexample.
assert rarc_5_8_8__same_key_same_id {
  all a, b: rarc_5_8_8__event |
    (a.coords.run_id = b.coords.run_id and a.coords.tier_id = b.coords.tier_id
      and a.coords.seq_no = b.coords.seq_no)
      implies a.event_id = b.event_id
}
//@derives [RARC.5.8.8]
check rarc_5_8_8__same_key_same_id for 6

// TIERS NEVER SHARE AN ID. Two events whose keys differ in the tier identifier
// alone -- one run, one seq -- carry distinct event_ids: the tier is in the key.
// Rests on rarc_5_8_8__stamp and lfst_5_6__derive_injective jointly. NO
// counterexample.
assert lfst_5_6__tiers_never_share_an_event_id {
  all a, b: rarc_5_8_8__event |
    (a.coords.run_id = b.coords.run_id and a.coords.seq_no = b.coords.seq_no
      and a.coords.tier_id != b.coords.tier_id)
      implies a.event_id != b.event_id
}
//@derives [LFST.5.6]
check lfst_5_6__tiers_never_share_an_event_id for 6

// SEQ ALONE DISTINGUISHES. With neither identifier given, two events at
// different seq carry distinct event_ids. Rests on rarc_5_8_8__stamp and
// lfst_5_6__derive_injective jointly. NO counterexample.
assert lfst_5_6__seq_alone_distinguishes {
  all a, b: rarc_5_8_8__event |
    (no a.coords.run_id and no a.coords.tier_id and no b.coords.run_id and no b.coords.tier_id
      and a.coords.seq_no != b.coords.seq_no)
      implies a.event_id != b.event_id
}
//@derives [LFST.5.6]
check lfst_5_6__seq_alone_distinguishes for 6

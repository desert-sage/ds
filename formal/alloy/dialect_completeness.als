/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS dialect definitions — what the loader accepts, and why it derives nothing
 * (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_ndlc_2_2__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE RULE. A dialect definition's `settings` map must set every capability of the
 * registry and name nothing else, and what it sets must satisfy the fundamental
 * constraints; the loader derives nothing ([NDLC.2.2], [LCAP.3.8]). The model takes
 * a definition AS WRITTEN -- any keys, some perhaps missing -- and a registry, and
 * states the three refusals. A definition is accepted when none of them applies.
 * There is no repair step to model, and that absence is the rule.
 *
 * WHAT IS DERIVED, beyond the rule said a second way:
 *   - the `true` settings of an accepted definition are closed under the
 *     constraints taken any number of steps, though the table states one step;
 *   - a definition pins its registry: accepted against two registries, the two
 *     have the same capabilities. So when a capability is added, every
 *     definition written before it is refused as incomplete -- the loud failure
 *     [NDLC.2.2] asks for, which a loader that defaulted an unset key would not
 *     give.
 *
 * NOT MODELLED. Which capabilities exist and which constraints hold among them:
 * a registry here is any set of keys with any constraint relation over it. The
 * registry of [LCAP.1], the table of [LCAP.3.8] and the dialects the corpus
 * writes out in full are `dialect_capability.als`'s. Also not modelled: the YAML
 * surface (`name`, a syntax error) and the duplicate-name refusal of [NDLC.6.1].
 *
 * TEETH, each run once on a copy with one line of `ndlc_2_2__accepted` removed.
 * Without the `incomplete` line -- a loader that defaults what is unset -- the
 * exactness, pinning and new-capability checks fail and the closure check holds.
 * Without the `unknown_capability` line the same three fail. Without the
 * `violated` line the closure check alone fails.
 */
module ds/dialect_completeness

//@spec [NDLC.2.2]
// A key a `settings` map may carry. Whether it names a capability is a question
// about the registry the definition is loaded against, not about the key.
sig ndlc_2_2__key {}

//@spec [LCAP.3.8]
// A capability registry: the keys that are capabilities ([LCAP.1]) and the
// fundamental constraints among them. `needs` holds one pair per row of the
// constraint table: if the first is `true`, the second must be `true`.
sig lcap_3_8__registry {
  caps:  set ndlc_2_2__key,
  needs: ndlc_2_2__key -> ndlc_2_2__key
}

//@spec [LCAP.3.8]
// A constraint relates two capabilities of the registry it belongs to.
fact lcap_3_8__constraints_name_capabilities {
  all r: lcap_3_8__registry | r.needs in r.caps -> r.caps
}

//@spec [NDLC.2.2]
// A dialect definition as written: the keys its `settings` map sets `true` and
// the keys it sets `false`. A map gives a key one value, so the two are disjoint.
// Nothing else is assumed of it: it may leave a capability out, and it may carry
// a key the registry does not have.
sig ndlc_2_2__definition {
  on:  set ndlc_2_2__key,
  off: set ndlc_2_2__key
} { no on & off }

//@spec [NDLC.2.2]
// DS_VALIDATE_DIALECT_INCOMPLETE: a capability of the registry is left unset.
pred ndlc_2_2__incomplete[d: ndlc_2_2__definition, r: lcap_3_8__registry] {
  some r.caps - (d.on + d.off)
}

//@spec [NDLC.2.2]
// DS_VALIDATE_DIALECT_UNKNOWN_CAPABILITY: a key names no capability of the registry.
pred ndlc_2_2__unknown_capability[d: ndlc_2_2__definition, r: lcap_3_8__registry] {
  some (d.on + d.off) - r.caps
}

//@spec [LCAP.3.8]
// DS_VALIDATE_DIALECT_DEPENDENCY: a capability is set `true` and one it needs is
// not set `true`.
pred lcap_3_8__violated[d: ndlc_2_2__definition, r: lcap_3_8__registry] {
  some c: d.on | some c.(r.needs) - d.on
}

//@spec [NDLC.2.2]
// The loader accepts a definition it refuses for none of the three reasons. It
// judges the map as written and changes nothing in it.
pred ndlc_2_2__accepted[d: ndlc_2_2__definition, r: lcap_3_8__registry] {
  not ndlc_2_2__incomplete[d, r]
  not ndlc_2_2__unknown_capability[d, r]
  not lcap_3_8__violated[d, r]
}

//@probe
// An accepted definition with both values in it, against a registry whose
// constraint is in play: a capability that needs another is set `true`.
run probe__accepted {
  some d: ndlc_2_2__definition, r: lcap_3_8__registry |
    ndlc_2_2__accepted[d, r] and some d.off and some d.on & (r.needs).univ
} for 5

//@probe
// Each refusal can be the only one: they are three conditions, not one.
run probe__incomplete_alone {
  some d: ndlc_2_2__definition, r: lcap_3_8__registry |
    ndlc_2_2__incomplete[d, r] and not ndlc_2_2__unknown_capability[d, r]
    and not lcap_3_8__violated[d, r]
} for 5

//@probe
run probe__unknown_capability_alone {
  some d: ndlc_2_2__definition, r: lcap_3_8__registry |
    ndlc_2_2__unknown_capability[d, r] and not ndlc_2_2__incomplete[d, r]
    and not lcap_3_8__violated[d, r]
} for 5

//@probe
run probe__violated_alone {
  some d: ndlc_2_2__definition, r: lcap_3_8__registry |
    lcap_3_8__violated[d, r] and not ndlc_2_2__incomplete[d, r]
    and not ndlc_2_2__unknown_capability[d, r]
} for 5

//@probe
// A registry can grow under an accepted definition: the two checks about a
// changed registry have something to be about.
run probe__registry_grows {
  some d: ndlc_2_2__definition, r, s: lcap_3_8__registry |
    ndlc_2_2__accepted[d, r] and r.caps in s.caps and r.caps != s.caps
} for 5

// EXACTLY THE CAPABILITIES, EACH ONCE: an accepted definition's keys are the
// registry's capabilities and nothing else, and each has one value. Nothing was
// filled in to make it so: the map as written is already total. This is the rule
// said a second way, a check on the transcription. NO counterexample.
assert ndlc_2_2__accepted_sets_exactly_the_capabilities {
  all d: ndlc_2_2__definition, r: lcap_3_8__registry |
    ndlc_2_2__accepted[d, r] implies (d.on + d.off = r.caps and no d.on & d.off)
}
//@spec [NDLC.2.2]
check ndlc_2_2__accepted_sets_exactly_the_capabilities for 6

// CLOSED UNDER THE CONSTRAINTS: whatever a `true` capability needs, through any
// number of rows of the table, is `true` in an accepted definition. The table
// and the refusal state one step. NO counterexample.
assert lcap_3_8__true_settings_are_closed {
  all d: ndlc_2_2__definition, r: lcap_3_8__registry |
    ndlc_2_2__accepted[d, r] implies d.on.^(r.needs) in d.on
}
//@derives [LCAP.3.8]
check lcap_3_8__true_settings_are_closed for 6

// A DEFINITION PINS ITS REGISTRY: accepted against two registries, the two have
// the same capabilities. A definition cannot survive a change to the set of
// capabilities, in either direction. NO counterexample.
assert ndlc_2_2__a_definition_pins_its_registry {
  all d: ndlc_2_2__definition, r, s: lcap_3_8__registry |
    (ndlc_2_2__accepted[d, r] and ndlc_2_2__accepted[d, s]) implies r.caps = s.caps
}
//@derives [NDLC.2.2]
check ndlc_2_2__a_definition_pins_its_registry for 6

// A NEW CAPABILITY IS A LOUD FAILURE: every definition accepted before the
// registry gained a capability is refused after it, and as INCOMPLETE -- it
// takes no value for the new capability by omission. It needs both halves of
// "exactly": the unset key is refused, and the old definition could not have
// named a capability the registry did not yet have. NO counterexample.
assert ndlc_2_2__a_new_capability_refuses_every_old_definition {
  all d: ndlc_2_2__definition, r, s: lcap_3_8__registry |
    (ndlc_2_2__accepted[d, r] and r.caps in s.caps and r.caps != s.caps)
      implies (not ndlc_2_2__accepted[d, s] and ndlc_2_2__incomplete[d, s])
}
//@derives [NDLC.2.2]
check ndlc_2_2__a_new_capability_refuses_every_old_definition for 6

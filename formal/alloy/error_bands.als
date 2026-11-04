/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS error-code values — the integer is the identity; retired values stay dead (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_nerr_10_2__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. A status is an integer drawn from one dictionary, and the number is
 * the identity ([LERR.8.1]): one value, one meaning, whatever an implementation calls
 * it. The -600 decade holds two families — the native-Rete loader / runtime at
 * -600..-610 and the series-backend ABI at -620..-625 — and they do not collide
 * ([NERR.10.2]: "the integer alone identifies the error … these values do not collide
 * with the native-Rete loader codes"), so a produced value says by itself which call
 * surface produced it: backend-ABI codes come only from backend registration, never
 * from the Rete loader. And the retired ranges — -300..-399 ([NERR.3.2]), -508..-513
 * and -520..-527 ([IERR.2.8a], `reserved` in proto/status.proto) — have no dictionary
 * entry and are never produced, an instance of [STYL.2.8.7].
 *
 * WHAT THIS MODEL USED TO SAY, and why it changed. It formalised a
 * register in which the two families SHARED -600..-605 and a bare integer meant two
 * things, "disambiguated only by the originating call"; its checks restated that
 * overlap, so they stayed green after the register moved to disjoint ranges. That
 * model proved a property of an allocation the corpus has withdrawn. This one proves
 * the property the corpus now states: no origin is needed, and the origin is
 * derivable from the value.
 *
 * TEETH: drop `lerr_8_1__number_is_identity` and `nerr_10_2__integer_alone_identifies`
 * fails — one value produced twice with two meanings. Drop
 * `nerr_10_2__values_do_not_collide` and `nerr_10_2__backend_codes_only_from_registration`
 * fails — a value with an entry on both surfaces lets the Rete loader produce a
 * backend-ABI code. Drop `nerr_3_2__retired_has_no_entry` and
 * `nerr_3_2__no_retired_reused` fails.
 */
module ds/error_bands

//@spec [NERR.10.2]
// A numeric error-code value.
sig nerr_10_2__value {}

//@spec [NERR.10.2]
// A distinct error meaning (a specific fault condition: WM_FULL, BACKEND_ABI_VERSION, …).
sig nerr_10_2__meaning {}

//@spec [NERR.10.2]
// The two call surfaces of the -600 decade: the native-Rete loader / runtime, and
// series-backend registration.
abstract sig nerr_10_2__surface {}

//@spec [NERR.10.2]
one sig nerr_10_2__rete_loader extends nerr_10_2__surface {}

//@spec [NERR.10.2]
one sig nerr_10_2__backend_registration extends nerr_10_2__surface {}

//@spec [LERR.8.1]
// The dictionary: a value, what it means, and the surface that allocates it. The
// name an implementation gives the value is a label and is not modelled.
sig lerr_8_1__entry {
  value:   one nerr_10_2__value,
  means:   one nerr_10_2__meaning,
  surface: one nerr_10_2__surface
}

//@spec [LERR.8.1]
// The number is the identity: two entries for one value mean one thing.
fact lerr_8_1__number_is_identity {
  all disj e1, e2: lerr_8_1__entry | e1.value = e2.value implies e1.means = e2.means
}

//@spec [NERR.10.2]
// The families do not collide: two entries for one value sit on one surface. This is
// the disjointness of -600..-610 and -620..-625 as a fact about the register.
fact nerr_10_2__values_do_not_collide {
  all disj e1, e2: lerr_8_1__entry | e1.value = e2.value implies e1.surface = e2.surface
}

//@spec [NERR.10.2]
// A produced error result: the value returned and the surface that returned it.
sig nerr_10_2__result {
  value:  one nerr_10_2__value,
  origin: one nerr_10_2__surface
}

//@spec [NERR.10.2]
// A result is a dictionary entry produced on its own surface: backend-ABI codes come
// only from backend registration, Rete codes only from the loader / runtime.
fact nerr_10_2__produced_on_its_surface {
  all r: nerr_10_2__result |
    some e: lerr_8_1__entry | e.value = r.value and e.surface = r.origin
}

//@spec [LERR.8.1]
// What a value means, read off the dictionary.
fun lerr_8_1__meaning_of[v: nerr_10_2__value]: set nerr_10_2__meaning {
  { m: nerr_10_2__meaning | some e: lerr_8_1__entry | e.value = v and e.means = m }
}

//@spec [NERR.3.2]
//@spec [STYL.2.8.7]
// Retired values — -300..-399, -508..-513, -520..-527 — permanently reserved: an
// instance of the reserved-allocation discipline.
one sig nerr_3_2__retired { vals: set nerr_10_2__value }

//@spec [NERR.3.2]
// A retired value has no dictionary entry: the name is gone and the value stays dead.
fact nerr_3_2__retired_has_no_entry {
  no e: lerr_8_1__entry | e.value in nerr_3_2__retired.vals
}

//@probe
// Both families populated on one register, results produced on both surfaces, a
// retired range beside them — and every produced value means exactly one thing.
run probe__two_surfaces_one_register {
  some disj e1, e2: lerr_8_1__entry | e1.surface != e2.surface
  some r: nerr_10_2__result | r.origin = nerr_10_2__backend_registration
  some r: nerr_10_2__result | r.origin = nerr_10_2__rete_loader
  some nerr_3_2__retired.vals
} for 6

// THE INTEGER ALONE IDENTIFIES THE ERROR: every produced value means exactly one
// thing, whichever surface produced it — no call is needed to read a result. NO
// counterexample.
assert nerr_10_2__integer_alone_identifies {
  all r: nerr_10_2__result | one lerr_8_1__meaning_of[r.value]
}
//@derives [NERR.10.2]
check nerr_10_2__integer_alone_identifies for 6

// THE ORIGIN IS DERIVABLE FROM THE VALUE: two results carrying one value came from
// one surface. What the old register needed the call to supply, the value now
// carries. NO counterexample.
assert nerr_10_2__origin_follows_the_value {
  all disj r1, r2: nerr_10_2__result | r1.value = r2.value implies r1.origin = r2.origin
}
//@derives [NERR.10.2]
check nerr_10_2__origin_follows_the_value for 6

// BACKEND-ABI CODES COME ONLY FROM REGISTRATION: a result whose value the backend
// surface allocated was produced by backend registration, never by the Rete loader.
// NO counterexample.
assert nerr_10_2__backend_codes_only_from_registration {
  all r: nerr_10_2__result |
    (some e: lerr_8_1__entry |
       e.value = r.value and e.surface = nerr_10_2__backend_registration)
    implies r.origin = nerr_10_2__backend_registration
}
//@derives [NERR.10.2]
check nerr_10_2__backend_codes_only_from_registration for 6

// VACATED: no error result ever carries a retired value — a result needs an entry and
// a retired value has none ([STYL.2.8.7]). NO counterexample.
assert nerr_3_2__no_retired_reused {
  no r: nerr_10_2__result | r.value in nerr_3_2__retired.vals
}
//@derives [NERR.3.2]
check nerr_3_2__no_retired_reused for 6

/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS dialects and capabilities — the registry, the constraints, the dialects the
 * corpus writes out, and how a `use` block resolves (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_ldia_1_1__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * WHAT THIS MODEL IS. A dialect is a setting of every capability to `true` or
 * `false` ([LDIA.1.1]). A program's resolved settings are its dialect's with the
 * lines of its `use` block applied ([LDIA.1.3], [LDIA.3.3.1]). They must satisfy
 * the fundamental constraints, and the compiler switches nothing on or off to
 * make them ([LDIA.3.5.1], [LCAP.3.8]). A construct is permitted when no
 * restricting setting forbids it ([LCAP.3.5]). The registry of [LCAP.1], the
 * constraint table and four dialects are TRANSCRIBED here, name by name and row
 * by row: the three built-in dialects of [LDIA.9], and `frame`, the example
 * [NDLC.2.1] gives.
 *
 * WHAT IS CHECKED AGAINST THE TRANSCRIPTIONS, which is where one clause could be
 * wrong about another:
 *   - each written dialect sets every capability of the registry, once;
 *   - each written dialect satisfies every constraint;
 *   - `realtime` differs from `default` in `realtime` and `constspace` alone,
 *     and so leaves `linear_scan` `true`, as [LDIA.9.3] says of a dialect it
 *     defines by reference;
 *   - `use default` with `realtime: true` and nothing else is refused: the
 *     compiler does not turn `constspace` on for the author ([LCAP.3.7]);
 *   - the four deferred storage and samples-plane capabilities of [LCAP.2.10]
 *     are `false` in every written dialect.
 * The remaining checks say a definition a second way, and are tagged as such.
 *
 * NOT MODELLED. What each capability permits or selects in the engine ([LCAP.2]):
 * a construct here is anything at all, with any set of capabilities able to
 * forbid it. That resolved settings never change a result ([LDET.1.12], which
 * [LDIA.1.3] cites). Imports and libraries ([LDIA.2.10]); the unknown and the
 * twice-named capability in a `use` block ([LDIA.3.3.2], [LDIA.3.3.6]); the
 * artefact's `requires` ([RDSC.16.2]). The loader's rule for a dialect
 * definition, over any registry, is `dialect_completeness.als`'s. The two
 * deferral refusals, [LCAP.2.1.5]'s on a `use` line or dialect setting
 * `realtime` or `constspace` `true` and [LCAP.2.10]'s on one setting a deferred
 * storage or samples-plane capability `true`: the model states the algebra of
 * the settings, as [LCAP.5] does, and
 * `probe__default_with_realtime_and_constspace_passes` is a block that edition
 * refuses at the line. What is checked of [LCAP.2.10] is the written dialects'
 * side, that each sets the four `false`.
 *
 * TEETH, each run once on a copy with one line removed. Without `default`'s
 * `+ float` line the every-capability check fails. Without its `+ call` line
 * that check and the constraints check both fail, and the probe that `use
 * default` with `realtime` and `constspace` turned on passes finds no
 * instance: `nocooldown` is left needing a capability nothing sets. With
 * `sampled_slots` moved to `default`'s `true` row the deferred-false check
 * fails and nothing else does.
 * Without the `realtime -> constspace` row the two checks that refuse
 * `realtime` without `constspace` fail. Without the `- u.turns_off` line of
 * the resolution the overrule check fails. With `realtime` changing a third
 * setting (`dynamic_ttl` moved with the other two) the two-settings check
 * fails and nothing else does; with `linear_scan` moved to `default`'s
 * `false` row it fails again, on its other conjunct, and nothing else does.
 * With `no` read as `some` in `ldia_1_3__permitted` -- permitted taken for
 * forbidden -- the composition check fails, and the probe that more
 * restriction permits less finds no instance: the definition said a second
 * way pins its polarity.
 */
module ds/dialect_capability

// ── the registry ─────────────────────────────────────────────────────────────

//@spec [LCAP.1]
// A registered capability: a boolean setting with a stable name. The members are
// the registry, under their stable names, in the enumeration's order. The first
// three are the strategy capabilities; every other is a construct capability.
// Four numbers are retired and reserved, so none is a member, no dialect can
// set one and no `use` block can name one: 12, `record_event`, with its
// action; 17, 18 and 19, `storage_sample_latest`, `storage_sample_agg` and
// `storage_event_query`, which gated storage queries the language does not
// have. Number 20 is `storage_hydrate_facts`, named for the service it gates;
// the name it held before is reserved. Seventeen members.
abstract sig lcap_1__capability {}
one sig realtime, constspace, linear_scan extends lcap_1__capability {}
one sig logical, dynamic_ttl, regex, float extends lcap_1__capability {}
one sig call, publish, cache, cache_delete, nocooldown extends lcap_1__capability {}
one sig series, sampled_slots, persist_on_series extends lcap_1__capability {}
one sig storage_hydrate_facts, storage_hydrate_samples extends lcap_1__capability {}

//@spec [LCAP.2.10]
// The four deferred storage and samples-plane capabilities, as the clause's
// table lists them: registered, and `false` in every program and dialect of
// this edition.
fun lcap_2_10__deferred: set lcap_1__capability {
    sampled_slots
  + persist_on_series
  + storage_hydrate_facts
  + storage_hydrate_samples
}

//@spec [LCAP.3.8]
// The fundamental constraints, one row of the table per line: if the first is
// `true`, the second must be `true`. The order of the rows carries nothing.
fun lcap_3_8__needs: lcap_1__capability -> lcap_1__capability {
    storage_hydrate_facts -> call
  + storage_hydrate_samples -> call
  + nocooldown -> call
  + persist_on_series -> series
  + realtime -> constspace
}

//@spec [LCAP.3.8]
// A setting, given as the set that is `true`, satisfies the constraints when
// everything a `true` capability needs is `true`.
pred lcap_3_8__satisfied[t: set lcap_1__capability] { t.lcap_3_8__needs in t }

// ── the dialects the corpus writes out ───────────────────────────────────────

//@spec [LDIA.1.1]
// A dialect as its clause writes it out: the capabilities it sets `true` and the
// capabilities it sets `false`. That the two are a setting of EVERY capability,
// each once, is checked below and not assumed.
abstract sig ldia_1_1__dialect { sets_true, sets_false: set lcap_1__capability }
one sig dialect_base, dialect_default, dialect_realtime, dialect_frame extends ldia_1_1__dialect {}

//@spec [LDIA.9.1]
// `base` sets every capability `false`.
fact ldia_9_1__base {
  no dialect_base.sets_true
  dialect_base.sets_false = lcap_1__capability
}

//@spec [LDIA.9.2]
// `default`, as the clause's table has it: the `true` row, one capability per
// line in the row's order, then the `false` row.
fact ldia_9_2__default {
  dialect_default.sets_true =
      call
    + publish
    + cache
    + cache_delete
    + nocooldown
    + regex
    + series
    + logical
    + linear_scan
    + float
  dialect_default.sets_false =
      realtime
    + constspace
    + dynamic_ttl
    + sampled_slots
    + persist_on_series
    + storage_hydrate_facts
    + storage_hydrate_samples
}

//@spec [LDIA.9.3]
// `realtime` has `default`'s settings with `realtime: true` and `constspace: true`.
fact ldia_9_3__realtime {
  dialect_realtime.sets_true = dialect_default.sets_true + realtime + constspace
  dialect_realtime.sets_false = dialect_default.sets_false - realtime - constspace
}

//@spec [NDLC.2.1]
// `frame`, the example the clause gives of a definition with all its fields: its
// `settings` map, the keys set `true` and then the keys set `false`.
fact ndlc_2_1__frame {
  dialect_frame.sets_true = linear_scan + logical + regex + float + call + publish
      + cache + cache_delete + nocooldown
  dialect_frame.sets_false = realtime + constspace + dynamic_ttl + series + sampled_slots
      + persist_on_series + storage_hydrate_facts + storage_hydrate_samples
}

// ── a `use` block, and what it resolves to ───────────────────────────────────

//@spec [LDIA.3.3.1]
// A `use` directive: the dialect it names and the lines of its block, as the
// capabilities it turns on and those it turns off. A block names a capability at
// most once ([LDIA.3.3.6]), so the two are disjoint.
sig ldia_3_3_1__use {
  names:     one ldia_1_1__dialect,
  turns_on:  set lcap_1__capability,
  turns_off: set lcap_1__capability
} { no turns_on & turns_off }

//@spec [LDIA.1.3]
// The resolved settings, as the set that is `true`: the dialect's, with each line
// of the block replacing the dialect's setting for the capability it names.
fun ldia_1_3__resolved[u: ldia_3_3_1__use]: set lcap_1__capability {
  u.names.sets_true
    - u.turns_off
    + u.turns_on
}

//@spec [LDIA.3.5.1]
// The constraint check: the resolved settings satisfy every constraint, or the
// program is refused. What is judged is the resolved settings as the author
// wrote them; nothing is switched on or off first.
pred ldia_3_5_1__passes[u: ldia_3_3_1__use] {
  lcap_3_8__satisfied[ldia_1_3__resolved[u]]
}

// ── constructs, and the settings that forbid them ────────────────────────────

//@spec [LCAP.3.5]
// The settings that restrict, given the set that is `true`: `realtime` and
// `constspace` restrict when `true`, and every other capability, `linear_scan`
// among them, restricts when `false`.
fun lcap_3_5__restricting[t: set lcap_1__capability]: set lcap_1__capability {
  (t & (realtime + constspace)) + (lcap_1__capability - realtime - constspace - t)
}

//@spec [LDIA.1.3]
// A construct, and the capabilities whose restricting setting forbids it: the
// construct capability that permits it, and any strategy it cannot run under.
sig ldia_1_3__construct { barred_by: set lcap_1__capability }

//@spec [LDIA.1.3]
// The constructs a program with these settings may use: those no restricting
// setting forbids.
fun ldia_1_3__permitted[t: set lcap_1__capability]: set ldia_1_3__construct {
  { c: ldia_1_3__construct | no c.barred_by & lcap_3_5__restricting[t] }
}

// ── the model is about something ─────────────────────────────────────────────

//@probe
// A `use` block that turns something on and something off, and passes.
run probe__a_block_that_passes {
  some u: ldia_3_3_1__use |
    some u.turns_on and some u.turns_off and ldia_3_5_1__passes[u]
} for 4

//@probe
// A `use` block the constraint check refuses.
run probe__a_block_that_is_refused {
  some u: ldia_3_3_1__use | not ldia_3_5_1__passes[u]
} for 4

//@probe
// `use default` with `realtime: true` and `constspace: true` passes: what the
// refusal below turns on is `constspace`, and nothing else.
run probe__default_with_realtime_and_constspace_passes {
  some u: ldia_3_3_1__use |
    u.names = dialect_default and u.turns_on = realtime + constspace
    and no u.turns_off and ldia_3_5_1__passes[u]
} for 4

//@probe
// Two blocks, one restricting at least what the other does and permitting
// strictly less: the composition check below has something to be about.
run probe__more_restriction_permits_less {
  some u, v: ldia_3_3_1__use |
    lcap_3_5__restricting[ldia_1_3__resolved[u]] in lcap_3_5__restricting[ldia_1_3__resolved[v]]
    and some ldia_1_3__permitted[ldia_1_3__resolved[u]] - ldia_1_3__permitted[ldia_1_3__resolved[v]]
} for 4

// ── the transcriptions, checked against each other ───────────────────────────

// EVERY CAPABILITY, ONCE: each dialect the corpus writes out sets every
// capability of the registry, and none twice. NO counterexample.
assert ldia_1_1__each_written_dialect_sets_every_capability_once {
  all d: ldia_1_1__dialect |
    d.sets_true + d.sets_false = lcap_1__capability and no d.sets_true & d.sets_false
}
//@derives [LDIA.1.1]
check ldia_1_1__each_written_dialect_sets_every_capability_once for 4

// EVERY DIALECT SATISFIES THE CONSTRAINTS, as [LCAP.3.8] requires of every
// dialect's settings. NO counterexample.
assert lcap_3_8__each_written_dialect_satisfies_the_constraints {
  all d: ldia_1_1__dialect | lcap_3_8__satisfied[d.sets_true]
}
//@derives [LCAP.3.8]
check lcap_3_8__each_written_dialect_satisfies_the_constraints for 4

// `realtime` IS `default` AND TWO SETTINGS: it differs from `default` in
// `realtime` and `constspace` and nowhere else, so it leaves `linear_scan`
// `true`. Both depend on what `default`'s table says. NO counterexample.
assert ldia_9_3__realtime_changes_two_settings_of_default {
  dialect_realtime.sets_true - dialect_default.sets_true = realtime + constspace
  linear_scan in dialect_realtime.sets_true
}
//@derives [LDIA.9.3]
check ldia_9_3__realtime_changes_two_settings_of_default for 4

// THE DEFERRED FOUR ARE `false` IN EVERY WRITTEN DIALECT, as [LCAP.2.10] requires
// of every dialect of this edition: none of the four sets one `true`. The
// transcriptions of [LDIA.9] and [NDLC.2.1] checked against the table of
// [LCAP.2.10]. NO counterexample.
assert lcap_2_10__written_dialects_set_the_deferred_false {
  all d: ldia_1_1__dialect | no d.sets_true & lcap_2_10__deferred
}
//@derives [LCAP.2.10]
check lcap_2_10__written_dialects_set_the_deferred_false for 4

// NOTHING IS SWITCHED ON FOR THE AUTHOR: `use default` with `realtime: true` and
// no other line is refused, because `default` has `constspace: false` and the
// constraint check judges what was written. NO counterexample.
assert lcap_3_7__default_with_realtime_alone_is_refused {
  all u: ldia_3_3_1__use |
    (u.names = dialect_default and u.turns_on = realtime and no u.turns_off)
      implies not ldia_3_5_1__passes[u]
}
//@derives [LCAP.3.7]
check lcap_3_7__default_with_realtime_alone_is_refused for 4

// ── definitions, said a second way ───────────────────────────────────────────

// THE BLOCK OVERRULES THE DIALECT, AND NOTHING ELSE MOVES: a capability the
// block turns on is `true`, one it turns off is `false`, and one it does not
// name keeps the dialect's setting. NO counterexample.
assert ldia_1_3__the_block_overrules_and_nothing_else_moves {
  all u: ldia_3_3_1__use |
    u.turns_on in ldia_1_3__resolved[u]
    and no u.turns_off & ldia_1_3__resolved[u]
    and (all c: lcap_1__capability - u.turns_on - u.turns_off |
           c in ldia_1_3__resolved[u] iff c in u.names.sets_true)
}
//@spec [LDIA.1.3] [LDIA.3.3.1]
check ldia_1_3__the_block_overrules_and_nothing_else_moves for 4

// `realtime: true` WITHOUT `constspace: true` IS REFUSED, whatever dialect and
// block produced it. NO counterexample.
assert ldia_3_5_1__realtime_without_constspace_is_refused {
  all u: ldia_3_3_1__use |
    (realtime in ldia_1_3__resolved[u] and constspace not in ldia_1_3__resolved[u])
      implies not ldia_3_5_1__passes[u]
}
//@spec [LDIA.3.5.1] [LCAP.3.7]
check ldia_3_5_1__realtime_without_constspace_is_refused for 4

// SETTINGS COMPOSE BY INTERSECTION: settings that restrict at least as much
// permit no construct the others refuse. No setting relaxes what another
// imposes. It holds by the shape of `ldia_1_3__permitted`, which is why this
// is the definition said a second way. NO counterexample.
assert lcap_3_5__more_restriction_never_permits_more {
  all u, v: ldia_3_3_1__use |
    lcap_3_5__restricting[ldia_1_3__resolved[u]] in lcap_3_5__restricting[ldia_1_3__resolved[v]]
      implies ldia_1_3__permitted[ldia_1_3__resolved[v]] in ldia_1_3__permitted[ldia_1_3__resolved[u]]
}
//@spec [LCAP.3.5]
check lcap_3_5__more_restriction_never_permits_more for 4

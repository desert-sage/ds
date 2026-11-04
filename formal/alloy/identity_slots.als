/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS logical identity — KEY/MUTABLE slot-role partition model (Alloy 6), with
 * the engine-owned `ts` slot in its own role beside it.
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_rdsc_5_5_7__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker; enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. Each slot carries an identity_role — KEY, MUTABLE, ENGINE or
 * UNSPECIFIED ([RDSC.5.5.7]). It is a conditional partition on the schema's
 * lifecycle: on a `logical` schema every author slot is KEY or MUTABLE
 * (require-all, [LFAC.1.7.4]) and the `ts` slot ([LFAC.9.1]) is ENGINE, the role
 * of a slot the engine fills and authors never write ([LFAC.9.2], [LFAC.9.3]); on
 * a non-`logical` schema every slot, `ts` included, is UNSPECIFIED (a key/mutable
 * marker there is rejected, [LFAC.1.7.6]). Identity is then the KEY-slot tuple and
 * MUTABLE is payload ([IRET.19.1]), so a logical schema's KEY and MUTABLE slots are
 * disjoint and cover all its author slots, and `ts` is in neither: outside identity
 * and outside the compared payload. This model — a convergence of the language,
 * runtime, and impl statements of one rule — proves the labelling is
 * exhaustive-and-disjoint per lifecycle, and that identity + payload exactly
 * partition a logical schema's author slots.
 *
 * WHAT `ts` IS HERE, AND IS NOT. A schema has at most one `ts` slot. Its type (a
 * `Time`), its fill and the no-op test that leaves it out are noop_reassert.als's;
 * this model carries only its role, which the format fixes: `IDENTITY_ROLE_ENGINE`
 * on a `logical` schema and `IDENTITY_ROLE_UNSPECIFIED` on any other
 * (`proto/slot.proto#IdentityRole`, [RDSC.5.5.7]).
 *
 * TEETH: drop `rdsc_5_5_7__role_partition` and the checks fail — a logical slot goes
 * UNSPECIFIED (silent identity gap), a non-logical slot wears a KEY marker, or a logical
 * schema's key + payload no longer cover its slots. Drop the ENGINE line of that fact
 * (the third conjunct) and a logical `ts` may take any role: `lfac_9_1__ts_unmarked`,
 * `iret_19_1__ts_outside_key_and_payload`, `rdsc_5_5_7__marked_iff_logical`,
 * `rdsc_5_5_7__engine_iff_logical_ts` and `iret_19_1__key_and_payload_partition_slots`
 * fail (a MUTABLE `ts` lands in the payload), and `lfac_1_7_4__logical_slots_all_marked`
 * alone holds, since it never looks at `ts`. Drop the `ts`
 * exemption from the first conjunct instead and the fact asks a logical `ts` to be
 * KEY or MUTABLE and ENGINE at once: no instance has one, `probe__mixed_schemas`
 * finds nothing, and every check holds of a model about no `ts` — the exemption is
 * a condition, not a decoration.
 */
module ds/identity_slots

//@spec [RDSC.5.5.7]
// A slot's identity_role: KEY (part of the schema's identity key), MUTABLE (payload),
// ENGINE (the engine's `ts` on a logical schema) or UNSPECIFIED (no identity role —
// a non-logical schema's slot).
abstract sig rdsc_5_5_7__role {}
one sig KeyRole     extends rdsc_5_5_7__role {}
one sig MutableRole extends rdsc_5_5_7__role {}
one sig EngineRole  extends rdsc_5_5_7__role {}
one sig Unspecified extends rdsc_5_5_7__role {}

//@spec [LFAC.1.7]
// A schema.
sig lfac_1_7__schema {}

//@spec [LFAC.1.7]
// The `logical`-lifecycle schemas (a subset) — the ones that carry an identity key and
// do per-identity retract-and-replace.
sig lfac_1_7__logical in lfac_1_7__schema {}

//@spec [RDSC.5.5.7]
// A slot of a schema, carrying an identity_role.
sig rdsc_5_5_7__slot {
  owner: one lfac_1_7__schema,
  role:  one rdsc_5_5_7__role
}

//@spec [LFAC.9.1]
// The `ts` slots: a slot named `ts`, which a schema may declare and need not.
sig lfac_9_1__ts in rdsc_5_5_7__slot {}

//@spec [LFAC.9.1]
// A schema declares `ts` at most once: a slot name is unique within its schema.
fact lfac_9_1__one_ts_per_schema {
  all sch: lfac_1_7__schema | lone (lfac_9_1__ts & owner.sch)
}

//@spec [RDSC.5.5.7]
// Require-all on logical, ENGINE for its `ts`, unspecified on non-logical: every
// author slot of a `logical` schema is KEY or MUTABLE ([LFAC.1.7.4]); its `ts` slot is
// ENGINE ([LFAC.9.1]); every slot of a non-`logical` schema is UNSPECIFIED (a
// key/mutable marker there is rejected, [LFAC.1.7.6]).
fact rdsc_5_5_7__role_partition {
  all s: rdsc_5_5_7__slot |
    (s.owner in lfac_1_7__logical and s not in lfac_9_1__ts implies s.role in (KeyRole + MutableRole))
    and (s.owner not in lfac_1_7__logical implies s.role = Unspecified)
    and (s.owner in lfac_1_7__logical and s in lfac_9_1__ts implies s.role = EngineRole)
}

//@spec [IRET.19.1]
// A schema's identity key: its KEY slots — the tuple assert matches an existing fact on.
fun iret_19_1__identity_key[sch: lfac_1_7__schema]: set rdsc_5_5_7__slot {
  { s: rdsc_5_5_7__slot | s.owner = sch and s.role = KeyRole }
}

//@spec [IRET.19.1]
// A schema's payload: its MUTABLE slots — compared under tolerance, not identity.
fun iret_19_1__payload[sch: lfac_1_7__schema]: set rdsc_5_5_7__slot {
  { s: rdsc_5_5_7__slot | s.owner = sch and s.role = MutableRole }
}

//@probe
// A logical schema with KEY + MUTABLE slots and a `ts` slot, and a non-logical schema
// with only UNSPECIFIED slots, one of them `ts`, coexist. Satisfiable.
run probe__mixed_schemas {
  some sch: lfac_1_7__logical |
    (some s: rdsc_5_5_7__slot | s.owner = sch and s.role = KeyRole)
    and (some s: rdsc_5_5_7__slot | s.owner = sch and s.role = MutableRole)
    and (some s: lfac_9_1__ts | s.owner = sch)
  some sch: (lfac_1_7__schema - lfac_1_7__logical) | some s: lfac_9_1__ts | s.owner = sch
} for 6

// REQUIRE-ALL: no author slot of a logical schema is UNSPECIFIED — every one but `ts`
// is marked KEY or MUTABLE ([LFAC.1.7.4]). NO counterexample.
assert lfac_1_7_4__logical_slots_all_marked {
  all s: rdsc_5_5_7__slot - lfac_9_1__ts | s.owner in lfac_1_7__logical implies s.role in (KeyRole + MutableRole)
}
//@spec [LFAC.1.7.4]
check lfac_1_7_4__logical_slots_all_marked for 6

// MARKED IFF LOGICAL AND NOT `ts`: a slot carries a KEY/MUTABLE marker IFF its schema is
// logical and it is an author slot — a non-logical slot and a `ts` slot carry none
// ([RDSC.5.5.7] / [LFAC.1.7.6] / [LFAC.9.1]). NO counterexample.
assert rdsc_5_5_7__marked_iff_logical {
  all s: rdsc_5_5_7__slot |
    (s.role in (KeyRole + MutableRole)) iff (s.owner in lfac_1_7__logical and s not in lfac_9_1__ts)
}
//@spec [RDSC.5.5.7]
check rdsc_5_5_7__marked_iff_logical for 6

// ENGINE IFF LOGICAL `ts`: a slot carries ENGINE IFF it is the `ts` of a logical schema
// — so ENGINE is never an author's marker, and a non-logical `ts` is UNSPECIFIED like
// its neighbours ([RDSC.5.5.7], `proto/slot.proto#IdentityRole`). NO counterexample.
assert rdsc_5_5_7__engine_iff_logical_ts {
  all s: rdsc_5_5_7__slot |
    (s.role = EngineRole) iff (s.owner in lfac_1_7__logical and s in lfac_9_1__ts)
}
//@spec [RDSC.5.5.7]
check rdsc_5_5_7__engine_iff_logical_ts for 6

// KEY + PAYLOAD PARTITION THE AUTHOR SLOTS: every slot of a logical schema other than
// `ts` is in its identity key (KEY) or its payload (MUTABLE) — the two are disjoint and
// cover all such slots, so assert matches on the key tuple and compares the payload
// ([IRET.19.1]). NO counterexample.
assert iret_19_1__key_and_payload_partition_slots {
  all sch: lfac_1_7__logical |
    (let owned = { s: rdsc_5_5_7__slot | s.owner = sch and s not in lfac_9_1__ts } |
       owned = iret_19_1__identity_key[sch] + iret_19_1__payload[sch]
       and no (iret_19_1__identity_key[sch] & iret_19_1__payload[sch]))
}
//@derives [IRET.19.1]
check iret_19_1__key_and_payload_partition_slots for 6

// `ts` IS UNMARKED, on every schema: it carries no KEY or MUTABLE marker — ENGINE on a
// logical schema, UNSPECIFIED elsewhere — the one slot of a logical schema require-all
// does not reach ([LFAC.9.1], [LFAC.1.7.4]). NO counterexample.
assert lfac_9_1__ts_unmarked {
  all s: lfac_9_1__ts | s.role not in (KeyRole + MutableRole)
}
//@derives [LFAC.9.1]
//@derives [LFAC.1.7.4]
check lfac_9_1__ts_unmarked for 6

// `ts` IS OUTSIDE IDENTITY AND OUTSIDE THE PAYLOAD: it is in neither set assert reads
// ([IRET.19.1]), so it takes no part in the match and no part in the comparison
// ([LFAC.9.1]). NO counterexample.
assert iret_19_1__ts_outside_key_and_payload {
  all s: lfac_9_1__ts | s not in iret_19_1__identity_key[s.owner] + iret_19_1__payload[s.owner]
}
//@derives [IRET.19.1]
//@derives [LFAC.9.1]
check iret_19_1__ts_outside_key_and_payload for 6

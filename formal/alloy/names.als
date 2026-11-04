/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS identifiers & namespaces — structural consistency model (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_lnam_2_3_1__<tag>):
 *      <lowercased-clause-id>__<snake_tag>, e.g. `llex_9_5__reserved_words`
 *      formalizes [LLEX.9.5]. A satisfiability probe (tied to no clause) carries
 *      the `probe__` marker. Enumeration members inherit their parent's clause.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name:
 *        //@spec [ID]     — formalizes normative clause [ID] (1:1)
 *        //@derives [ID]  — a check proving a consequence of [ID]
 *        //@probe         — a satisfiability probe, tied to no clause
 *        //@gap           — an invariant with no dotted home (a finding)
 *
 * SCOPE. Three invariants: (A) reserved words are disjoint from
 * author identifiers; (B) the type namespace is flat, so type resolution is
 * unambiguous; (C) classification is by position, not identity, so one name may
 * span both namespaces.
 *
 * (A) IS NOW BLANKET, AND THAT IS THE CHANGE. This model carried no general
 * disjointness invariant because the retired three-class taxonomy kept most
 * contextual keywords nameable outside their promoted position, so the only
 * reservation worth modelling was the built-in type names in (B). The single flat
 * list [LLEX.9.5] removes that conditionality — a reserved word is refused
 * everywhere, in every position — so the narrow invariant and the reason for its
 * narrowness both go, and (A) covers the whole list.
 *
 * What (A) deliberately does NOT model is case. Reservation is by exact NFC
 * string ([LNAM.2.1.1]), and `lnam_2_3_1__name` already treats distinct spellings
 * as distinct atoms, so `Where` is simply a different atom from `where` and needs
 * no constraint to stay nameable.
 *
 * THE KIND `Schema` IS A KIND, NOT A TYPE. [LGRA.22.7] lists it among the type
 * namespace's entries, admissible only as a service kwarg's declared type and
 * naming a fact of any schema. It is not a builtin type -- it has no row on
 * [LGRA.22.8] -- and it is a reserved word, with a `type` row on [LLEX.9.6]. So
 * it sits in the model BESIDE `lgra_22_7__builtin_types`, not inside it: one
 * name that occupies the namespace, that no declared type takes (B), and that
 * (A) refuses to every author identifier because it is reserved. Which of the
 * two routes refuses a `schema Schema` is [LLEX.9.7]'s: the reserved-word row,
 * before the duplicate-type check could see a collision. The model states both
 * facts and checks that the name resolves alone.
 *
 * TEETH, each run once on a copy with one line removed. Without the
 * `in llex_9_5__reserved_words.reserved` line of
 * `lgra_22_7__schema_kind_reserved_not_builtin` the never-an-author-name check
 * fails and nothing else does. Without its `not in` line, and separately without
 * the kind's line of `lgra_22_7__type_namespace_flat`, the resolves-alone check
 * fails and nothing else does.
 */
module ds/names

//@spec [LNAM.2.3.1]
// An NFC-normalized identifier identity. Distinct atoms = distinct names;
// comparison is case-sensitive, so `Reading` and `reading` are distinct atoms.
sig lnam_2_3_1__name {}

// ---- (A) reserved words are never author identifiers [LLEX.9.5] -------------

//@spec [LLEX.9.5]
// The reserved words — every word the language itself uses, enumerated by
// [LLEX.9.6]. Not a class: there is one list and no position, scope or category
// in which a member of it becomes nameable.
one sig llex_9_5__reserved_words { reserved: set lnam_2_3_1__name }

//@spec [LGRA.2.5.2]
// `NAME` is the single identifier terminal — a name an author chooses for a
// binding / slot / schema / rule / const.
sig lgra_2_5_2__author_identifier { name: one lnam_2_3_1__name }

//@spec [LLEX.9.5]
// The reservation: no author-chosen identifier is spelled as a reserved word.
fact llex_9_5__reserved_never_author_names {
  no i: lgra_2_5_2__author_identifier | i.name in llex_9_5__reserved_words.reserved
}

// SAFETY: no NAME is simultaneously a reserved word and an author identifier, so
// the lexer's keyword-vs-NAME decision is unambiguous. NO counterexample.
assert llex_9_5__author_ident_not_reserved {
  no n: lnam_2_3_1__name |
    n in llex_9_5__reserved_words.reserved and
    (some i: lgra_2_5_2__author_identifier | i.name = n)
}
//@spec [LLEX.9.5]
check llex_9_5__author_ident_not_reserved for 6

// ---- (B) the type namespace is flat -> type resolution is unambiguous --------

//@spec [LGRA.22.7]
// The built-in type names (`String`/`Int`/`Float`/…, the temporal types and
// `Interval`): the type-namespace entries an author does not declare. They are
// also reserved words, but what (B) needs from them is only that they occupy the
// namespace — the refusal itself is (A)'s.
one sig lgra_22_7__builtin_types { names: set lnam_2_3_1__name }

//@spec [LGRA.22.7]
// An author-declared entry in the type namespace: a schema or a unit.
sig lgra_22_7__declared_type { name: one lnam_2_3_1__name }

//@spec [LGRA.22.7]
// The kind `Schema`: an entry of the type namespace that is neither a builtin
// type nor anything an author declares. Admissible only as a service kwarg's
// declared type, it names a fact of any schema; what (B) needs from it is that
// it occupies the namespace under one name.
one sig lgra_22_7__schema_kind { name: one lnam_2_3_1__name }

//@spec [LGRA.22.7]
// The kind is a reserved word -- it carries a `type` row on [LLEX.9.6], so (A)
// refuses a declaration spelled as it -- and it is not a builtin type: it has no
// row on [LGRA.22.8], so its name is none of theirs.
fact lgra_22_7__schema_kind_reserved_not_builtin {
  lgra_22_7__schema_kind.name in llex_9_5__reserved_words.reserved
  lgra_22_7__schema_kind.name not in lgra_22_7__builtin_types.names
}

//@spec [LGRA.22.7]
// Flat namespace: a declared type never collides with a built-in type name or
// with the kind's, and declared types are pairwise distinct.
fact lgra_22_7__type_namespace_flat {
  no d: lgra_22_7__declared_type | d.name in lgra_22_7__builtin_types.names
  no d: lgra_22_7__declared_type | d.name = lgra_22_7__schema_kind.name
  all disj d, d2: lgra_22_7__declared_type | d.name != d2.name
}

// SAFETY: no NFC name resolves to both a built-in and an author-declared type, so
// a type reference resolves to exactly one entity. NO counterexample.
assert lgra_22_7__type_resolution_unambiguous {
  no n: lnam_2_3_1__name |
    n in lgra_22_7__builtin_types.names and
    (some d: lgra_22_7__declared_type | d.name = n)
}
//@spec [LGRA.22.7]
check lgra_22_7__type_resolution_unambiguous for 6

// THE KIND RESOLVES ALONE: the kind's name is no builtin type's and no declared
// type's, so a type position written as it reaches the kind and nothing else.
// The two facts about the kind said a second way. NO counterexample.
assert lgra_22_7__schema_kind_resolves_alone {
  lgra_22_7__schema_kind.name not in lgra_22_7__builtin_types.names
  no d: lgra_22_7__declared_type | d.name = lgra_22_7__schema_kind.name
}
//@spec [LGRA.22.7]
check lgra_22_7__schema_kind_resolves_alone for 6

// THE KIND IS NEVER AN AUTHOR'S NAME: because its name is reserved, (A) keeps
// it off every author identifier -- a `schema Schema`, a unit or an `opaque
// type` so named is refused as a reserved word ([LLEX.9.7]), before the flat
// namespace could see a collision. Follows from the reservation and
// `llex_9_5__reserved_never_author_names` together. NO counterexample.
assert llex_9_5__schema_kind_never_an_author_name {
  no i: lgra_2_5_2__author_identifier | i.name = lgra_22_7__schema_kind.name
}
//@derives [LLEX.9.5]
check llex_9_5__schema_kind_never_an_author_name for 6

// ---- (C) classification is by position, not identity [LNAM.2.1.1] ------------

//@spec [LNAM.2.1.1]
// Classification of an identifier occurrence: a type reference or a value binding.
// Determined by grammatical position, never by case/identity.
abstract sig lnam_2_1_1__classification {}
one sig type_reference extends lnam_2_1_1__classification {}
one sig value_binding  extends lnam_2_1_1__classification {}

//@spec [LNAM.2.1.1]
// A NAME occurrence: its identity is the name, its classification the position.
sig lnam_2_1_1__occurrence {
  name: one lnam_2_3_1__name,
  role: one lnam_2_1_1__classification
}

//@probe
// A non-trivial universe (some reserved word, author id, built-in, declared type)
// is satisfiable — the facts are not mutually over-constraining.
run probe__consistent {
  some llex_9_5__reserved_words.reserved
  some lgra_2_5_2__author_identifier
  some lgra_22_7__builtin_types.names
  some lgra_22_7__declared_type
} for 6

//@spec [LNAM.2.1.1]
// One NFC name legitimately classifies both ways across the two disjoint
// namespaces — a schema/const/binding may share a name. Satisfiable by design.
run lnam_2_1_1__name_spans_both_namespaces {
  some n: lnam_2_3_1__name |
    (some o:  lnam_2_1_1__occurrence | o.name  = n and o.role  = type_reference) and
    (some o2: lnam_2_1_1__occurrence | o2.name = n and o2.role = value_binding)
} for 4

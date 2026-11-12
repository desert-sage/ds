<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The Atom Registry

## Registry

### Census

The `.dsc` atom census is [RDSC.7.1](inv:specs:std:label#rdsc-7-1), and the stream's atom registry is [RFCS.16](inv:specs:std:label#rfcs-16).

An atom's wire identity is its field number in the `body` oneof of `proto/atom.proto#Atom`, which is the census's `Field #` column. Its name is its body message, the `Atom` column. A `.proto` file may define several bodies. An atom's body is its `.proto` and its `RDSC` clauses; framing, load order and loading semantics are [The .dsc format](../artefacts/dsc-format.md).

*(Spec: [RDSC.7.6], [RDSC.12.3], proto: atom.proto)*

### Multiplicity

Every multiplicity in the census is the compiler's guarantee, and the runtime does not re-check it.

| Census term | Meaning |
|---|---|
| exactly 1 | the compiler writes exactly one; the runtime rejects a file with none and does not check for a second |
| per module | at most one per `module_id` for `DsSource`, and at most one per (`module_id`, named entity) for every other per-module atom |
| per schema, per slot, per rule | at most one per named entity; atoms of one kind repeat for different entities, and a schema, its slots and a rule each belong to one module |

The compiler writes no duplicate within a module's namespace. A schema's own name, a rule's name and a service's name are each unique in a program, so no two `schema_group`s, `rule_group`s or `ServiceDef`s share one, and no atom of one module replaces an atom of another. An artefact that did not come from a conforming compiler carries none of these guarantees.

*(Spec: [RDSC.7.2], [RDSC.7.2.1], [RDSC.7.3])*

### Numbers outside the census

Every atom a loader meets has a row in its series' census. The atoms a loader steps over by name are at [Atoms stepped over](../artefacts/dsc-format.md#atoms-stepped-over).

`StreamHeader` has no row and never appears in a `.dsc`: a reader walking the `.dsc` atoms of a self-contained stream takes it as the start of the stream ([Lean and self-contained streams](../artefacts/fact-stream.md#lean-and-self-contained-streams)). Two members of one `oneof` cannot share a number, so no `.dsc` atom collides with it.

*(Spec: [RDSC.7.5], [RDSC.9.4], [LDET.1.10])*

### Test and oracle atoms

The `TestCase`, `TestFact`, `TestCacheSeed`, `TestResponse` and `TestReply` atoms and the `Oracle*` atoms are test metadata, each with a field number of its own.

A production runtime's loader [steps over](../artefacts/dsc-format.md#atoms-stepped-over) them and runs the program unchanged.

*(Spec: [RDSC.7.6], [RDSC.9.4])*

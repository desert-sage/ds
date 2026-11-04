<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Terms

## DS

The short form of the language's official name, Desert Sage.

*(Spec: [LSCO.1.13])*

## Fact

One [instance](facts/schemas.md) of a schema: a value for each of its slots.

*(Spec: [LFAC.11], [RTIM.6.3])*

## Schema

A top-level [declaration](facts/schemas.md#schema) that names a fact type, its slots and its lifecycle.

*(Spec: [LGRA.5.1])*

## Slot

A named, typed [member](facts/schemas.md) of a schema.

*(Spec: [LGRA.5.1])*

## Rule

A top-level [declaration](rules/rules.md#rule) of patterns and actions, separated by `->`.

*(Spec: [LGRA.6.1])*

## Pattern

A [line](rules/patterns.md#pattern-body) of a rule's left-hand side that matches facts of one schema, or their absence.

*(Spec: [LGRA.8.1])*

## Activation

A rule together with the particular facts that matched it: a firing owed until it fires, which stays, fired, while its match lasts.

*(Spec: [LFAC.11], [LDET.5.3], [IDAT.6.2], [IRET.11])*

## Working memory

The set of facts an engine holds live.

*(Spec: [LFAC.11], [RARC.5.2.1])*

## Action

A [statement](actions/actions.md#action) of a rule's right-hand side.

*(Spec: [LGRA.6.1], [LGRA.10.1])*

## Module

A source file of a compilation unit: the [program](#program), or an imported [library](#library).

*(Spec: [LDIA.3.4.1])*

## Library

A DS source file with no `use` directive.

*(Spec: [LDIA.2.10.1])*

## Program

A DS source file with a `use` directive.

*(Spec: [LDIA.2.10.1])*

## Dialect

A [name](capabilities/dialects.md#dialect) for a setting of every capability to `true` or `false`.

*(Spec: [LDIA.1.1])*

## Capability

A boolean [setting](capabilities/registry.md#capability) with a stable name.

*(Spec: [LCAP.1])*

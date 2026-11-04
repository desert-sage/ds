<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Built-in schemas

## The built-in module

### Built-in module

Every compilation imports the built-in module, and no program declines it.

The module declares the built-in schemas and nothing else. It is not a library: no import names it, no `as` alias renames it, and no dotted name reaches into it. Its schemas are in scope by their bare names in every file.

*(Spec: [LIMP.12.1])*

### The built-in schemas

| Schema | Written into the artefact |
|---|---|
| [`ComputationError`](../errors/fault-facts.md#computationerror-fact) | always |
| [`TypeError`](../errors/fault-facts.md#typeerror-fact) | always |
| [`CallError`](../calls/call.md#callerror) | when the program contains a `call` action or names the schema |
| [`TimeZoneOffset`](../time/zones.md#timezoneoffset) | always |

A built-in schema the program does not use is left out of the artefact. A rule that matches `CallError` in a program with no `call` compiles and is inert.

*(Spec: [LIMP.12.2])*

### Taken names

A built-in schema's name is taken in every file, and no alias resolves the collision.

| Name | Code |
|---|---|
| `ComputationError`, `TypeError` | `DS_VALIDATE_RESERVED_TYPE_NAME` |
| `CallError`, `TimeZoneOffset`, `HydrationComplete`, `HydratedSample` | `DS_VALIDATE_IMPORT_NAME_COLLISION` |

```ds declaration error=DS_VALIDATE_RESERVED_TYPE_NAME
schema TypeError:
    id: String
```

*(Spec: [LIMP.12.2], [LIMP.12.3], [LERR.9.4])*

### Internal scope

`ComputationError` and `TypeError` are [`internal`](lifecycles.md#internal), and no other schema can be.

*(Spec: [LIMP.12.4], [LERR.9.4])*

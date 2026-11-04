<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Dialect binding

## Binding

### Binding tuple

The dialect-binding tuple is the three fields every bound artefact carries, identifying the rules and the behaviour it came from.

| Field | Holds |
|---|---|
| `dsc_sha256` | the SHA-256 of the compiled `.dsc` active when the artefact was produced |
| `capabilities` | the program's resolved settings: every capability set `true`, in ascending `Capability` order |
| `dialect_def_sha256` | the SHA-256 of the canonical serialization of those settings ([Canonical serialization](#canonical-serialization)) |

The dialect's name is not part of the tuple: two programs whose settings resolve alike are bound alike, whatever dialect each named. The tuple is checked without any external registry.

`capabilities` is strictly ascending, and each entry is a member of `proto/capabilities.proto#Capability` other than `CAPABILITY_UNSPECIFIED`, so no capability appears twice. A reader refuses a list that breaks either rule, at load with `DS_ERR_DSC_SEMANTIC` and in a recording's header with `DS_ERR_PARSE`. It never cuts, sorts or de-duplicates the list.

*(Spec: [RBND.1.1], [RBND.1.3], Source: runtime/src/libds/rfcs/codec.c)*

### Containers

Each bound container carries the tuple under its own format's field names.

| Artefact | Container |
|---|---|
| `.dsc` | the `DscHeader` atom |
| event trace | the `StreamHeader` atom, where `dsc_hash` is the `.dsc`'s `dsc_sha256` |
| DAP trace | the first-line `meta` object of the `.dsr` |

In a container a `.proto` message defines, the fields are the message's. Any other container names them `dsc_sha256`, `capabilities` and `dialect_def_sha256`, verbatim and with no alias, whatever naming its format otherwise follows.

A loader rejects a container missing a required field with `DS_ERR_BND_INCOMPLETE`. The rule binds the singular fields, `dsc_sha256` and `dialect_def_sha256`: an empty `capabilities` list is a value. An event trace whose header holds neither singular field is unverifiable, not incomplete, and the engine replays it without a binding check. An event trace holding one of the two and not the other is refused with `DS_ERR_BND_INCOMPLETE`, whether or not a `.dsc` is loaded.

*(Spec: [RBND.2], [RBND.2.1], [RBND.2.2])*

## Hashing

### dsc_sha256

Every artefact's `dsc_sha256` is the value the `.dsc`'s own header carries ([dsc_sha256](dsc-format.md#dsc_sha256)), copied from the header of the `.dsc` active when the artefact was produced.

A runtime never hashes the `.dsc` another way to fill it. Nothing outside the `.dsc` file is hashed: a container's framing is not part of the `.dsc` byte sequence.

*(Spec: [RBND.3.1])*

### Hash encoding

A hash is a lowercase hex string of 64 characters, with no `0x` prefix and no separators, in a text container, and the raw 32 bytes in a protobuf `bytes` field.

`dialect_def_sha256` follows the same encoding as `dsc_sha256`.

*(Spec: [RBND.3.2], [RBND.3.3])*

### Canonical serialization

`dialect_def_sha256` is the SHA-256 of the canonical serialization of the program's resolved settings: the named dialect's settings with the `use` block's overrides applied.

```ebnf
serialization = magic , enabled_line ;
magic         = "ds.dialect.v2" , lf ;
enabled_line  = "enabled=" , [ name , { "," , name } ] , lf ;
name          = ? a capability's stable name ? ;
lf            = %x0A ;
```

`enabled_line` names exactly the capabilities set `true`, each once, in ascending number of their `Capability` member, and `name` is that member's stable name. With no setting `true`, the line is `enabled=` and its line feed. A stable name is a protobuf enum member's name, so it is ASCII and holds neither `,` nor a line feed, and the serialization defines no escaping.

*(Spec: [RBND.4.1], [RBND.4.2], [RBND.4.3])*

## Checking

### Binding check

When two artefacts are loaded together, the secondary artefact's tuple equals the primary artefact's, the `.dsc`'s, field by field.

| Field that differs | Result |
|---|---|
| `dsc_sha256` | `DS_ERR_BND_DSC_MISMATCH` |
| `capabilities` or `dialect_def_sha256` | `DS_ERR_BND_DIALECT_MISMATCH` |

A mismatch is fatal. The detail names the field that disagreed and both observed values, truncated to 16 hex characters where applicable; for `capabilities` it names the capabilities in one tuple and not the other. There is no advisory mode, warn-and-continue or best-effort load: event-trace replay and DAP-trace replay both check. `DS_ERR_BND_DIALECT_MISMATCH` is also the refusal of an artefact whose settings an integration's admission policy does not admit.

*(Spec: [RBND.5.1], [RBND.5.2], [RBND.5.3])*

### Single-artefact loads

Loading one artefact alone, a `.dsc` or an event trace dumped with no engine, invokes no binding check.

Such a loader may surface the artefact's tuple as diagnostic output and never cross-checks it against a reference it was not given. An engine that has loaded no `.dsc` checks no event trace.

*(Spec: [RBND.2.1], [RBND.5.4])*

### Comparator

A runtime has one dialect-binding comparison, and every load path that checks the tuple uses it.

It takes an expected and an actual tuple, and yields `DS_OK` when all three fields are equal, or `DS_ERR_BND_DSC_MISMATCH` or `DS_ERR_BND_DIALECT_MISMATCH` with the detail of [Binding check](#binding-check). No load path tests the fields individually. A comparator that consumes a subset of the tuple is not a fail-closed gate, and appears only in informational diagnostics.

*(Spec: [RBND.1.5], [RBND.6.1], [RBND.6.2], [RBND.6.3])*

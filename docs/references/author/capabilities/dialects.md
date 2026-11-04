<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Dialects

## The dialect

### Dialect

A name for a setting of every [capability](registry.md) to `true` or `false`. Dialect names and capability names are separate namespaces.

A dialect filters constructs. Every DS file parses under the same grammar.

*(Spec: [LDIA.1.1], [LDIA.1.2], [LDIA.1.4], [NDLC.1.3])*

### Resolved settings

A program's dialect's settings, with its `use` block's overrides applied. They govern its whole compilation unit: the artefact records them, the engine runs them, and the compiler validates every module against them.

The binding of an artefact to its settings is at [Dialect binding](inv:internals:std:doc#artefacts/dialect-binding).

*(Spec: [LDIA.1.3], [LDIA.2.9], [LDIA.3.4.1])*

## The `use` directive

### `use`

**`use_decl ::= 'use' NAME NEWLINE | 'use' NAME ':' NEWLINE INDENT setting_line+ DEDENT`**

**`setting_line ::= NAME ':' BOOL_LIT NEWLINE`**

`use <dialect>` takes the dialect's settings. With a block, each line overrides the one capability it names, and a line restating the dialect's setting changes nothing.

```ds action head
use default:
    dynamic_ttl: true
log info "{r.id}"
```

*(Spec: [LDIA.2.1], [LDIA.2.2], [LDIA.3.3.1], [LDIA.3.3.5], [LGRA.3.1])*

### Placement

`use` appears at most once in a file, before any declaration. A second `use` is a compile error.

Whether a file has a `use` makes it a [program](../terms.md#program) or a [library](../terms.md#library).

*(Spec: [LDIA.2.6], [LDIA.2.7], [LDIA.2.10.1])*

### Programs and libraries

| Condition | Code |
|---|---|
| an `import` that resolves to a file with a `use` directive, at the `import` line | `DS_VALIDATE_IMPORT_OF_PROGRAM` |
| a library given as the file to build, with no artefact produced | `DS_VALIDATE_NOT_A_PROGRAM` |
| a `.dstest` file with a `use` directive | `DS_VALIDATE_USE_IN_TEST` |

A library is validated under the importing program's resolved settings, and its requirements are computed from its content. A test runs under the resolved settings of the program it tests.

*(Spec: [LDIA.2.10.6], [LDIA.2.10.7], [LDIA.2.10.8], [LDIA.2.10.9])*

## Resolution

### Compile-time checks

The compiler checks a `use` directive in this order.

1. **Dialect name.** The name resolves among the built-in dialects and those registered with a [dialect file](dialect-files.md).
2. **Overrides.** Each line of the block names a capability once.
3. **Constraints.** The resolved settings satisfy the [fundamental constraints](registry.md#fundamental-constraints).
4. **Constructs.** Every construct of every module is permitted by the resolved settings.

| Condition | Code |
|---|---|
| an unknown dialect name, the message listing the registered dialects | `DS_VALIDATE_UNKNOWN_DIALECT` |
| an unknown capability, the message naming it and the registry | `DS_VALIDATE_UNKNOWN_CAPABILITY` |
| a capability named twice in one block | `DS_VALIDATE_CAPABILITY_DUPLICATE` |
| a constraint violated | `DS_VALIDATE_CAPABILITY_CONSTRAINT` |
| a construct not permitted | `DS_VALIDATE_CAPABILITY_DISABLED` |

```ds action head error=DS_VALIDATE_UNKNOWN_DIALECT
use nowhere
log info "{r.id}"
```

*(Spec: [LDIA.3.1], [LDIA.3.2.1], [LDIA.3.2.2], [LDIA.3.3.2], [LDIA.3.3.6], [LDIA.3.4.1], [LDIA.3.4.2], [LDIA.3.5.1])*

### Deferred capabilities

Refused before the constraint check:

| Written | Code |
|---|---|
| `use realtime`, at the dialect name, whatever the block overrides | `DS_VALIDATE_REALTIME_DEFERRED` |
| `realtime` or `constspace` set `true` on a `use` block line | `DS_VALIDATE_REALTIME_DEFERRED` |
| `sampled_slots`, `persist_on_series`, `storage_hydrate_facts` or `storage_hydrate_samples` set `true` on a `use` block line | `DS_VALIDATE_CAPABILITY_DEFERRED` |

A line setting any of them `false` is accepted.

```ds action head error=DS_VALIDATE_REALTIME_DEFERRED
use realtime
log info "{r.id}"
```

*(Spec: [LCAP.2.1.5], [LCAP.2.10], [LDIA.3.2.3], [LDIA.3.3.7])*

### Error message

A compile error for a construct the settings do not permit identifies:

- the construct, and the capability that forbids it by its stable name;
- where the setting came from: the dialect, or the `use` block line;
- a refactor hint, where it has one;
- the source location, and for a construct in an imported library, the library.

*(Spec: [LDIA.5.1], [LDIA.5.2], [LDIA.5.3], [LDIA.5.4], [LDIA.5.5], [LDIA.5.8], [NDLC.5.3])*

## Built-in dialects

### `base`

Sets every capability `false`.

*(Spec: [LDIA.9.1])*

### `default`

| Setting | Capabilities |
|---|---|
| `true` | `call`, `publish`, `cache`, `cache_delete`, `nocooldown`, `regex`, `series`, `logical`, `linear_scan`, `float` |
| `false` | `dynamic_ttl`, and the [deferred capabilities](#deferred-capabilities) |

*(Spec: [LDIA.9.2], [LFCA.8.1])*

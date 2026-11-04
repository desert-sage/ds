<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Dialect files

## The file

### Dialect YAML

```text
name: <NAME>
settings:
  <capability>: <true or false>
```

A YAML file that defines a [dialect](dialects.md#dialect). Its fields are `name` and `settings`, and no other.

`settings` holds exactly these keys, each `true` or `false`: the capabilities of [Capability table](registry.md#capability-table), and `realtime`, `constspace`, `sampled_slots`, `persist_on_series`, `storage_hydrate_facts` and `storage_hydrate_samples`, which are `false`.

*(Spec: [NDLC.2.1], [NDLC.2.2], [LDIA.3.3.5], [LDIA.4.1])*

### Read-only dialect

A dialect that sets `call`, `publish`, `cache`, `cache_delete` and `nocooldown` `false` is valid. `cached(...)` reads still work.

*(Spec: [NDLC.2.4])*

## Compiling with a dialect file

### `-d`

**`dialect_file = ( "-d" | "--dialect-file" ) , dialect_path ;`**

Registers the dialect for one compile, and one pass may register any number. The subcommands that take it are at [Options](../tools/dsc.md#options). A file that declares `use <name>` is validated against the dialect of that name.

With no dialect file, the compiler knows the built-in dialects.

*(Spec: [NDLC.1.4], [NDLC.4.2], [NDLC.4.3], Source: compiler/dsc_cli.ebnf)*

## Registration errors

### File refusals

The compiler validates a dialect file at load, before it reads any source file. It exits with status 2, and the message names the file.

| Condition | Message prefix |
|---|---|
| a `settings` key naming no capability | `DS_VALIDATE_DIALECT_UNKNOWN_CAPABILITY` |
| a capability absent from `settings` | `DS_VALIDATE_DIALECT_INCOMPLETE` |
| settings that violate a [fundamental constraint](registry.md#fundamental-constraints) | `DS_VALIDATE_DIALECT_DEPENDENCY` |
| `realtime` or `constspace` set `true` | `DS_VALIDATE_REALTIME_DEFERRED` |
| a storage capability set `true` | `DS_VALIDATE_CAPABILITY_DEFERRED` |
| `name` missing, empty or not a `NAME` token | `DS_VALIDATE_DIALECT_BAD_NAME` |
| a dialect name already registered | `DS_VALIDATE_DIALECT_DUPLICATE_NAME` |
| a YAML syntax error | file path and `YAML parse error` |
| a top-level key other than `name` and `settings` | file path, the line and the key |
| `settings` absent, or not a mapping | file path and `settings must be a mapping` |

*(Spec: [NDLC.6.1], [NDLC.6.2], [LFCA.1.4], [LFCA.9.3])*

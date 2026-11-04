<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Capabilities

## The registry

### Capability

A boolean setting with a stable name, in lower snake case. Every program has a setting for every capability: its [dialect](dialects.md)'s, with its `use` block's overrides applied.

A setting decides which constructs a program may use and how the engine carries them out, not what the program computes.

*(Spec: [LCAP.1], [LCAP.2], [LFCA.1.1], [LDIA.1.3])*

### Kinds

- A strategy capability chooses how the engine executes a program, and restricts constructs to those that strategy can run.
- A construct capability permits a construct, and `false` forbids it.

*(Spec: [LCAP.1])*

### Capability table

| Capability | Kind | Governs |
|---|---|---|
| `linear_scan` | strategy | [`linear_scan`](linear-scan.md) |
| `logical` | construct | [`logical`](logical.md) |
| `dynamic_ttl` | construct | [`dynamic_ttl`](dynamic-ttl.md) |
| `regex` | construct | [`regex`](regex.md) |
| `float` | construct | [`float`](#float) |
| `call` | construct | the [`call`](../calls/call.md#call) action |
| `publish` | construct | the [`publish`](../actions/emit-publish.md#publish) action |
| `cache` | construct | the [`cache`](../actions/cache.md#cache) action |
| `cache_delete` | construct | the [`cache_delete`](../actions/cache.md#cache_delete) action |
| `series` | construct | [`series`](../series/declarations.md#series) declarations and the [aggregations](../series/aggregations.md#aggregation-catalogue) |
| `nocooldown` | construct | the bare [`nocooldown`](../calls/call.md#nocooldown) flag on `call` |

The registry also holds capabilities that every program and dialect sets `false`, at [Deferred capabilities](dialects.md#deferred-capabilities).

*(Spec: [LCAP.1], [LFCA.2.1], [LFCA.5.1], [LFCA.6.1], [LFCA.1.4])*

## Construct capabilities

### Disabled constructs

A construct whose capability the resolved settings set `false` is refused with `DS_VALIDATE_CAPABILITY_DISABLED`, in the program and in every library it imports. The message contents are at [Error message](dialects.md#error-message).

```ds action head error=DS_VALIDATE_CAPABILITY_DISABLED
use default:
    cache: false
cache key: "k" value: r.n
```

*(Spec: [LFCA.2.1], [LFCA.6.1], [LDIA.3.4.2])*

### `float`

**`float: false`**

Forbids every construct whose type, or the type of any of its operands, is `Float`: a `Float` slot, literal, `let`, `const` or cast target, and every operator, builtin and series aggregation that produces a `Float`. Each is refused with `DS_VALIDATE_CAPABILITY_DISABLED`.

*(Spec: [LCAP.2.9])*

### `nocooldown`

**`nocooldown: false`**

Forbids the bare [`nocooldown`](../calls/call.md#nocooldown) flag on `call`, so every call states a numeric cooldown.

*(Spec: [LFCA.6.1], [LFCA.6.2])*

### Always available

`emit`, `log`, `cached(...)` reads, the expression grammar, patterns (`no`, `within`, `then`, `latest`), schema declarations, `let`, rule-header [`cooldown`](../rules/cooldown.md#cooldown) and string interpolation are available under every setting. A dialect cannot disable them.

*(Spec: [LDIA.4.2], [LFCA.2.3], [LFCA.2.4])*

## Composition

### Intersection

A program satisfies the restrictions of every setting it has. One that fails any of them does not compile, and no setting relaxes a restriction another imposes.

*(Spec: [LCAP.3.5])*

### Fundamental constraints

| If this is `true` | this must be `true` |
|---|---|
| `nocooldown` | `call` |

Every program's resolved settings and every dialect's settings satisfy this. A violation in a program is refused with `DS_VALIDATE_CAPABILITY_CONSTRAINT`, naming the constraint and the settings.

```ds action head error=DS_VALIDATE_CAPABILITY_CONSTRAINT
use default:
    call: false
log info "{r.id}"
```

*(Spec: [LCAP.3.8], [LDIA.3.5.1], [LFCA.7.1])*

### `linear_scan` false with `logical` false

A program with both settings may hold only single-pattern rules: a multi-pattern rule is refused by the [join anchor](linear-scan.md#join-anchor), which needs `logical` schemas.

*(Spec: [LCAP.2.3], [LCAP.3.1], [LNOG.6.1], [LNOG.6.2], [LNOG.9])*

### `linear_scan` false with `dynamic_ttl` true

The combination is permitted.

*(Spec: [LCAP.3.3], [LDTL.2.2])*

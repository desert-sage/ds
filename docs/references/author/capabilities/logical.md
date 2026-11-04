<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `logical`

## The setting

### `logical` false

**`logical: false`**

A construct setting that forbids [logical facts](../facts/logical.md) in a program and every library it imports.

A program has it through its dialect or a `use` block line. `default` has `logical: true`. The combination with `linear_scan: false` is at [`linear_scan` false with `logical` false](registry.md#linear_scan-false-with-logical-false).

*(Spec: [LCAP.2.3], [LNOG.2.1])*

## Refusals

### Logical constructs

Each is refused with `DS_VALIDATE_CAPABILITY_DISABLED`:

- a `schema` declared `scope logical`, anywhere in the compilation unit;
- an `emit` with the `logical` keyword, whatever the schema's lifecycle.

```ds declaration head error=DS_VALIDATE_CAPABILITY_DISABLED
use default:
    logical: false
schema Doc scope logical:
    id: String key
```

*(Spec: [LNOG.3.1], [LNOG.3.2], [LNOG.9])*

## Behaviour

### Fact lifetime

Every emitted fact persists until it expires by TTL, a rule withdraws it, or the engine is reset.

*(Spec: [LNOG.1.2])*

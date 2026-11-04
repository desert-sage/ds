<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Opaque types

## Declaration

### Opaque type

**`opaque type <Name> over Bytes`**

An opaque type is a nominal type carried by an underlying representation, with an operation surface sealed to equality and the operations whose signatures name it.

The representation must be `Bytes`; any other is refused with `DS_VALIDATE_OPAQUE_UNSUPPORTED_REPR`. A program or a library declares one, and it is importable from the library that declares it: `from keys import (Key, Signature)`. A second declaration of a name is refused with `DS_VALIDATE_DUPLICATE_OPAQUE_TYPE`, and a name that is both an opaque type and a schema with `DS_VALIDATE_NAME_COLLISION`.

```ds declaration
opaque type Key over Bytes
```

*(Spec: [LOPQ.1.1], [LOPQ.2.1], [LOPQ.2.2], [LOPQ.2.3], [LOPQ.10.1], Source: compiler/mercury/src/dsc.resolve.m)*

### Nominal identity

Each opaque type and its representation are pairwise distinct types, with no implicit conversion.

An assignment, comparison or argument binding across two opaque types, or between one and its representation, is refused with `DS_VALIDATE_OPAQUE_TYPE_MISMATCH`. Two declarations are two types, whatever their names: two libraries' `Key`s are distinct, and a file that imports a declaration holds that declaration.

*(Spec: [LOPQ.2.3])*

### Gating

Opaque types are part of the base language; no capability gates them.

*(Spec: [LOPQ.8.1])*

## Operations

### Equality

**`a == b`**, **`a != b`**

`==` and `!=` on two values of one opaque type compare bytewise on the representation.

Equality is reflexive and total. An opaque-typed slot may be equality-joined.

*(Spec: [LOPQ.3.1], [LOPQ.5.2], [LOPQ.5.3])*

### Declared operations

A `service` or builtin whose signature names the opaque type takes or returns it, and the type system enforces the match.

A `service` takes its arguments as `kwarg` declarations. An opaque return is a slot on its response schema.

*(Spec: [LOPQ.3.2])*

### Sealed operations

Every other operation on an opaque receiver is refused with `DS_VALIDATE_OPAQUE_NO_OP`.

This covers `len`, indexing, every member of the representation type, a `::` cast of the representation, interpolation of the raw value, ordering with `<`, `<=`, `>` or `>=`, and any other builtin method of the representation.

*(Spec: [LOPQ.3.3], [LOPQ.5.2], [LOPQ.11])*

## The seal

### Construction

A rule does not construct an opaque value from its representation; `Key(some_bytes)` is refused with `DS_VALIDATE_OPAQUE_NO_OP`.

An opaque value originates from a fact slot or call argument of the type, populated from the representation at the host boundary; from a declared operation that returns the type; or from a constant declared in a library. A rule uses a declared constant and mints no other value.

*(Spec: [LOPQ.4.1], [LOPQ.4.2], [LOPQ.11])*

### Elimination

A rule does not eliminate an opaque value to its representation; `<opaque>::T` for any non-opaque `T` is refused with `DS_VALIDATE_OPAQUE_NO_OP`.

*(Spec: [LOPQ.4.3], [LOPQ.11])*

## Type rules

### Flow

An opaque value flows like a scalar: slot value, `let` binding, call argument, pattern binding and fact slot.

It has no fields and is not a fact. A schema may have an opaque-typed slot.

```ds declaration
opaque type Key over Bytes
schema Sample scope logical:
    id: String key
    token: Key mutable
```

*(Spec: [LOPQ.1.2], [LOPQ.5.1], [LOPQ.9.2])*

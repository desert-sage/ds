<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Json

## The type

### Json slot

**`<slot>: Json`**

`Json` is the field type for an opaque payload, read through dot and bracket operators, with runtime-typed leaves.

It offers path projection (`a.b[0]`), `has`, `len` and [structural equality with no ordering](#json-equality), and no element enumeration. A wrong-typed leaf is a [Json leaf mismatch](#json-leaf-mismatch). The C view is [Json](inv:integrator:std:doc#facts/json).

```ds declaration
schema Doc scope logical:
    id: String key
    payload: Json mutable
```

*(Spec: [LGRA.5.8.1], [LCNT.7.1])*

### Json literal

A `Json` value enters from outside the rule; a rule writes none as a literal, and [a fact converts to none](conversions.md#refused-conversions).

A `json()` call outside a [test block](../tools/dstest.md#test) is refused with `DS_VALIDATE_JSON_LITERAL_REFUSED`.

*(Spec: [LGRA.5.8.3], [LGRA.9.8.3])*

### Chaining

A bracket index or further dotted segment past a slot addresses a part of its value only where the slot is `Json`.

Past a slot of any other builtin type a bracket index is refused with `DS_VALIDATE_BAD_PATH`, and a dotted segment is a member read.

```ds expression error=DS_VALIDATE_BAD_PATH
r.n[0]
```

*(Spec: [LGRA.5.8.5])*

### Path resolution

A path that does not resolve is absent: it reads as `null`, and `has` of it is `false`.

A path does not resolve where a segment names a missing key, or addresses a value that is not its container: a key into an array or a scalar, an index into an object or a scalar. A path present with JSON `null` reads as `null`, a value and not absence. `has` is the only absence test.

A path read whose root is `null`, a `Json?` slot holding none, reads as `null` and raises no fault; it propagates as an operator over a `null` operand does.

*(Spec: [LNUL.8.4], [LNUL.4.1])*

### Json leaf mismatch

A `Json` leaf whose runtime type does not match an arithmetic or comparison operator raises a `TypeError`.

Unless a deciding operand absorbs it, the activation is abandoned and the fault reaches the fault surfaces, a `TypeError` fault fact among them. The operation does not evaluate to `false`, and nothing propagates. An absorbed `TypeError` reaches no surface. The surfaces are its only report: no metric counts it and the engine logs nothing for it.

*(Spec: [LEXP.7.12], [LEXP.7.12.1], [LEXP.7.12.3])*

### Json leaf conversion

**`<value>::T`**, **`<value>::T?`**

A value whose kind is known only at runtime converts by the kind it holds when the conversion runs.

Such a value is a leaf a path reads from a `Json` value, a value computed from one, `x ?? d` with `x` such a value, whatever type `??` gives it, and a `let` name with no annotation bound to one. Such a value has no type the compiler can determine, so a [`let` annotation](../units/checking.md#let-annotation) over it is refused. The conversion takes the [defined conversion](conversions.md#defined-conversions) for that kind, and its class. A `null` gives `null`. A kind with no conversion to `T`, an array or an object among them, raises a [`TypeError`](../errors/fault-facts.md#typeerror-fact). A JSON `31` and a JSON `31.5` both convert under `::Float?`, a JSON `"31.5"` parses as a `String` does, and a JSON `true` is a `TypeError`.

The `?` follows [the question mark rule](conversions.md#the-question-mark-rule). Such a value is a nullable source, and an `is not null` guard does not narrow it; `x ?? d` with a `d` that is not nullable, and a `let` name bound to one, is not. The conversion is fallible when `T` is `Int`, `Float` or `Bool`, which a `String` reaches by a parse, and total otherwise. A missing `?` and a redundant one are refused with `DS_VALIDATE_CAST_NULLABILITY`. With `j.a` a JSON `31.5`, `(j.a ?? 0)::Float?` is `31.5`, and `(j.a ?? 0)::String` takes no `?`. `j.a::String?` takes its `?` after `j.a is not null and` as well. A whole `Json` value, read with no path, is a [refused conversion](conversions.md#refused-conversions).

*(Spec: [LCST.4.5.11], [LCST.4.5.2], [LCST.4.3.1], [LLET.3.5], [LUNI.8.6])*

### Json equality

**`a == b`**, **`a != b`**

Two `Json` operands compare by deep structural equality, the same test a no-op reassertion applies.

`<`, `<=`, `>` and `>=` with either operand a whole `Json` value are refused at the operator with `DS_VALIDATE_UNORDERED_TYPE`. In a [comparison chain](../expr/operators.md#comparison-chains) each step is judged on its own two operands. A whole `Json` value is a `Json` slot read without a path. A `null` operand propagates.

*(Spec: [LEXP.7.19])*

## Introspection

### len of Json

**`len(<Json>)`**

`len` on a `Json` value returns its array length at run time, as `Int`.

It raises a `TypeError` if the value is not an array, abandoning the activation.

*(Spec: [LEXP.6.1], [LEXP.6.2])*

### has

**`has(<Json path>)`**

`has` returns whether the path resolves, as `Bool`.

*(Spec: [LEXP.6.1], [LEXP.6.2])*

## Values

### Json limits

A `Json` value a runtime holds is within four limits.

| Limit | Maximum | Counted as |
|---|---|---|
| depth | 16 | a scalar, or an empty array or object, is one level; each enclosing array or object adds one |
| nodes | 256 | every scalar, array and object in the value, the root included |
| string bytes | 16,384 | the UTF-8 bytes of every string and object key, summed |
| text | 24,576 | the bytes of JSON text handed to a parse |

Depth, nodes and string bytes hold wherever a `Json` value comes into being. The text limit holds for text handed to a parse and is checked before any of it is read; a runtime's own serialization is exempt. A value over a limit is refused, never truncated. Inside a rule, the engine raises a `ComputationError` of kind `NOT_REPRESENTABLE` and abandons the activation. A host call that would admit one returns a status, under [Json](inv:integrator:std:doc#facts/json).

*(Spec: [LGRA.5.8.6])*

### Json objects

A `Json` object names each key once; JSON text with a repeated key in one object is malformed.

Two keys are one key when their strings are equal once escapes are resolved, compared as UTF-8 bytes: `"a/b"` and `"a\/b"` are one key. A runtime keeps neither member over the other: it refuses the text.

*(Spec: [LGRA.5.8.7])*

### Json integers

A `Json` integer is a 64-bit signed integer; JSON text with an integer literal outside that range is malformed.

`9223372036854775807` and `-9223372036854775808` are held. `9223372036854775808` and `-9223372036854775809` are malformed. A runtime neither saturates such a literal nor reads it as a float.

*(Spec: [LGRA.5.8.9])*

### Json floats

A `Json` value holds no `±Inf` and no NaN.

A number literal with a fraction or an exponent reads as the nearest `Float`, ties to even. A literal past the largest finite `Float` is malformed, and is neither read as an infinity nor saturated. A literal that rounds to zero is `+0.0`. `1.7976931348623157e308` is held, `1e-400` is `+0.0`, and `1.8e308` and `-1e400` are malformed.

*(Spec: [LGRA.5.8.10])*

### Json float zero

Every float zero a `Json` value holds is `+0.0`; a `-0.0` becomes `+0.0` where the value comes into being.

The zero stays a float, a different kind from an integer `0`. A `Float` slot keeps `-0.0`. A leaf read of a JSON `-0.0` is `+0.0`.

*(Spec: [LGRA.5.8.8])*

### Json text

A runtime writes a `Json` value as one text.

- No whitespace between tokens.
- An object's members in ascending key order, compared as UTF-8 bytes.
- In a string or key: `"` and `\` as `\"` and `\\`; `U+0008`, `U+000C`, `U+000A`, `U+000D` and `U+0009` as `\b`, `\f`, `\n`, `\r` and `\t`; any other character below `U+0020` as `\u00` and two lowercase hexadecimal digits; every other character as its own UTF-8 bytes.
- An integer in decimal, with `-` for a negative one.
- A `Float` in the canonical form.
- `true`, `false` and `null` as themselves.

*(Spec: [LGRA.5.8.7a])*

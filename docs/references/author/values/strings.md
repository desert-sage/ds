<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Strings and bytes

## String

### String values

A `String` value is an immutable sequence of Unicode codepoints.

Every codepoint in `U+0001` to `U+10FFFF` is admissible except the surrogates `U+D800` to `U+DFFF`. An operation that produces modified text returns a new `String`. The empty string is admissible and is present, with length zero, as distinct from a missing slot.

*(Spec: [LSTR.1.1], [LSTR.1.3], [LSTR.1.4], [LSTR.9.1])*

### U+0000

`U+0000` is refused where it would enter a `String`, a `Json` string or a `Json` object key.

A literal that spells it is a compile error. A host call that supplies it, JSON text holding it raw or as `\u0000`, a recording and an artefact are each refused. A value is never truncated at a `U+0000`, and a `U+0000` is never dropped.

*(Spec: [LSTR.1.1], [LSTR.1.5])*

### String encoding

The wire form of a `String` between runtime, host and storage is UTF-8.

*(Spec: [LSTR.1.2])*

### String length

**`len(s)`**

`len` on a `String` returns its number of Unicode codepoints, as `Int`.

`café` with a precomposed `é` has length 4. `U+1F44B U+1F3FD` has length 2.

```ds expression
len(r.label)
```

*(Spec: [LSTR.2.1], [LSTR.9.2])*

### String equality

**`a == b`**

Two strings are equal iff they have the same length and matching codepoints at every position.

No normalisation applies: `café` with `U+00E9` is not equal to `café` with `U+0065 U+0301`.

*(Spec: [LSTR.3.1], [LSTR.9.3])*

### String ordering

**`a < b`**

String ordering is lexicographic by codepoint value, which is UTF-8 byte order for a well-formed pair, and is not locale-aware.

```ds expression
r.label == "a"
r.label < "b"
```

*(Spec: [LSTR.3.2])*

### Regex on strings

[Regex patterns and matches](../expr/regex.md) operate on `String` values at the codepoint level.

A regex on a `Bytes` value is refused with `DS_VALIDATE_REGEX_ON_BYTES`.

*(Spec: [LSTR.7.1.1], Source: compiler/mercury/src/dsc.typecheck.m)*

### JSON strings

A JSON string is a `String`; a path read that yields one returns a `String`. The wire encoding is UTF-8.

*(Spec: [LSTR.7.2.1], [LSTR.7.2.2])*

### JSON text escapes

A `\u` escape in JSON text names one UTF-16 code unit.

A high-surrogate escape followed at once by a low-surrogate escape names the one codepoint above `U+FFFF` the pair encodes. Any other surrogate escape makes the text malformed JSON, and the reader refuses it.

*(Spec: [LSTR.7.2.3])*

### Interpolation result

An [interpolation](../actions/actions.md#interpolation-site) expression produces a `String`, a sequence of codepoints.

*(Spec: [LSTR.7.3.1])*

## Bytes

### Bytes values

A `Bytes` value is an immutable sequence of octets with no encoding metadata.

The language does not interpret it as text. An operation that produces modified bytes returns a new `Bytes` value. A rule stores one in a slot, [compares it for equality](#bytes-equality) and passes it to a call.

*(Spec: [LSTR.4.1], [LSTR.4.4], [LSTR.4.6])*

### Bytes equality

**`a == b`**, **`a != b`**

Two `Bytes` operands are equal iff they have the same length and the same octet at every position.

`<`, `<=`, `>` and `>=` with either operand `Bytes` are refused at the operator with `DS_VALIDATE_UNORDERED_TYPE`. In a [comparison chain](../expr/operators.md#comparison-chains) each step is judged on its own two operands. A `null` operand propagates.

*(Spec: [LEXP.7.19])*

### Bytes length

**`len(b)`**

`len` on a `Bytes` value returns its byte count, as `Int`.

*(Spec: [LSTR.4.2])*

### Bytes and String conversion

`String` and `Bytes` are distinct types with no conversion in either direction.

`==` between a `String` and a `Bytes` is refused with `DS_VALIDATE_TYPE_MISMATCH`. A `::` cast from `Bytes` to `String`, or from `String` to `Bytes`, is refused with `DS_VALIDATE_BYTES_CONVERSION_RETIRED`.

*(Spec: [LSTR.4.5], [LSTR.4.6], Source: compiler/mercury/src/dsc.typecheck.m)*

## Capacity

### String capacity

**`<slot>: String capacity N`**

`capacity N` bounds a `String` slot to at most `N` codepoints, counted as `len` counts them; `N` is a positive integer, and a slot without it is unbounded.

- A slot of any other type is refused with `DS_VALIDATE_CAPACITY_BAD_TYPE`.
- An `N` below 1 is refused with `DS_VALIDATE_CAPACITY_NOT_POSITIVE`.
- A string literal written to a slot it exceeds is refused with `DS_VALIDATE_CAPACITY_LITERAL_EXCEEDED`.
- `capacity` is required only where a capability's clause requires it: under [`linear_scan: false`](../capabilities/linear-scan.md#linear_scan-false), on a `String` slot read by a regex match or an ordering comparison.

```ds declaration
schema Line scope logical:
    id: String key
    text: String capacity 8 mutable
```

*(Spec: [LSTR.11.1], [LSTR.11.2], [LSTR.11.4])*

### Capacity at run time

A longer value that reaches the slot at run time, in an asserted or an emitted fact, is a bounds refusal.

The value is not stored or truncated, and the assert or the emit does not happen. The `BoundsError` names `CAP_VALUE_CAPACITY`, with the capacity as its limit and the value's length as the observed count. A refused emit stops its firing there: the actions after it do not run.

*(Spec: [LSTR.11.3])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Schemas

## Declaration

### `schema`

```text
schema_decl ::= 'schema' NAME schema_lifecycle? ':' NEWLINE
                INDENT
                    docstring?
                    field_decl+
                DEDENT
schema_lifecycle ::= 'scope' scope_value
scope_value      ::= 'explicit'
                  |  'activation'
                  |  'logical' 'ambient'?
                  |  'ttl' time_expr 'ambient'?
docstring ::= STRING_LIT NEWLINE
```

A schema declaration names a fact type, its [scope](lifecycles.md#scope-values) and its slots.

With no `schema_lifecycle`, the scope is `explicit`. The name enters the [type namespace](../lang/program.md#type-namespace), and a library schema's name is its [own name](../lang/imports.md#own-name). A bare string literal as the first statement of the body is the schema's docstring.

```ds declaration
schema Sample scope logical:
    "A sample."
    id: String key
    state: Float mutable
```

*(Spec: [LGRA.5.1], [LGRA.5.2], [LGRA.5.6], [LSCP.1.3], [LSCP.1.4])*

### Scope clause refusals

| Form | Code |
|---|---|
| `schema Foo logical:`, `schema Foo ttl <duration>:` | `DS_VALIDATE_LEGACY_SCHEMA_LIFECYCLE` |
| `schema Foo scope ambient:` | `DS_VALIDATE_BARE_AMBIENT_SCOPE_RETIRED` |
| `schema Foo scope ttl <duration> ambient:` | `DS_VALIDATE_TTL_AMBIENT_NOT_IN_V1` |

*(Spec: [LSCP.1.6], [LSCP.1.7], [LSCP.2.5.9])*

### Slot limit

A schema holds at most 255 slots; more is refused with `DS_VALIDATE_SCHEMA_TOO_MANY_SLOTS`.

The limit counts every slot, and binds every schema the program declares or the compiler declares for it.

*(Spec: [LGRA.5.11])*

### Generated `.proto`

The compiler generates one `.proto` per schema and ships it inside the `.dsc`.

The `.proto` has one field per slot, `optional` exactly when the slot is nullable. The C view of a schema is [Schemas](inv:integrator:std:doc#facts/schemas), and the engine's is [the data model](inv:internals:std:doc#overview/data-model).

*(Spec: [LFAC.8.2], [LFAC.8.3], [LFAC.8.5])*

## Slots

### Slot declaration

```text
field_decl ::= NAME ':' field_type NULLABLE? field_capacity? slot_marker* field_tolerance? STRING_LIT? NEWLINE
field_capacity ::= 'capacity' INT_LIT
field_type ::= TYPE_SYM
slot_marker ::= 'key' | 'mutable'
field_tolerance ::= 'tolerance' (INT_LIT | FLOAT_LIT)
```

A slot declaration names one value of a fact, with an optional trailing docstring.

`NULLABLE` is [`T?`](../values/null.md#nullable-types). `field_capacity` is [String capacity](../values/strings.md#string-capacity).

*(Spec: [LGRA.5.1], [LGRA.5.7])*

### Slot types

A `field_type` resolves in the type namespace: a builtin type, a declared unit symbol, dimension or scalar-group name, or a declared schema.

A type that resolves to none of these is refused with `DS_VALIDATE_UNKNOWN_TYPE`. `Bytes` is a scalar at a slot, as at every type position, and its values are [Bytes values](../values/strings.md#bytes-values). A [`Json` slot](../values/json.md#json-slot) is the one builtin type access chains past.

*(Spec: [LGRA.5.7.1], [LGRA.22.7], [LSTR.4.6])*

### `key` and `mutable`

**`key`**, **`mutable`**

`key` puts a slot in a `logical` fact's [identity](lifecycles.md#identity); `mutable` makes it payload.

- Every slot of a `logical`-based schema but `ts` carries one of the two. An unmarked slot is refused with `DS_VALIDATE_IDENTITY_ROLE_REQUIRED`.
- Either marker on any other base is refused with `DS_VALIDATE_IDENTITY_ROLE_NON_LOGICAL`.

```ds declaration error=DS_VALIDATE_IDENTITY_ROLE_REQUIRED
schema Sample scope logical:
    id: String
```

*(Spec: [LGRA.5.10], [LFAC.1.7.1], [LFAC.1.7.4], [LFAC.1.7.6], Source: compiler/mercury/src/dsc.validate.m)*

### Slot values

A slot holds its own value: a value read from another fact stays unchanged when that fact is retracted, superseded or expires.

This holds for every type, `Json` and `Bytes` included. A [schema-typed slot](#schema-typed-slots) is the exception.

*(Spec: [LFAC.10.1])*

## References

### Schema-typed slots

A slot whose type resolves to a schema holds a [fact reference](#fact-references) to a fact of that schema.

The slot is written once, by an [`emit`](../actions/emit-publish.md#emit) or [`publish`](../actions/emit-publish.md#publish) kwarg.

*(Spec: [LGRA.5.7a.1], [LGRA.5.7a.2])*

### Fact references

A fact reference is a pattern binding read with no slot, a `let` bound to a fact reference, or a read of a schema-typed slot.

`a == b` is `true` when both name one fact, and `a != b` is its negation. Equal keys or equal slots do not make two facts one. A no-op reassertion leaves a fact the same fact; a meaningful change replaces it with another. References to facts of different schemas are never equal. A `null` operand propagates. Inside a negated pattern's `where`, that pattern's binding is the candidate fact.

`<`, `<=`, `>` and `>=` with a fact reference as either operand are refused with `DS_VALIDATE_UNORDERED_TYPE`.

```ds rule
rule distinct_pair:
    Reading a
    Reading b where a != b
->
    log info "{a.id}"
```

*(Spec: [LEXP.7.20])*

## The `ts` slot

### `ts`

**`ts: Time`**

A schema may declare a slot named `ts`, the fact's time, which the engine owns.

- `ts` is a non-nullable `Time`. Any other type, `Time?` included, is refused with `DS_VALIDATE_TS_NOT_TIME`.
- A `key` or `mutable` marker on it is refused with `DS_VALIDATE_TS_MARKED`.
- A schema named by `latest`, and every schema in a `then` sequence, declares it.
- It is outside the [identity key](lifecycles.md#identity) and outside the [no-op comparison](lifecycles.md#no-op-reassertion).

*(Spec: [LFAC.9.1])*

### `ts` source

A fact takes its `ts` when it enters working memory, by where it comes from.

| Source | `ts` |
|---|---|
| `emit`, `publish` | the wall clock's current sample, as a UTC `Time`, filled before any slot value is evaluated |
| an [`initial` block](initial.md#application) | the wall clock's sample of the step that consumes it |
| a host input | supplied by the host, as in [Asserting](inv:integrator:std:doc#facts/asserting) |
| a [test input](../tools/dstest.md#inputs) | supplied by the test runner: the `at` coordinate in absolute mode, its offset from the Unix epoch in relative mode |

*(Spec: [LFAC.9.2])*

### `ts` read-only

`ts` is read wherever a slot is read, and no author writes it.

A `ts` value in an `emit`, a `publish` or a [test's constructed fact](../tools/dstest.md#construction) is refused with `DS_VALIDATE_TS_READ_ONLY`.

```ds rule error=DS_VALIDATE_TS_READ_ONLY
schema Stamp scope logical:
    id: String key
    ts: Time

rule stamp:
    Reading r
->
    emit Stamp logical id: r.id ts: r.ts
```

*(Spec: [LFAC.9.3])*

## Slot tolerance

### `tolerance`

**`tolerance` (`INT_LIT` | `FLOAT_LIT`)**

`tolerance` declares a `mutable` slot's no-meaningful-change deadband, compared in the [no-op test](lifecycles.md#no-op-reassertion).

The literal is unsigned, finite and carries no unit. `tolerance 0` is exact equality, as is a slot with no `tolerance`.

```ds declaration
schema Sample scope logical:
    id: String key
    level: Float mutable tolerance 0.5
```

*(Spec: [LGRA.5.1], [LGRA.5.9.7], [LGRA.5.9.8], [LGRA.5.9.9], [LUNI.7.4])*

### Tolerance on a unit-typed slot

The literal is a difference in the [unit-typed slot](../units/checking.md#unit-typed-slots)'s declared unit, converted to the base unit by scale only.

For a unit converting as `y = a*x + b`, the tolerance in the base unit is `|a|` times the literal, and `b` is dropped. `tolerance 1` on a `fahrenheit` slot is a deadband of 5/9 kelvin. The result is written as a `Float`, including where the dimension's storage is an integer.

*(Spec: [LUNI.7.3], [LUNI.7.4])*

### Tolerance refusals

| Condition | Code |
|---|---|
| on a `key` slot | `DS_VALIDATE_TOLERANCE_ON_KEY` |
| on a `ttl` schema | `DS_VALIDATE_TOLERANCE_TTL_SCHEMA` |
| on any other non-`logical` schema | `DS_VALIDATE_TOLERANCE_NON_LOGICAL` |
| on a slot other than `Float`, `Int`, or a base or tier-1 unit symbol: a tier-2 unit, a dimension or scalar-group name, any other type | `DS_VALIDATE_TOLERANCE_BAD_TYPE` |
| a literal whose type does not match the slot's | `DS_VALIDATE_TOLERANCE_LITERAL_TYPE` |

One slot reports one tolerance refusal, the first row that applies.

```ds declaration error=DS_VALIDATE_TOLERANCE_ON_KEY
schema Sample scope logical:
    id: Float key tolerance 0.5
```

*(Spec: [LGRA.5.9.4], [LGRA.5.9.5], [LGRA.5.9.6], [LGRA.5.9.10], [LFAC.2.6.4], Source: compiler/mercury/src/dsc.validate.m)*

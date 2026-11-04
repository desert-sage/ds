<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Unit checking

## Rational

### Rational type

`Rational` is an exact compile-time numeric type `p/q`, with `q > 0`, in reduced form with the sign on the numerator.

It has no slot type. The compiler folds Rational arithmetic before code generation, and a Rational literal in a rule expression promotes to `Float` at run time. Overflow of the `int64` numerator or denominator during compile-time arithmetic is a compile error.

*(Spec: [LUNI.2.1], [LUNI.2.4])*

### Rational literal

**`INT_LIT / INT_LIT`**

`INT_LIT / INT_LIT`, wherever it appears, is a `Rational` reduced at parse time.

Division by literal zero is refused with `DS_VALIDATE_DIV_BY_ZERO`. `/` with a non-literal operand is [runtime division](../values/numbers.md#true-division).

```ds expression
r.level * 5/9
```

*(Spec: [LUNI.2.2])*

### Rational promotion

`Int` promotes to `Rational` and `Rational` to `Float`, implicitly.

| Expression | Result |
|---|---|
| `Rational * Rational` | `Rational` |
| `Rational * Int` | `Rational` |
| `Rational + Float` | `Float` |
| `Float * 5/9` | `Float` |
| `Rational * math.pi` | `Float` |

*(Spec: [LUNI.2.3], [LUNI.2.6])*

### Rational arithmetic

| Operation | Result |
|---|---|
| `a/b + c/d` | `(ad+bc) / bd`, reduced |
| `a/b * c/d` | `ac / bd`, reduced |
| `a/b / c/d` | `ad / bc`, reduced; an error if `c` is 0 |
| `(a/b) ** n`, `Int` `n` at least 0 | `aⁿ / bⁿ` |
| `-(a/b)` | `(-a) / b` |

*(Spec: [LUNI.2.5])*

## Unit types in schemas

### Unit-typed slots

**`<slot>: <unit>`**

A declared unit symbol is a slot type, resolved to its dimension, storage type and conversion parameters.

```ds declaration
schema Sample scope logical:
    id: String key
    span: meter mutable
```

*(Spec: [LUNI.7.1])*

### Dimension-typed slots

**`<slot>: <dimension>`**

A declared dimension or scalar-group name is a slot type, typed by the dimension and naming no unit.

A same-dimension value written to it converts to the base unit. A dimension name is a type only for a slot and a service kwarg, so no unit literal is written with it, and a `let` or `const` annotation refuses it.

*(Spec: [LUNI.7.1])*

### Slot storage

A unit-typed slot is stored in its dimension's base unit, whichever unit it declares.

`temp: fahrenheit` stores kelvin as `float64`, and `duration: millisecond` stores nanoseconds as `int64`. A `float64` value that lands in `int64` storage, a `unit formula` result included, casts by `roundTiesToEven`.

*(Spec: [LUNI.7.2], [LUNI.17.5])*

### Aliases in slots

An alias as a slot type is refused with `DS_VALIDATE_SLOT_TYPE_ALIAS`.

```ds declaration error=DS_VALIDATE_SLOT_TYPE_ALIAS
schema Sample scope logical:
    id: String key
    span: m mutable
```

*(Spec: [LUNI.7.5])*

## Type checking in expressions

### Same dimension

Operations and comparisons between values of one dimension are valid, and both operands convert to the base unit before combining.

```ds expression
r.level::kelvin + 5_K
```

*(Spec: [LUNI.8.1])*

### Cross dimension

Operations between values of different dimensions or scalar groups are refused with `DS_VALIDATE_DIM_MISMATCH`.

```ds expression error=DS_VALIDATE_DIM_MISMATCH
r.level::meter + 5_kg
```

*(Spec: [LUNI.8.2])*

### Bare scalars

A dimensioned value multiplied, divided, added to or subtracted from a unit-less scalar keeps its dimension.

*(Spec: [LUNI.8.3])*

### Two dimensioned values

Multiplication and division of two dimensioned values require a `let` type annotation for the result.

No unit algebra applies. Without the annotation, the operation is refused with `DS_VALIDATE_DIM_AMBIGUOUS`, as are `//` and `**` on dimensioned operands. Stripping both operands, `r.a::Float / r.b::Float`, gives a plain `Float` operation.

```ds expression error=DS_VALIDATE_DIM_AMBIGUOUS
r.level::meter * r.level::meter
```

*(Spec: [LUNI.8.4], [LUNI.8.7.2], Source: compiler/mercury/src/dsc.typecheck.m)*

### Assertion and strip

**`<number>::<unit>`**, **`<unit value>::<number>`**

`<number>::<unit>` asserts the dimension tag without applying the affine factor, and `<unit value>::<number>` strips it.

Both are total and zero-cost. The number is `Float` for a `float64` dimension and `Int` for an `int64` or `int32` one, and a strip yields the stored base-unit number, on a dimension-typed value too. Any other source is an [undefined pair](../values/conversions.md#refused-conversions). Assigning a number to a unit-typed slot without the assertion is a compile error.

*(Spec: [LUNI.8.5])*

### Dimension through a cast

The dimension of `x::<unit>` is that unit's dimension, and the result checks as a native value of that unit.

The cast contributes the dimension and not the scale, so `r.a::celsius + r.b::kelvin` is valid. `x::Float` has no dimension.

*(Spec: [LUNI.8.7], [LUNI.8.7.1], [LUNI.8.7.2], [LUNI.8.7.4])*

### Leaf kind and dimension

A unit-typed slot read and a `::<unit>` cast report two independent facets: the storage's leaf kind and the unit's dimension.

The leaf kind is `Float` for `float64` and `Int` for `int64` or `int32`, and drives the numeric and [bitwise](../values/numbers.md#bitwise-operators) operand checks. A quantity in an `int64` dimension is an `Int` with a dimension, and its arithmetic is `Int` arithmetic. The dimension drives the checks on this page.

*(Spec: [LUNI.8.7.3])*

### let annotation

**`let <name>: <type> = <expr>`**

A `let` annotation claims the type the right-hand side already has; the compiler checks it, and it never converts or drops a unit.

`<type>` is `String`, `Int`, `Float`, `Bool`, `Json`, `Time`, `Date`, `Duration` or a canonical unit symbol. The check is on the right-hand side's result. A unit annotation on a value of the same dimension changes nothing, and one on a plain `Float` asserts the unit as `::<unit>` does.

| Annotation | Refused with |
|---|---|
| a scalar or temporal type on another kind; a unit on a non-number; a right-hand side of undeterminable type | `DS_VALIDATE_LET_TYPE_MISMATCH` |
| unitless `Float` or `Int` on a value with a unit; a unit of another dimension, unless exactly one `implicit` formula bridges them | `DS_VALIDATE_LET_DIM_MISMATCH` |
| an alias, a dimension name, or a type name of another sort, such as a schema | `DS_VALIDATE_LET_BAD_ANNOTATION` |
| a name that resolves to no type | `DS_VALIDATE_UNKNOWN_TYPE` |

```ds action
let d: meter = r.level::meter
log info "{d} {d:u}"
```

*(Spec: [LUNI.8.6])*

## Interpolation

### Display unit

Interpolation displays a value in the declared slot unit, never the storage base.

The display round trip through the base is not the identity for an affine unit whose factor is not a power of two: the displayed value can differ from the source by a few ULP.

*(Spec: [LUNI.11.1], [LUNI.11.1.1])*

### Unit format

**`{x:u}`**

The `u` format renders the unit's label alone.

A value with its label is two sites, `{x} {x:u}`. `u` on a number with no unit is refused with `DS_VALIDATE_INTERP_UNIT_NON_UNIT`. The label is the declaration's `label` string, else the unit symbol.

| Slot type | No format | `:f`, `:.2f` | `:u` |
|---|---|---|---|
| `Float` | bare number | bare number | refused |
| unit-typed | bare number | bare number | the label alone |

```ds action error=DS_VALIDATE_INTERP_UNIT_NON_UNIT
log info "{r.level:u}"
```

*(Spec: [LUNI.11.2], [LUNI.11.3], [LUNI.11.4])*

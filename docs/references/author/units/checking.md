<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Unit checking

## Rational

### Rational type

`Rational` is an exact compile-time numeric type `p/q`, with `q > 0`, in reduced form with the sign on the numerator.

It has no slot type. The compiler folds Rational arithmetic exactly before code generation: at compile time a `Rational`'s numerator and denominator are integers of any size. A Rational literal in a rule expression promotes to `Float` at run time. A constant that a runtime value cannot hold is refused as [Whole base units](literals.md#whole-base-units) and [Tier 1](declarations.md#tier-1) state.

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

What a host asserts into a slot typed by a unit or a dimension, and reads from it, is the slot's stored number ([Asserting](inv:integrator:std:doc#facts/asserting), [Schemas](inv:integrator:std:doc#facts/schemas)). An author whose host holds a number in another unit may instead declare the slot `Float` and assert the unit in the rule with [`::<unit>`](#assertion-and-strip).

*(Spec: [LUNI.7.2], [LUNI.17.5], [LUNI.7.6], [LUNI.8.5])*

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

`+`, `-`, `%` and the comparisons between values of one dimension are valid, and both operands convert to the dimension's base unit before combining.

`/` and `//` between values of one dimension are valid and give a bare number: `/` a `Float` ([True division](../values/numbers.md#true-division)), `//` by its operands ([Floor division](../values/numbers.md#floor-division)). A `unit scalar` group is a dimension here.

```ds expression
r.level::kelvin + 5_K
r.level::meter / 2_m
```

*(Spec: [LUNI.8.1])*

### Cross dimension

Two values of different dimensions, or of different scalar groups, are refused, and the operator decides the code.

| Operator | Code |
|---|---|
| `+`, `-`, `%`, the comparisons, and the [forms over two values](#forms-over-two-values) | `DS_VALIDATE_DIM_MISMATCH` |
| `*`, `/`, `//`, `**` ([Two dimensioned values](#two-dimensioned-values)) | `DS_VALIDATE_DIM_AMBIGUOUS` |

```ds expression error=DS_VALIDATE_DIM_MISMATCH
r.level::meter + 5_kg
```

*(Spec: [LUNI.8.2])*

### Bare numbers

A number with no unit is dimensionless, and takes no dimension or unit from the operand beside it.

`x * n`, `n * x`, `x / n` and `x // n` have `x`'s dimension. A [`Duration`](../time/types.md#duration) scaled this way is at [Time and Duration](../time/arithmetic.md#time-and-duration).

A bare number beside a dimensioned value is refused with `DS_VALIDATE_DIM_MISMATCH` as an operand of `+`, `-` or `%`, in either order, and in a comparison, a literal zero included. A `unit formula`'s function checks a bare argument the same way. `n / x` and `n // x` are at [Two dimensioned values](#two-dimensioned-values).

A literal, a slot typed `Int` or `Float`, a `::Float` strip and a same-dimension quotient are bare numbers. An operand whose type the compiler cannot determine is not one. A value of a `unit scalar` group is dimensioned. The rule does not reach the body of a unit declaration or a `unit formula`.

```ds expression error=DS_VALIDATE_DIM_MISMATCH
r.level::meter + 1.0
r.level::meter > 0
```

*(Spec: [LUNI.8.3])*

### Two dimensioned values

No unit algebra applies.

`*` of two dimensioned values, `/` and `//` of two values of different dimensions, `/` and `//` of a bare number by a dimensioned value, and `**` or `math.pow` with a dimensioned operand on either side are refused with `DS_VALIDATE_DIM_AMBIGUOUS`, under a `let` annotation too.

A `::Float` strip of each operand gives base-unit numbers, a `time` value's in nanoseconds, and a [`::<unit>`](#assertion-and-strip) assertion on the result states its unit: `(r.w::Float * r.h::Float)::meter_squared`.

```ds expression error=DS_VALIDATE_DIM_AMBIGUOUS
r.level::meter * r.level::kilogram
1.0 / r.level::meter
```

*(Spec: [LUNI.8.4], [LUNI.8.6], [LUNI.8.7.2])*

### Forms over two values

The operands of the two-argument `min` and `max`, of `??` and of `..`, the point and the interval of `in`, and two intervals a relation or an equality compares are checked as the operands of `+` are.

A bare number beside a dimensioned value, a `Duration` included, and two values of different dimensions are refused with `DS_VALIDATE_DIM_MISMATCH`. Values of one dimension are valid, and the result has that dimension. An interval of them carries it, and a point or another interval is checked against it. An operand whose type the compiler cannot determine is not refused.

```ds expression error=DS_VALIDATE_DIM_MISMATCH
max(r.level::meter, 1.0)
```

*(Spec: [LUNI.8.8])*

### Builtins over a dimensioned value

`round`, `math.floor`, `math.ceil` and `math.trunc` over a dimensioned value round in the value's own unit and give a value of that unit: `round` of a `celsius` value of 21.5 is 22 `celsius`.

`math.sign` reads the value in its own unit and gives a bare `Int`. `abs` gives a value of its argument's type, unit included. `math.pow` is refused as `**` is ([Two dimensioned values](#two-dimensioned-values)).

A value's own unit is the unit its static type names: the declared unit of a slot or a kwarg, a literal's unit, the target of a `::<unit>` cast, a [`let` annotation](#let-annotation), and, for an operation over values of one dimension, its left operand's unit. A value whose type names no unit, such as a [dimension-typed slot](#dimension-typed-slots)'s, is in its dimension's base unit.

Every other builtin whose parameter is `Int` or `Float` refuses a dimensioned argument, a `unit scalar` group's value and a `Duration` included, with `DS_VALIDATE_DIM_MISMATCH`. A `::Float` strip admits it, and the builtin receives the base-unit number. The refusal does not reach `min` and `max` ([Forms over two values](#forms-over-two-values)), `math.fma`, an `angle` argument to a [transcendental function](../expr/math.md#transcendental-functions) or to `great_circle`, an operand whose type the compiler cannot determine, or the body of a unit declaration or a `unit formula`.

```ds expression head error=DS_VALIDATE_DIM_MISMATCH
import math
math.sqrt(r.level::meter)
```

*(Spec: [LUNI.8.9], [LEXP.3.2])*

### Assertion and strip

**`<number>::<unit>`**, **`<unit value>::<number>`**

`<number>::<unit>` takes the number as being in that unit, and `<unit value>::<number>` strips the dimension.

The assertion applies the unit's conversion: the result is the value the number names, held in the base unit. `35.0::celsius` is 35 `celsius`, and `5::second` is 5 seconds. The strip is an identity at runtime, and yields the stored base-unit number, of a unit-typed and a [dimension-typed](#dimension-typed-slots) value alike. A strip and an assertion into the base unit are inverses. A strip followed by an assertion into any other unit reads the base-unit number as a number in that unit.

Both are total. The number is `Float` for a `float64` dimension and `Int` for an `int64` or `int32` one. Any other source is an [undefined pair](../values/conversions.md#refused-conversions). Assigning a number to a unit-typed slot without the assertion is a compile error.

```ds expression
r.level::kelvin
r.level::kelvin::Float
```

*(Spec: [LUNI.8.5])*

### Dimension through a cast

The dimension of `x::<unit>` is that unit's dimension, and the result checks as a native value of that unit.

The cast contributes the dimension and not the scale, so `r.a::celsius + r.b::kelvin` is valid. `x::Float` has no dimension.

*(Spec: [LUNI.8.7], [LUNI.8.7.1], [LUNI.8.7.2], [LUNI.8.7.4])*

### Leaf kind and dimension

A unit-typed slot read and a `::<unit>` cast report two independent facets: the storage's leaf kind and the unit's dimension.

The leaf kind is `Float` for `float64` and `Int` for `int64` or `int32`, and drives the numeric and [bitwise](../values/numbers.md#bitwise-operators) operand checks. A quantity in an `int64` dimension is an `Int` with a dimension, and its arithmetic is `Int` arithmetic. A value of the `time` dimension is a [`Duration`](../time/types.md#duration). The dimension drives the checks on this page.

*(Spec: [LUNI.8.7.3])*

### let annotation

**`let <name>: <type> = <expr>`**

A `let` annotation claims the type the right-hand side already has; the compiler checks it, and it never converts or drops a unit.

`<type>` is `String`, `Int`, `Float`, `Bool`, `Json`, `Time`, `Date`, `Duration` or a canonical unit symbol. The check is on the right-hand side's result. A unit annotation on a value of the same dimension changes nothing. Asserting a unit on a number is the [`::<unit>`](#assertion-and-strip) cast's.

| Annotation | Refused with |
|---|---|
| a scalar or temporal type on another kind; a unit on a non-number; a right-hand side of undeterminable type | `DS_VALIDATE_LET_TYPE_MISMATCH` |
| unitless `Float` or `Int` on a value with a unit; a unit of another dimension, unless exactly one `implicit` formula bridges them; a unit on a [bare number](#bare-numbers) | `DS_VALIDATE_LET_DIM_MISMATCH` |
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

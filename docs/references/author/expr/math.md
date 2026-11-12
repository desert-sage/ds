<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Math

## Module access

`abs`, `round`, `min` and `max` are global. Every other function and constant here is a member of the `math` module, reached through [its import](../lang/imports.md#math-distance-and-calendar).

A call with a count its arities do not hold is refused with `DS_VALIDATE_BAD_ARITY`.

```ds expression error=DS_VALIDATE_BAD_ARITY
abs(r.n, 1)
```

*(Spec: [LEXP.3.1], [LIMP.3.3.4])*

## Constants

### `math` constants

| Constant | Value | Literal |
|---|---|---|
| `pi` | π | `3.141592653589793` |
| `e` | e | `2.718281828459045` |
| `tau` | 2π | `6.283185307179586` |

Each is a `Float`, the binary64 nearest its value.

```ds expression head
import math
math.pi * r.level
```

*(Spec: [LIMP.3.3.4], [LEXP.4.1])*

### `inf`

Floating-point infinity, a permitted `Float` value. `inf == inf` holds.

*(Spec: [LEXP.4.1], [LEXP.4.2])*

### `nan`

A reserved identifier that is not a usable value: in a slot value, a `let` or a `::` cast target it is refused with `DS_VALIDATE_NAN_VALUE`.

```ds action error=DS_VALIDATE_NAN_VALUE
let level = nan
log info "{r.id}"
```

*(Spec: [LEXP.4.1], [LEXP.4.2])*

### NaN values

An expression may compute a NaN: `inf - inf`, `inf / inf` and `0.0 * inf` are NaN, and no `Float` operation checks for it. A NaN never enters working memory:

- a NaN `Float` arriving by a host assert is refused with `DS_ERR_NAN_REJECTED`;
- a NaN a rule's activation would put in a slot is a [`TypeError`](../errors/fault-facts.md#typeerror-fact), and the engine abandons the activation;
- a NaN `Float` call argument refuses the call with `DS_ERR_NAN_REJECTED`, and the engine does not issue it. A `±Inf` argument passes.

A `±Inf`, or a NaN an expression produced, forced into a JSON data-plane body is a `NOT_REPRESENTABLE` trap at the verb, and a host call that would build such a value is refused with `DS_ERR_JSON_NONFINITE`.

A NaN's sign and payload are not observable.

*(Spec: [LEXP.4.2], [LEXP.4.3], [LDET.3.2.7])*

## Arithmetic and rounding

A rounding of a `Float` returns an `Int`, and a rounding of a value with a unit a value of that unit. When the mathematical result lies outside the `Int` range, or the argument is not finite, the engine raises a [`ComputationError`](../errors/fault-facts.md#computationerror-fact) of kind `NOT_REPRESENTABLE` and abandons the activation. Every builtin over a value with a unit is at [Builtins over a dimensioned value](../units/checking.md#builtins-over-a-dimensioned-value).

*(Spec: [LEXP.3.2.1], [LEXP.17.2])*

### `abs`

**`abs(x: Int) → Int`**, **`abs(x: Float) → Float`**

The absolute value, of the argument's type.

*(Spec: [LEXP.3.2])*

### `round`

**`round(x: Int) → Int`**, **`round(x: Float) → Int`**, **`round(x: <unit>) → <unit>`**

The nearest integer, ties to even.

```ds expression
round(r.level)
```

*(Spec: [LEXP.3.2])*

### `floor`

**`math.floor(x: Int) → Int`**, **`math.floor(x: Float) → Int`**, **`math.floor(x: <unit>) → <unit>`**

The largest integer not greater than `x`.

```ds expression head
import math
math.floor(r.level)
```

*(Spec: [LEXP.3.2])*

### `ceil`

**`math.ceil(x: Int) → Int`**, **`math.ceil(x: Float) → Int`**, **`math.ceil(x: <unit>) → <unit>`**

The smallest integer not less than `x`.

```ds expression head
import math
math.ceil(r.level)
```

*(Spec: [LEXP.3.2])*

### `trunc`

**`math.trunc(x: Int) → Int`**, **`math.trunc(x: Float) → Int`**, **`math.trunc(x: <unit>) → <unit>`**

`x` truncated toward zero.

```ds expression head
import math
math.trunc(r.level)
```

*(Spec: [LEXP.3.2])*

### `sign`

**`math.sign(x: Int) → Int`**, **`math.sign(x: Float) → Int`**, **`math.sign(x: <unit>) → Int`**

An `Int`: 1 when `x > 0`, −1 when `x < 0`, otherwise 0. `-0.0` and a NaN give 0.

```ds expression head
import math
math.sign(r.level)
```

*(Spec: [LEXP.3.2])*

### `sqrt`

**`math.sqrt(x: Float) → Float`**

The correctly rounded square root. A negative `x` gives NaN.

```ds expression head
import math
math.sqrt(r.level)
```

*(Spec: [LEXP.3.2])*

### `fma`

**`math.fma(x: Float, y: Float, z: Float) → Float`**

IEEE 754's fused multiply-add: `x × y + z`, rounded once to binary64.

The operands are those `x * y + z` admits, under that expression's unit rules. An `Int` operand converts to `Float`, and the result is a `Float`. An infinite or NaN operand, or `0 × ∞`, gives the infinity or NaN IEEE 754 defines, and nothing traps. A null operand yields null, and the call is nullable where an operand is.

```ds expression head
import math
math.fma(r.level, 2.0, 1.0)
```

*(Spec: [LEXP.3.2.2])*

### `pow`

**`math.pow(x: Int, y: Int) → Int`**, **`math.pow(x: Float, y: Float) → Float`**

The function form of [`**`](../values/numbers.md#exponent), with its result types. With a non-negative integer exponent the result is an exact `Int`. With any other exponent it is the correctly rounded `Float` under [Transcendental functions](#transcendental-functions).

```ds expression head
import math
math.pow(r.n, 2)
```

*(Spec: [LEXP.3.2], [LEXP.3.9.1])*

## Binary min and max

**`min(a, b: Int | Float) → Int | Float`**, **`min(a, b: <unit>) → <unit>`**, **`max(a, b: Int | Float) → Int | Float`**, **`max(a, b: <unit>) → <unit>`**

The smaller or larger of two numeric operands, keeping the winning operand's kind: `max(5, 3.0)` is `5`, and `max(2, 3.5)` is `3.5`.

When the operands compare equal, the result is `a`, kind and sign included: `max(2, 2.0)` is `2`, and `min(0.0, -0.0)` is `0.0`. Two `Int` operands compare exactly. An `Int` beside a `Float` is promoted first.

One argument, a cursor, is the series aggregation.

```ds expression
max(min(r.n, 10), 0)
```

*(Spec: [LEXP.3.8.1], [LEXP.3.8.2], [LEXP.12.11])*

## Angle conversion

### `degrees`

**`math.degrees(x: Float) → Float`**

Radians to degrees: `x` times the binary64 nearest 180/π̂, rounded once, where π̂ is `math.pi`.

```ds expression head
import math
math.degrees(r.level)
```

*(Spec: [LEXP.3.6], [LEXP.3.6.1])*

### `radians`

**`math.radians(x: Float) → Float`**

Degrees to radians: `x` times the binary64 nearest π̂/180, rounded once.

An `Int` argument to either function converts to `Float` first. At a non-finite or NaN argument, the result is the IEEE 754 product's.

```ds expression head
import math
math.radians(r.level)
```

*(Spec: [LEXP.3.6], [LEXP.3.6.1])*

## Integer members

**`x.NAME`**, **`x.NAME(args)`**

Members of an `Int` value, reading `x` as its 64-bit two's-complement pattern, with bit 0 the least significant.

| Member | Result | Domain |
|---|---|---|
| `x.bit_count` | the number of 1 bits; `-1` has 64 | every `x` |
| `x.bit_length` | the number of bits the magnitude of `x` needs; 0 for 0 | every `x` |
| `x.leading_zeros` | the number of 0 bits above the highest 1 bit; 64 for 0, 0 for a negative `x` | every `x` |
| `x.trailing_zeros` | the number of 0 bits below the lowest 1 bit; 64 for 0 | every `x` |
| `x.bits(lo, w)` | the `w` bits from bit `lo` upward | `0 ≤ lo`, `1 ≤ w`, `lo + w ≤ 64` |
| `x.sign_extend(w)` | the low `w` bits, read as a two's-complement number | `1 ≤ w ≤ 64` |
| `x.swap_bytes(w)` | the low `w / 8` bytes, in reverse order | `w` is 16, 32 or 64 |

Every argument is an `Int`. A null receiver or argument yields null. `bits` and `swap_bytes` are non-negative unless `w` is 64.

An argument outside its domain raises a [`ComputationError`](../errors/fault-facts.md#computationerror-fact) of kind `DOMAIN` and abandons the activation. Compile-time constant arguments that place a call outside the domain whatever its other arguments hold are refused with `DS_VALIDATE_BIT_FIELD_RANGE`: `x.swap_bytes(24)` is refused, and `x.bits(lo, 8)` with a run-time `lo` is not.

On any other receiver type these names are refused with `DS_VALIDATE_UNKNOWN_MEMBER`. A `Json` leaf is cast to `Int` first.

```ds expression error=DS_VALIDATE_BIT_FIELD_RANGE
r.n.swap_bytes(24)
```

*(Spec: [LEXP.3.7.1], [LEXP.3.7.2], [LEXP.3.7.3], [LEXP.3.7.4])*

## Transcendental functions

Each takes `Float` arguments, an `Int` argument converting to `Float`, and returns a `Float`. An `angle` argument is its value in radians.

The result is the exact mathematical value rounded once to the nearest binary64, ties to even: an overflowing value rounds to an infinity, and an underflowing one to a subnormal or a zero.

The operands with no real value, or whose value is a limit, are at [LEXP.3.9.3](inv:specs:std:label#lexp-3-9-3). A NaN operand gives NaN, except in that table's `pow` rows. A NaN result flows on through the expression.

| Function | Meaning |
|---|---|
| `math.exp(x)` | `e` to the power `x` |
| `math.ln(x)` | the natural logarithm |
| `math.log2(x)` | the base-2 logarithm |
| `math.log10(x)` | the base-10 logarithm |
| `math.sin(x)`, `math.cos(x)`, `math.tan(x)` | the trigonometric functions of `x` radians |
| `math.asin(x)`, `math.acos(x)`, `math.atan(x)` | the inverse trigonometric functions, in radians |
| `math.atan2(y, x)` | the angle of the point (`x`, `y`) from the positive `x` axis, in radians, in [−π, π] |
| `math.sinh(x)`, `math.cosh(x)`, `math.tanh(x)` | the hyperbolic functions |

*(Spec: [LEXP.3.9.1], [LEXP.3.9.2], [LEXP.3.9.3], [LEXP.3.9.4])*

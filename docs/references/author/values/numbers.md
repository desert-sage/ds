<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Numbers

## Types

### Int

`Int` is a 64-bit signed integer.

Overflow wraps silently, two's complement.

*(Spec: [LEXP.7.13.1])*

### Float

`Float` is IEEE 754 binary64, rounding to nearest, ties to even, with subnormals kept.

An `Int` operand promotes to `Float` under an operator. A division by zero with a `Float` operand follows [Division by zero](#division-by-zero).

*(Spec: [LDET.3.6.1], [LEXP.7.3])*

### Bool

`Bool` is the type of `true` and `false`.

The arithmetic operators take `Int` or `Float`, so a `Bool` is no operand of theirs. [Numeric and Bool](conversions.md#refused-conversions) convert by no cast. `and`, `or` and `not` are [Kleene](null.md#kleene-logic).

*(Spec: [LEXP.7.1a])*

### Committed slot types

A `String`, `Int`, `Float` or `Bool` slot's type is committed at schema time.

A `Float` slot in a string comparison is refused with `DS_VALIDATE_TYPE_MISMATCH`, not a runtime fallback.

*(Spec: [LEXP.7.12.5])*

## Operator result types

### Promotion

All operands `Int` give `Int`. Any `Float` operand gives `Float`, and each `Int` operand promotes.

```ds expression
r.n + 1
r.level + r.n
```

*(Spec: [LEXP.7.1], [LEXP.7.2], [LEXP.7.3])*

### Promotion at a slot

`Int` to `Float` promotion applies where an operator combines operands and not where a value is assigned to a declared slot.

An `emit` or `publish` kwarg of type `Int` into a `Float` slot is refused with `DS_VALIDATE_TYPE_MISMATCH`. Write the [cast](conversions.md#the-cast).

*(Spec: [LEXP.7.3b], Source: compiler/mercury/src/dsc.validate.m)*

### Arithmetic operands

`+`, `-`, `*`, `/`, `//` and `%` take `Int` or `Float`.

A `String` operand is refused with `DS_VALIDATE_BAD_OPERAND_TYPE`.

```ds expression error=DS_VALIDATE_BAD_OPERAND_TYPE
r.label + r.label
```

*(Spec: [LEXP.7.1a], [LEXP.8.8])*

### Exponent

**`a ** b`**

`**` raises `a` to the power `b`.

- `Int ** Int` with a compile-time-known non-negative exponent, a literal or a `const` that folds to at least 0, is `Int`, by binary exponentiation under `Int` wrap.
- `Int ** Int` with a negative exponent, or one whose sign is not known at compile time, is `Float`, by correctly rounded `pow`. `2 ** -3 == 0.125`. `0` to a negative power is `+Inf`, and `±Inf` for an odd exponent.
- A non-integer exponent or a `Float` operand gives `Float`, by the same `pow`.

`**` is right-associative and each power is typed on its own: `a ** b ** 2` with a runtime `b` is `Float`.

*(Spec: [LEXP.7.3a], [LEXP.7.3a.1])*

### True division

**`a / b`**

`/` divides, and its result is `Float`, on two `Int` values included.

`INT_LIT / INT_LIT` is a [`Rational` literal](../units/checking.md#rational-literal), not the `/` operator. Any non-literal operand makes it the operator.

*(Spec: [LEXP.7.4])*

### Floor division

**`a // b`**

`//` divides and rounds toward negative infinity; its result type follows [Promotion](#promotion).

`7 // 2 == 3`, `-7 // 2 == -4`, `-7.5 // 2 == -4.0`.

With a `Float` operand and a nonzero divisor, `r` being step 1's exact remainder under [Modulo](#modulo):

1. `q = (a - r) / b`, the subtraction and the division each rounded once.
2. If Modulo's step 2 adjusted `r`, `q` becomes `q - 1`, rounded once.
3. If `q` is 0, the result is a zero with the sign of `a / b`.
4. Otherwise, with `f` the floor of `q`, the result is `f + 1` if `q - f` exceeds 0.5, else `f`. A NaN `q` gives NaN.

*(Spec: [LEXP.7.5])*

### Modulo

**`a % b`**

`%` is the remainder; `Int % Int` is `Int`, and any `Float` operand gives `Float`.

A nonzero result takes the divisor's sign: `5.5 % 2 == 1.5`, `-7 % 3 == 2`, `-7.5 % 2 == 0.5`.

With a `Float` operand and a nonzero divisor:

1. `r = a - b * trunc(a / b)`, computed exactly, with `a`'s sign. It is NaN when `a` is infinite or either operand is NaN, and `a` when `b` is infinite and `a` finite.
2. If `r` is nonzero and its sign differs from `b`'s, `r` becomes `r + b`, rounded once.
3. If `r` is 0, the result is a zero with `b`'s sign; otherwise it is `r`.

*(Spec: [LEXP.7.6])*

### Division by zero

A `/`, `//` or `%` whose operands are all `Int` is a runtime error when the divisor is zero, `/` included.

With a `Float` operand the operation is IEEE 754's: `/` and `//` give `±Inf` for a nonzero dividend and NaN for a zero one, and `%` gives NaN.

A `false` guard decides an `and` on either side of it: `x != 0 and y / x > 1` and `y / x > 1 and x != 0` are both `false` when `x` is `0`.

*(Spec: [LEXP.7.15.1], [LEXP.7.15.2], [LEXP.7.16.1])*

### Unary minus

**`-a`**

Unary `-` is arithmetic negation of an `Int` or a `Float`.

A unit-typed `Int` or `Float` is an `Int` or a `Float` here. An operand of any other kind, a [`Duration`](../time/types.md#duration) among them, is refused with `DS_VALIDATE_BAD_OPERAND_TYPE`.

*(Spec: [LEXP.7.10])*

### Unary plus

**`+a`**

Unary `+` on a numeric operand is a no-op.

*(Spec: [LEXP.7.11])*

### Bitwise operators

**`a & b`**, **`a | b`**, **`a ^ b`**, **`~a`**, **`a << n`**, **`a >> n`**

The bitwise operators take integer operands.

A `Float` operand whose type is known statically is refused with `DS_VALIDATE_BITWISE_TYPE`.

```ds expression error=DS_VALIDATE_BITWISE_TYPE
r.level & 1
```

*(Spec: [LEXP.7.7], [LEXP.7.9], Source: compiler/mercury/src/dsc.typecheck.m)*

### Shifts

**`a << n`**, **`a >> n`**

`>>` is an arithmetic shift, the floor of `a / 2^n`; `<<` is `a * 2^n` under `Int` wrap.

The count is not reduced modulo 64. A count of 64 or more gives `0` or `-1` for `>>`, by the sign of `a`, and `0` for `<<`. A negative literal count is refused with `DS_VALIDATE_NEGATIVE_SHIFT`. A count negative at run time is a [`ComputationError`](../errors/fault-facts.md#computationerror-fact) of kind `DOMAIN`.

```ds expression error=DS_VALIDATE_NEGATIVE_SHIFT
r.n << -1
```

*(Spec: [LEXP.7.8], [LEXP.7.14.1], Source: compiler/mercury/src/dsc.typecheck.m)*


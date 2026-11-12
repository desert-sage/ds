<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Operators

## Precedence

The levels are [LGRA.9.2.1](inv:specs:std:label#lgra-9-2-1). Parentheses override precedence at any level. Operand and result types are at [Operator result types](../values/numbers.md#operator-result-types).

*(Spec: [LEXP.1.1], [LEXP.1.4], [LEXP.12.2])*

### Comparison and bitwise levels

Comparisons bind looser than every bitwise operator and tighter than `not`: `a & 0x4 != 0` is `(a & 0x4) != 0`, and `not a < b` is `not (a < b)`.

*(Spec: [LEXP.1.2])*

### Exponent level

`**` binds tighter than a unary operator on its left, accepts any expression on its right, and is right-associative: `-2 ** 3` is `-(2 ** 3)`, `2 ** -3` is `0.125`, and `2 ** 3 ** 2` is `2 ** 9`.

*(Spec: [LEXP.1.3])*

### Postfix level

Member access `.`, index `[ ]`, call `( )` and the cast `::` bind tighter than every prefix and infix operator.

*(Spec: [LEXP.1.5])*

## Comparison chains

**`a <op1> b <op2> c …`**

An expression with any number of comparison operators, which is the conjunction of the pairwise comparisons on consecutive terms.

A chain of N comparisons produces N−1 tests. Any comparison operator stands at any position: `a < b > c` is `(a < b) and (b > c)`. `a < b < c` states nothing about `a` and `c`. Chain length has no limit.

```ds expression
0 <= r.n < 10
```

*(Spec: [LEXP.2.1], [LEXP.2.2.1], [LEXP.2.2.2], [LEXP.2.2.3], [LEXP.2.3.1], [LEXP.2.4.1])*

## Members

**`receiver.NAME`**, **`receiver.NAME(args)`**

A `.NAME` call on a receiver whose type is known statically is a member read, resolved by the receiver's type. A name the type does not carry is refused with `DS_VALIDATE_UNKNOWN_MEMBER`.

The `Int` members are at [Integer members](math.md#integer-members).

*(Spec: [LEXP.7.18], [LGRA.9.6.2])*

## Expression positions

One grammar, precedence and set of type rules hold across all positions.

*(Spec: [LEXP.12.1])*

### Where an expression is legal

- a `where` clause on a pattern;
- a value argument of `call`, `emit`, `publish` or `cache`, a slot value of `emit` or `publish` among them.

*(Spec: [LEXP.8.1], [LEXP.8.2], [LEXP.8.3], [LEXP.8.4], [LEXP.8.9.2])*

### Where an expression is refused

- a pattern's slot value;
- a schema declaration, a series declaration or configuration, which take compile-time literals.

Each is a compile error, and arithmetic in a pattern's slot value or a schema declaration is a parse error. A duration position takes a [`time_expr`](../lang/lexical.md#time_expr), not an expression.

*(Spec: [LEXP.8.5], [LEXP.8.6], [LEXP.8.7], [LEXP.8.9.2], [LEXP.10.2.5])*

### `const` right-hand side

A compile-time-constant expression over literals, earlier constants and imported constants:

- arithmetic, comparison, bitwise and shift operators, `and`, `or` and `not`;
- unit literals, same-dimension conversion and unit assertions;
- the total `::` conversions;
- the global math builtins, and `math`, `distance` and `calendar` members over constant operands.

A `String` folds only as a literal. The compiler folds the right-hand side operation by operation, each to the value the engine computes for that operation in a rule: an `Int` result wraps, and each `Float` result is rounded before the next operation takes it. An `Int` under a `: Float` annotation is held, and read, as the `Float` it promotes to. The right-hand side is type-checked whole, as an expression in a rule is: `const x = 5_meter + 1` is refused by the [unit rules](../units/checking.md#bare-numbers).

`DS_VALIDATE_CONST_NOT_FOLDABLE` refuses:
- a construct that needs a runtime value, naming it;
- an operation with no value, whether or not the rest of the expression would absorb it: one the engine would raise a fault evaluating, such as `1 // (1 - 1)`, a `Float` to `Int` conversion of a value with no `Int`, or a `calendar` call that raises, and one whose `Float` result is NaN;
- `null` or a fallible `::T?` conversion, under any annotation.

An operation another refusal covers over constant operands keeps that refusal's code: `1 // 0` is `DS_VALIDATE_DIV_BY_ZERO` and `1 << -1` a [negative shift](../values/numbers.md#shifts), in a `const` as in a rule. The declaration's form is at [Constant declarations](../lang/program.md#constant-declarations).

```ds declaration error=DS_VALIDATE_CONST_NOT_FOLDABLE
const LIMIT = 1 // (1 - 1)
```

*(Spec: [LEXP.8.8], [LEXP.8.8.1], [LEXP.8.8.2], [LGRA.4.1])*

### `log` argument

The `log` action head takes one string, literal or interpolated. `log info (2 + 2)` is a parse error.

*(Spec: [LEXP.8.9.1])*

## Interactions

Re-evaluation of a `where` under a `logical` emit is at [Time-dependent tests](../facts/logical.md#time-dependent-tests), and `dwell` at [`dwell`](../facts/logical.md#dwell).

### Series aggregations

A [series aggregation](../series/aggregations.md#aggregation-catalogue) is a function-call atom that composes freely in an expression. Its value is recomputed at each test.

*(Spec: [LEXP.9.2.1], [LEXP.9.2.2])*

### `where` on a join

A `where` on a rule with more than one positive pattern does not read state that is not a function of the matched facts. The scope is the rule: a `where` attached to one pattern is refused as one naming bindings from two is.

| Read | Code |
|---|---|
| a clock read ([`now()`](../time/types.md#now), `monotonic_ns()`, `dwell`), a series read or a zone read | `DS_VALIDATE_NOW_MULTIPATTERN_UNSUPPORTED` |
| [`cached(key)`](../actions/cache.md#cached) | `DS_VALIDATE_NONFACT_WHERE_MULTIPATTERN` |

A rule with one positive pattern is unaffected, and so is a `let`.

```ds rule error=DS_VALIDATE_NOW_MULTIPATTERN_UNSUPPORTED
rule stale:
    Reading a
    Reading b where now() > a.ts and b.id == a.id
->
    log info "stale"
```

*(Spec: [LEXP.9.6.1], [LTIM.2.6.2])*

## Errors

### Compile errors

| Condition | Code |
|---|---|
| `/`, `//` or `%` of `Int` operands by literal zero | `DS_VALIDATE_DIV_BY_ZERO` |
| a builtin called with a count its arities do not hold | `DS_VALIDATE_BAD_ARITY` |

A malformed expression (an unclosed parenthesis, a missing operand, a dangling operator) is a parse error. A `Float` division by a zero literal is not an error.

```ds expression error=DS_VALIDATE_DIV_BY_ZERO
r.n / 0
```

The other refusals and faults are at [Division by zero](../values/numbers.md#division-by-zero), [Shifts](../values/numbers.md#shifts), [Bitwise operators](../values/numbers.md#bitwise-operators) and [`len` of `Json`](../values/json.md#len-of-json). Over a dimensioned value, those of every operator are at [Cross dimension](../units/checking.md#cross-dimension), and of `??`, `..` and `in` at [Forms over two values](../units/checking.md#forms-over-two-values).

*(Spec: [LEXP.10.2.2], [LEXP.10.2.4], [LEXP.10.2.6], [LEXP.3.1])*

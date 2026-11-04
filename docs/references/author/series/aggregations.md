<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Aggregations

## Catalogue

### Aggregation catalogue

The aggregations, one row each. A cursor is a [series cursor](reading.md#series-cursor), and `T` the type of the slot it reads. The [builtins](../expr/builtins.md#the-registry) page's columns apply.

```{include} ../_generated/aggregations.md
```

*(Spec: [LEXP.17.2], [LSER.16])*

### Applicability

An aggregation whose type does not match the slot's is refused with `DS_VALIDATE_SERIES_AGG_TYPE_MISMATCH`.

| Aggregation | Slot value types | Returns |
|---|---|---|
| `min`, `max` | `Float`, `Int` | the slot's type, nullable |
| `sum` | `Float`, `Int` | the slot's type |
| `mean`, `median`, `variance`, `stdev`, `pvariance`, `pstdev`, `pXX` | `Float`, `Int` | `Float?` |
| `count` | any type | `Int` |
| `count_distinct`, `count_of` | any type with defined equality | `Int` |
| `contains` | any type with defined equality | `Bool` |
| `bool_and`, `bool_or` | `Bool` | `Bool?` |
| `first`, `last` | any type | the slot's type, nullable |
| `rate` | `Float`, `Int` | `Float?` |
| `direction` | `Float`, `Int` | `Int?` |

`Returns` is the static type of both call forms. `String` and `Bytes` slots admit `count`, `count_distinct`, `count_of`, `contains`, `first` and `last`. A `Json` slot admits `count`, `first` and `last`. Type and time model are two axes, both to be met, and the compiler reports the first that fails. [Signal aggregations](signal.md#signal-applicability) have their own table.

```ds declaration error=DS_VALIDATE_SERIES_AGG_TYPE_MISMATCH
series Reading.label:
    mean sliding 10_min
```

*(Spec: [LSER.17.1], [LSER.17.2], [LSER.17.3], [LSER.17.4], [LSER.17.5], [LSER.17.7], Source: compiler/mercury/src/dsc.series.m)*

### Name refusals

| Condition | Code |
|---|---|
| a name that is no aggregation | `DS_VALIDATE_SERIES_AGG_NOT_SUPPORTED` |
| `pXX` with `XX` outside `1..99` | `DS_VALIDATE_SERIES_INVALID_QUANTILE` |

```ds declaration error=DS_VALIDATE_SERIES_INVALID_QUANTILE
series Reading.level:
    p100 sliding 10_min
```

*(Spec: [LSER.16.4.1], [LSER.17.6], [LSER.18.1])*

## Vocabulary

### Descriptive statistics

| Aggregation | Answers |
|---|---|
| `mean` | the arithmetic mean |
| `median` | the 50th percentile, as `p50` |
| `min`, `max` | the minimum, the maximum |
| `sum` | the sum |
| `count` | the sample count |

`sum` over an `Int` slot accumulates in a 64-bit signed integer, and [wraps](../values/numbers.md#int) as `Int` does.

*(Spec: [LSER.16.2], [LSER.16.2.2], [LSER.16.4.2])*

### Dispersion

| Aggregation | Answers | At one sample |
|---|---|---|
| `stdev` | the sample standard deviation | `null` |
| `pstdev` | the population standard deviation | `+0` |
| `variance` | the sample variance | `null` |
| `pvariance` | the population variance | `+0` |

*(Spec: [LSER.16.3.1], [LSER.16.3.3])*

### Quantiles

**`pXX`**

`pXX` interpolates linearly between the two order statistics that bracket it, for an integer `XX` in `1..99`.

The window's `n` samples sort ascending as `Float`, an `Int` converting round-to-nearest-even and `-0` before `+0`, as `x_0 .. x_{n-1}`. With `num = (n-1) * XX`, `lo = num // 100` and `frac = num % 100`, the result is `x_lo` when `frac = 0`, when `x_lo = x_{lo+1}`, or when `x_lo` is `-inf` and `x_{lo+1}` is not `+inf`. Otherwise it is `x_lo + (frac / 100) * (x_{lo+1} - x_lo)`, evaluated as correctly rounded operations in the order subtraction, division, multiplication, addition. With `n = 1` it is `x_0`. A bracketing pair of `-inf` and `+inf` reads NaN.

*(Spec: [LSER.16.4.1], [LSER.17.2])*

### Cardinality and membership

| Aggregation | Answers |
|---|---|
| `count_distinct(cursor)` | the count of distinct values |
| `count_of(cursor, value)` | the count of `value` |
| `contains(cursor, value)` | whether `value` was observed |

```ds expression series
count_distinct(r)
count_of(r, 1.0)
contains(r, 1.0)
```

*(Spec: [LSER.16.5.1], [LSER.16.6.1], [LSER.16.7.1])*

### Boolean aggregations

| Aggregation | Answers |
|---|---|
| `bool_and` | whether every sample is true |
| `bool_or` | whether any sample is true |

*(Spec: [LSER.16.8], [LSER.16.8.1])*

### Temporal aggregations

| Aggregation | Answers | Also `null` when |
|---|---|---|
| `first` | the oldest sample's value | |
| `last` | the newest sample's value | |
| `rate` | `(last - first) / elapsed_seconds` | no time elapses between the first and last samples |
| `direction` | `-1` falling, `0` steady, `+1` rising | the window holds one sample |

`direction` is the sign of the two newest samples' difference, decided by comparing them, with no tolerance. `-0` and `+0` compare equal. `null` while cold is [Cold read](reading.md#cold-read).

```ds expression series
r.first
r.last
r.rate
r.direction
```

*(Spec: [LSER.10.9], [LSER.16.9], [LSER.16.9.1])*

### Computation order

`sum`, `mean` and the dispersion statistics are computed in one order per time model, each step one correctly rounded binary64 operation.

Samples `x_1 .. x_n` are `Float`, an `Int` converting round-to-nearest-even; an `Int` slot's `sum` is the integer sum.

| Time model | Sample order | State |
|---|---|---|
| `all_time` | arrival | `mu_1 = x_1`, `M_1 = +0` |
| `sliding` | live samples, oldest first | two passes |
| `sample` | slots `0` to `n-1` | `mu_0 = +0`, `M_0 = +0` |

- **`sum`:** `S_0 = +0`, `S_k = S_{k-1} + x_k`.
- **`all_time`, `sample`:** `d = x_k - mu_{k-1}`, `mu_k = mu_{k-1} + d / k`, `M_k = M_{k-1} + d * (x_k - mu_k)`. `mean` is `mu_n`, and `M` is `M_n`.
- **`sliding`:** `mean` is `mu = S_n / n`. `Q_0 = +0`, `d = x_k - mu`, `Q_k = Q_{k-1} + d * d`, and `M` is `Q_n`.
- **Every time model:** `variance` is `M / (n - 1)`, `pvariance` is `M / n`, `stdev` and `pstdev` their square roots. On `all_time` and `sliding`, a variance not greater than `0` gives a deviation of `+0`.

*(Spec: [LSER.16.3.3])*

## Result units

### Unit-preserving aggregations

`min`, `max`, `mean`, `median`, `pXX`, `stdev`, `pstdev`, `sum`, `first` and `last` return the series slot's unit, with no annotation.

`count` returns a dimensionless `Int`. [Unit-typed slots](../units/checking.md#unit-typed-slots) states what such a slot holds.

*(Spec: [LUNI.9.1], [LUNI.9.3])*

### `integral` result unit

A `let` reading `integral` over a slot with a unit carries a type annotation naming a unit; one without is refused with `DS_VALIDATE_DIM_AGG_UNANNOTATED`.

Any unit symbol answers it. A read in a `where`, an `emit` slot or an interpolation needs none, and neither does a `let` over a slot with no unit or over `onset_rate`. `integral`'s `Float` return is its representation, and the annotation states its dimension.

*(Spec: [LUNI.9.2], [LSIG.1.1])*

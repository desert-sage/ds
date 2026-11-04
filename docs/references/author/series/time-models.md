<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Time models

## Phrases

### Time model phrases

A line's time model declares the part of a slot's history its aggregations apply to.

| Phrase | Window |
|---|---|
| `all_time` | from the first observation onward |
| `sliding <dur>` | at read time `t`, the half-open interval `(t - <dur>, t]`; a sample exactly `<dur>` old is outside it |
| `sample <n>` | a uniform random sample of size `n` from the unbounded stream |

`<dur>` is a [duration literal](../units/literals.md). A zero or negative window or sample count is refused with `DS_VALIDATE_SERIES_NONPOSITIVE_WINDOW`.

*(Spec: [LSER.14.1], [LGRA.13.5])*

### `tumbling`

**`tumbling <dur>`**

Every `tumbling` line is refused with `DS_VALIDATE_SERIES_NO_EXACT_BACKING`.

```ds declaration error=DS_VALIDATE_SERIES_NO_EXACT_BACKING
series Reading.level:
    mean tumbling 10_min
```

*(Spec: [LSER.14.4.5], [LSER.15.2])*

## `sample <n>`

### Reservoir

**`sample <n>`**

`sample <n>` keeps `n` samples per `by:` identity, chosen uniformly from all it absorbs, over the slot's lifetime.

It has no time axis and no insertion order, and its state is fixed at `n` whatever the arrival rate. `sample` is a time-model keyword, not an aggregation name.

```ds declaration
series Reading.level:
    mean, p95 sample 200
```

*(Spec: [LSER.14.5.1], [LSMP.1.1], [LSMP.1.2], [LSMP.1.3])*

### Reservoir determinism

The bag is the same on every run and every conforming platform for one event trace.

Each identity has up to `n` slots numbered from 0, and a 64-bit state `s` starting at `0x9e3779b97f4a7c15`. The `i`-th sample, `i` counted from 1 in event-trace order:

- with `i <= n`, fills slot `i - 1`, and `s` does not change;
- with `i > n`, sets `s` to `xs(s)` and `j` to `s mod i`, and replaces slot `j` if `j < n`, otherwise it is discarded.

`xs` is xorshift64 over unsigned 64-bit integers: `x ^= x << 13`, `x ^= x >> 7`, `x ^= x << 17`, each shift discarding the bits it moves out.

Aggregations read the bag's slots in order 0 to `n - 1`, read-only, in [the order](aggregations.md#computation-order) given for `sample`.

*(Spec: [LSMP.2.1], [LSMP.2.3])*

### Reservoir applicability

| Aggregation | Under `sample` |
|---|---|
| `mean`, `median`, `pXX`, `variance`, `pvariance`, `stdev`, `pstdev`, `sum`, `count` | admitted |
| `min`, `max` | admitted, as order statistics of the retained sample |
| `first`, `last`, `rate`, `direction`, `bool_and`, `bool_or`, `count_distinct`, `count_of`, `contains` | refused with `DS_VALIDATE_SERIES_AGG_TIME_MODEL_MISMATCH` |

```ds declaration error=DS_VALIDATE_SERIES_AGG_TIME_MODEL_MISMATCH
series Reading.level:
    first sample 200
```

*(Spec: [LSMP.3.1], [LSMP.3.2a], [LSER.16.6.2], [LSER.16.7.2], [LSER.16.8.3], [LSER.16.9.3], [LSER.16.9.4])*

## Accuracy

### Exactness

Every aggregation is exact: a combination of aggregation and time model with no exact form is refused with `DS_VALIDATE_SERIES_NO_EXACT_BACKING`.

`median` and `pXX` need a `sliding` window or `sample <n>`; `count_distinct`, `count_of` and `contains` need a `sliding` window. Their `all_time` forms are refused. The whole matrix is at [LSER.18.1](inv:specs:std:label#lser-18-1).

```ds declaration error=DS_VALIDATE_SERIES_NO_EXACT_BACKING
series Reading.level:
    p95 all_time
```

*(Spec: [LSER.10.19], [LSER.15.1], [LSER.15.2], [LSER.16.2.1], [LSER.16.5.2], [LSER.16.6.1], [LSER.16.7.1])*

### Accuracy phrases

`exact`, `tolerance`, `confidence`, `delta` and `bound deterministic` parse, and are refused with `DS_VALIDATE_SERIES_NO_EXACT_BACKING`.

```ds declaration error=DS_VALIDATE_SERIES_NO_EXACT_BACKING
series Reading.level:
    mean sliding 10_min exact
```

*(Spec: [LGRA.7.1], [LSER.15.1], Source: compiler/mercury/src/dsc.series.m)*

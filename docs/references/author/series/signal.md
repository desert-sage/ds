<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Signal aggregations

## The aggregations

### Signal applicability

| Aggregation | Element type | Time model | Returns |
|---|---|---|---|
| `active_fraction` | `Bool` | `sliding` | `Float` |
| `onset_rate` | `Bool` | `sliding` | `Float` |
| `integral` | `Float`, `Int` | `sliding`, `all_time` | `Float` |

A wrong element type is refused with `DS_VALIDATE_SERIES_AGG_TYPE_MISMATCH`, and a wrong time model with `DS_VALIDATE_SERIES_AGG_TIME_MODEL_MISMATCH`; the compiler reports the first failing axis. `integral`'s `tumbling` form is [refused](time-models.md#tumbling). What each does at `capacity` is [`capacity:`](declarations.md#capacity).

```ds declaration error=DS_VALIDATE_SERIES_AGG_TIME_MODEL_MISMATCH
series Reading.ok:
    active_fraction all_time
```

*(Spec: [LSIG.1.1], [LSIG.1.2], [LSIG.1.3.3], [LSIG.1.4.3], [LSIG.1.5.4])*

### `active_fraction`

**`active_fraction(cursor)`**

`active_fraction` is the time-weighted fraction of the sliding window during which the slot held `true`.

`active_fraction = (1/W) ∫ b(τ) dτ` over `[t-W, t]`, where `b(τ)` is `1` or `0`, each asserted value holding until the next assertion. It is a fraction of time, not of assertions.

```ds declaration
series Reading.ok:
    active_fraction, onset_rate sliding 10_min
```

*(Spec: [LSIG.1.3.1], [LSIG.1.3.2])*

### `onset_rate`

**`onset_rate(cursor)`**

`onset_rate` is the number of false-to-true transitions per second within the sliding window.

`onset_rate = N / min(W, elapsed)`, where `N` counts rising edges in `(t-W, t]` and `elapsed` is the time since the series instance absorbed its first sample. At the first edge `elapsed` is `0`, and the read is `0` until `elapsed` is greater than `0`. `elapsed` restarts when the backing is [evicted](reading.md#eviction).

*(Spec: [LSER.19.7], [LSIG.1.4.1], [LSIG.1.4.2])*

### `integral`

**`integral(cursor)`**

`integral` is the time-weighted integral of a slot, by the rectangle rule over the slot's step function.

`integral = Σ x_i (t_{i+1} - t_i)`, the newest sample held to the query time. A slot in units `U` gives `U·s`, and [Result units](aggregations.md#integral-result-unit) states the annotation it takes. The rectangle rule is exact over the facts. Against a continuously varying signal, its absolute error is at most the slot's `tolerance` or quantisation step times `W`. `integral` over `all_time` accumulates in a `Float` from `0.0` at the first assertion.

```ds declaration
series Reading.level:
    integral sliding 1_h gap zero
```

*(Spec: [LSIG.1.5.1], [LSIG.1.5.2], [LSIG.1.5.3], [LSIG.1.5.5])*

## Gaps

### Gap policy

**`gap hold`**, **`gap zero`**, **`gap skip`**

A gap policy states how `integral` advances across an interval with no new sample; omitted, it is `gap hold`.

| Policy | Across a gap |
|---|---|
| `gap hold` | carries the last asserted value |
| `gap zero` | treats the absence of a report as zero |
| `gap skip` | excludes the interval from the integral |

| Condition | Code |
|---|---|
| a gap policy on any other aggregation | `DS_VALIDATE_SERIES_GAP_ON_NON_INTEGRAL` |
| `gap skip` on a `scope logical` schema | `DS_VALIDATE_SERIES_GAP_SKIP_LOGICAL` |

```ds declaration error=DS_VALIDATE_SERIES_GAP_ON_NON_INTEGRAL
series Reading.level:
    mean sliding 1_h gap zero
```

*(Spec: [LSER.13.5.1], [LSIG.3.1], [LSIG.3.2], [LSIG.3.3], [LSIG.3.4])*

## Reliability

### Reliability contract

Each aggregation is exact over the observed event stream; its fidelity to the physical process rests on these assumptions.

| Aggregation | Exact with respect to | Assumption | If it breaks |
|---|---|---|---|
| `active_fraction` | the observed transitions | every transition is observed, and `true` is asserted at connection | a lost falling edge biases it high and does not correct itself; an already-on signal under-reports for up to `W` |
| `onset_rate` | the observed rising edges | edges are genuine onsets | chatter inflates it; `min(W, elapsed)` restarts after each idle gap |
| `integral` | the step function over the facts | every value change is observed, and the `gap` policy fits | `gap hold` over a dead source accrues without bound |

*(Spec: [LSIG.6.1])*

### Monotone timestamps

A series does not reorder: an assertion whose timestamp precedes the most recent one the series recorded is discarded.

With no `true` asserted for a signal already on, `active_fraction` reads `0` until the first observed rising edge.

*(Spec: [LSIG.6.2])*

### Replay

Each signal aggregation is bit-reproducible on any IEEE-754 platform, in a fixed fact order.

*(Spec: [LSIG.4.1], [LSIG.4.2])*

## Truth maintenance

### Signal thresholds

A `logical` fact emitted on a signal threshold retracts when the value falls back, with no retraction rule.

A crossing driven by a new assertion shows on that assertion's evaluation. A crossing driven by time alone shows at the next [re-evaluation](reading.md#time-dependent-reads). With no pump the derived fact does not change, so the retraction latency of a fact whose source can fall quiet is bounded by the host's pump interval. `active_fraction` below a small threshold lags by up to `W`, and `onset_rate` reads `0` on a signal stuck `true`.

*(Spec: [LSIG.1.4.4], [LSIG.7.1], [LSIG.7.2], [LSIG.7.3])*

## Cold start

### Before the first data

A signal aggregation reads `0.0` before its first data, and never `null`.

| Aggregation | First valid result |
|---|---|
| `active_fraction` | the first `true` assertion; biased low for up to `W` if already `true` |
| `onset_rate` | unbiased once the instance's age reaches `W` |
| `integral` | the first assertion |

*(Spec: [LSIG.8.1])*

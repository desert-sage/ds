<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# SERIES_SIGNAL conformance vectors (v1 signal aggregations)

**Status: LIVE.** The value vectors below are the `logical/` fixtures
`LSIG.1.3.1_golden_af_{1,2,3}`, `LSIG.1.5.1_golden_in_1`,
`LSIG.2.3.3_golden_in_2`, `LSIG.3.4_golden_in_3` and
`LSIG.1.4.1_golden_or_{1,2}`. Each asserts its stream at the stated instants;
at `q` a `Probe` fact arrives and a rule logs the aggregation's companion
(LSIG.2.5), and `log_message_sequence` compares the text, which is the value's
canonical Float text ([LDET.3.2.7]), so the comparison is exact (LSIG.4.4). No
public function reads a series: a series' value
reaches an integrator only through what a rule does with it ([NSBK.6.3]), so
that is how the vectors read it. The `runtime/LSIG.{AF,IN,OR}-*` fixtures are
deprecated. This document is the human-readable derivation.

These are the bit-exact
determinism golden vectors for the v1 signal-processing aggregations of
[LSIG.1] (`active_fraction`, `onset_rate`, `integral`). The expected values below are
computed by hand from the normative LSIG query algorithms and are the
acceptance criterion any conforming runtime must reproduce — on every
IEEE-754 platform and in every mode ([LSIG.4]).

Every value is exact in IEEE-754 `Float64`, and its canonical text names it
exactly, so comparing the logged text is exact equality (no tolerance) per
[LSIG.4.4].

---

## Value vectors

Each vector: a series declaration, a timestamped input stream (monotone
non-decreasing per [LSIG.6.2]), a read time `q`, and the exact expected
value with the clause it pins. Times shown in seconds; the runtime works in
int64 nanoseconds.

### `active_fraction` (SeriesBackendIntervalPulse) — [LSIG.1.3], [LSIG.2.2]

```
series sensor.pump.state:
    active_fraction sliding 300_s
```

| Vector | Stream (slot `state: Bool`) | q | Window (q−W, q] | On-time in window | Expected | Pins |
|---|---|---|---|---|---|---|
| AF-1 | `true@0_s`, `false@240_s` | 300_s | (0, 300] | 240_s | `0.8` | core insight `active_fraction ≠ mean` ([LSIG.1.3.2]) |
| AF-2 | `true@0_s` (no falling edge) | 60_s | (0, 60] | 60_s (open interval clipped to `t`) | `1.0` | stuck-true / open-interval clip ([LSIG.2.2.3], [LSIG.6]) |
| AF-3 | `true@0_s`, `false@30_s` | 60_s | (0, 60] | 30_s | `0.5` | basic time-weighted fraction |

Derivation (AF-1): the falling edge closes the interval `(0, 240]`,
`total_on_ns = 240e9`; at `q=300_s`, `t−W = 0`, the interval's out-of-window
portion is `[0,0]` (measure 0), so `active_fraction = 240e9 / 300e9 = 0.8`.
The `(t−W, t]` left-exclusive boundary ([LSIG.2.2.4]) makes the start at
`t−W` contribute zero, not a spurious sample.

### `integral` (SeriesBackendNumericIntegral, rectangle rule, `gap hold`) — [LSIG.1.5], [LSIG.2.3]

```
series flow.main.rate:
    integral sliding 10_s gap hold
```

| Vector | Stream (slot `rate: Float`, L/s) | q | Expected (L·s) | Pins |
|---|---|---|---|---|
| IN-1 | `2.0@0_s`, `5.0@4_s` | 10_s | `38.0` | rectangle / zero-order hold, open right edge held to `q` ([LSIG.1.5.1]) |
| IN-2 | `10.0@0_s`, `4.0@15_s` | 20_s | `70.0` | partial-interval clip at the sliding boundary ([LSIG.2.3.3]) |
| IN-3 | `2.0@0_s`, `5.0@4_s`, `gap zero` | 10_s | `8.0` | the open interval since the last sample is the gap, and `gap zero` contributes nothing for it |

Derivation (IN-1): held value `2.0` over `[0,4)` → `8.0`; `5.0` over `[4,10]`
→ `30.0`; total `38.0`. Derivation (IN-2), window `(10, 20]`: `10.0` held over
`(10,15]` → `50.0`; `4.0` over `(15,20]` → `20.0`; total `70.0`. The closed
`[0,15)` interval contributes `150.0` to `running_sum`, of which the
out-of-window `[0,10]` portion (`100.0`) is discounted at query:
`150 − 100 + 20 = 70.0`.

> The `K = 128` recompute path ([LSIG.2.3.4]) cannot be hand-tabulated
> compactly. It is exercised by a generated vector: assert `≥ 129` evictions
> of a slowly-varying rate, then read; the result must equal a from-scratch
> sum over the live ring (bit-identical). No fixture carries it yet.

### `onset_rate` (SeriesBackendRingBuffer, `min(W, elapsed)` denominator) — [LSIG.1.4], [LSIG.2.4]

```
series sensor.door.state:
    onset_rate sliding 20_s
```

| Vector | Stream (rising edges of `state: Bool`) | q | N₊ in (q−W, q] | elapsed = q − t_first | Expected (Hz) | Pins |
|---|---|---|---|---|---|---|
| OR-1 | `true@2_s` | 4_s | 1 | 2_s | `0.5` | warm-up denominator `min(W, elapsed)` ([LSIG.1.4.2]) |
| OR-2 | rising@`5,10,15,20,25_s` (toggling, falling between) | 26_s | 4 (edge@5 excluded, left-exclusive) | 21_s → capped at W=20_s | `0.2` | steady rate, `(t−W, t]` edge count |

Derivation (OR-1): one edge in the window, `t_first = 2_s`, `elapsed = 2_s`, so
`min(W, elapsed) = min(20, 2) = 2`; `onset_rate = 1 / 2 = 0.5`. The full-window
divisor would give `1/20 = 0.05` — the `min(W, elapsed)` warm-up denominator
is exactly what makes OR-1 `0.5`. Derivation (OR-2): edges at `10,15,20,25`
lie in `(6, 26]` (the edge at `5` is at/below `t−W = 6` and excluded), so
`N₊ = 4`; `elapsed = 26 − 5 = 21_s`, capped at `W = 20_s`; `onset_rate =
4 / 20 = 0.2`.

At the very first edge `elapsed = 0`; `onset_rate` is defined as `0` there,
not a divide-by-zero ([LSIG.1.4.2]).

---

## Compiler contract cases

These reach the LSIG compile-time contract and are `compiler`-category
`compile_ok` / `compile_error` fixtures; they need no runner kind.

| Case | rules_ds (sketch) | Expect | Pins |
|---|---|---|---|
| CC-1 | `integral sliding 1_h gap zero` | `compile_ok` | `gap-policy` grammar accepted ([LSER.13.5], [LGRA.7.1]) |
| CC-2 | `active_fraction sliding 5_min gap hold` | `compile_error` | `gap` on a non-integrating aggregation ([LSIG.3.3]) |
| CC-3 | `integral sliding 1_h gap skip` on a `scope logical` schema | `compile_error` code `DS_ERR_GAP_SKIP_LOGICAL` | [LSIG.3.4] |
| CC-4 | `integral all_time` in a `realtime` file | `compile_error` code `DS_ERR_REALTIME_UNBOUNDED_BACKING` | [LSIG.5.3] |
| CC-5 | `active_fraction sliding 5_min` on a `Float` slot | `compile_error` | element type — `Bool` only ([LSIG.1.2]) |
| CC-6 | `active_fraction tumbling 5_min` | `compile_error` | time model — `sliding` only ([LSIG.1.3.3]) |

CC-2/CC-5/CC-6 have no error code named in the spec (they reject via the
[LSER.15.2] closest-form hint shape); their JSON uses `message_contains`.

---

## Where the vectors live

- **Compiler cases (CC-*)** → `specs/conformance/compiler/LSIG.*.json`
  with `expect.kind` `compile_ok` / `compile_error`.
- **Value vectors (AF/IN/OR-*)** → `specs/conformance/logical/LSIG.*_golden_*.json`,
  `log_message_sequence`: the stream as `set` / `assert` / `pump` steps on the
  mock clock, then at `q` a `Probe` and a pump, and the one rule, joining
  `Probe` with the series' schema, logs the companion. `realtime` is deferred,
  so no vector pins the [LSIG.5.4] default-vs-bounded-memory divergence.

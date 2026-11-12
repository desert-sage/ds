# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Clause-literal references for the v1 series aggregations.

Every v1 series aggregation is exact, and a conforming runtime's read is
bit-identical across platforms ([LSER.15.1], [LDET.3.4]). This module is the
clauses' arithmetic written out: one function per aggregation, in IEEE-754
binary64 with the operation order the clause states, and one function per
window admission. Each is a reading of its clause's words and of nothing
else. No runtime is read here, and nothing here moves when a backing is
refactored. A property test beside this module holds a runtime's read to these
bit for bit; a disagreement is read against the clause before either side,
because the reference is a reading and the clause may be the thing that is
wrong.

Values are the slot's: `int` for `Int` and for a `Duration` in nanoseconds,
`float` for `Float`, `bool` for `Bool`, `str` for `String`. No NaN reaches a
slot ([LEXP.4.2]); an infinity may. Python's `float` is binary64 and its
`+ - * /` are the correctly rounded IEEE operations; `float(int)` converts
round-to-nearest-even; `int / int` below 2**53 is one correctly rounded
division; `math.sqrt` is IEEE `sqrt`, wrapped below so that a negative
argument answers NaN as IEEE does instead of raising.

A function that answers `None` answers `null`. Where a clause leaves an
operation order unstated, the function's docstring says which reading it
takes, and that reading is what changes when the clause is amended.

`test_series_reference.py` holds these to the clauses' own worked examples and
the two tables ([LSER.18.1], [LSER.17.2]) to the clause text.
"""
from __future__ import annotations

import math
from typing import NamedTuple, Optional, Sequence

_INT64_MIN = -(1 << 63)
_INT64_MAX = (1 << 63) - 1
_MASK64 = (1 << 64) - 1

# [LSER.14.1]'s time models a v1 cell is exact in; `tumbling` is refused in
# this edition ([LSER.14.4.5], [LSER.18.1] §). The name doubles as the backing
# whose operation order [LSER.16.3.3] gives: `all_time` the cumulative
# backing, `sliding` the raw-sample ring buffer, `sample` the reservoir.
TIME_MODELS = ("all_time", "sliding", "sample")


class Sample(NamedTuple):
    """One absorbed sample: the engine's clock at absorption, in nanoseconds,
    and the slot's value."""
    t: int
    v: object


class NotRepresentable(ArithmeticError):
    """[LERR.1.4.10]: a `ComputationError` of kind `NOT_REPRESENTABLE`."""


# ---------------------------------------------------------------------------
# The two matrices, as data a census reads.

# [LSER.18.1]: each aggregation and the time models its cell is exact in.
# `pXX` stands for every `p1` to `p99` ([LSER.16.4.1]).
EXACT_CELLS: dict[str, tuple[str, ...]] = {
    "mean": ("all_time", "sliding", "sample"),
    "sum": ("all_time", "sliding", "sample"),
    "count": ("all_time", "sliding", "sample"),
    "min": ("all_time", "sliding", "sample"),
    "max": ("all_time", "sliding", "sample"),
    "stdev": ("all_time", "sliding", "sample"),
    "pstdev": ("all_time", "sliding", "sample"),
    "variance": ("all_time", "sliding", "sample"),
    "pvariance": ("all_time", "sliding", "sample"),
    "rate": ("all_time", "sliding"),
    "direction": ("all_time", "sliding"),
    "first": ("all_time", "sliding"),
    "last": ("all_time", "sliding"),
    "bool_and": ("all_time", "sliding"),
    "bool_or": ("all_time", "sliding"),
    "median": ("sliding", "sample"),
    "pXX": ("sliding", "sample"),
    "count_distinct": ("sliding",),
    "count_of": ("sliding",),
    "contains": ("sliding",),
}

# [LSER.17.2]: the sampled types, and the slot value types each aggregation
# admits. The numeric three are `Float`, `Int` and `Duration`.
SAMPLED_TYPES = ("Float", "Int", "Bool", "String", "Time", "Date", "Duration")
_NUMERIC = ("Float", "Int", "Duration")
ADMITTED_TYPES: dict[str, tuple[str, ...]] = {
    "min": _NUMERIC, "max": _NUMERIC, "sum": _NUMERIC,
    "mean": _NUMERIC, "median": _NUMERIC, "variance": _NUMERIC,
    "stdev": _NUMERIC, "pvariance": _NUMERIC, "pstdev": _NUMERIC,
    "pXX": _NUMERIC,
    "count": SAMPLED_TYPES, "count_distinct": SAMPLED_TYPES,
    "count_of": SAMPLED_TYPES, "contains": SAMPLED_TYPES,
    "bool_and": ("Bool",), "bool_or": ("Bool",),
    "first": SAMPLED_TYPES, "last": SAMPLED_TYPES,
    "rate": _NUMERIC, "direction": _NUMERIC,
}


# ---------------------------------------------------------------------------
# Window admission: which absorbed samples a read is over, in the backing's
# order ([LSER.16.3.3]: arrival order, oldest to newest, for `all_time` and
# `sliding`; the bag's slots 0 to n-1 for `sample`).

def all_time(samples: Sequence[Sample]) -> list[Sample]:
    """[LSER.14.1] `all_time`: from first observation onward, no forgetting."""
    return list(samples)


def sliding(samples: Sequence[Sample], width_ns: int, t_ns: int) -> list[Sample]:
    """[LSER.14.1], [LSIG.2.2.4] `sliding <dur>` read at `t`: the half-open
    window `(t - dur, t]`. A sample exactly `dur` old is outside it; one
    stamped `t` is inside it."""
    return [s for s in samples if t_ns - width_ns < s.t <= t_ns]


def at_capacity(samples: Sequence[Sample], capacity: Optional[int]) -> list[Sample]:
    """[LSER.13.14], [LSER.18.1] `capacity: N` on a backing whose cell says
    **drop**: when a sample reaches an identity already holding `N`, the
    oldest is evicted and the new one retained, so the read covers the `N`
    newest. `None` is no capacity. Applied to the window-live samples: a
    sample that has left the window is not retained and does not count
    against `N`. Under the engine's clock a later absorption carries a later
    stamp, so the `N` newest of the window at the read are the `N` newest at
    every absorption before it, and the two compositions agree. The constant-
    state `all_time` backing retains no samples and is never bound."""
    if capacity is None:
        return list(samples)
    return list(samples)[max(0, len(samples) - capacity):]


RESERVOIR_SEED = 0x9E3779B97F4A7C15


def xorshift64(x: int) -> int:
    """[LSMP.2.1] xs over unsigned 64-bit integers: `x ^= x << 13`, then
    `x ^= x >> 7`, then `x ^= x << 17`, each shift discarding the bits it moves
    out."""
    x ^= (x << 13) & _MASK64
    x ^= x >> 7
    x ^= (x << 17) & _MASK64
    return x & _MASK64


def reservoir(samples: Sequence[Sample], n: int) -> list[Sample]:
    """[LSMP.2.1] `sample n`: the bag after absorbing the samples in
    event-trace order, slot 0 first. The generator state starts at
    `0x9e3779b97f4a7c15`; the i-th sample (i from 1) fills slot i-1 while
    i <= n, and otherwise the state steps once, j = s mod i, and the sample
    replaces slot j when j < n or is discarded. Before the bag is full it holds
    every absorbed sample ([LSER.19.8])."""
    slots: list[Sample] = []
    s = RESERVOIR_SEED
    for i, smp in enumerate(samples, 1):
        if i <= n:
            slots.append(smp)
        else:
            s = xorshift64(s)
            j = s % i
            if j < n:
                slots[j] = smp
    return slots


def values(samples: Sequence[Sample]) -> list:
    """The admitted samples' values, in the backing's order."""
    return [s.v for s in samples]


# ---------------------------------------------------------------------------
# Arithmetic the clauses name.

def as_float(x) -> float:
    """[LSER.16.3.3], [LSER.17.2]: an `Int` sample converts
    round-to-nearest-even; a `Float` is itself."""
    return float(x)


def _wrap64(n: int) -> int:
    """[LEXP.7.13], [LSER.16.2.2]: a 64-bit two's-complement total."""
    return (n + (1 << 63)) % (1 << 64) - (1 << 63)


def _sqrt(x: float) -> float:
    """IEEE `sqrt`: correctly rounded, `-0.0` for `-0.0`, NaN below zero
    ([LDET.3.6.2])."""
    if x < 0.0:
        return math.nan
    return math.sqrt(x)


def _sort_key(x: float) -> tuple[float, float]:
    """[LSER.17.2]'s ascending order over `Float`: by value, `-0` before `+0`."""
    return (x, math.copysign(1.0, x))


# ---------------------------------------------------------------------------
# Counting ([LSER.16.2], [LSER.16.5], [LSER.16.6], [LSER.16.7]).

def count(xs: Sequence) -> int:
    """[LSER.16.2] `count`: the sample count, an `Int`; `0` when cold
    ([LSER.19.8])."""
    return len(xs)


def count_distinct(xs: Sequence) -> int:
    """[LSER.16.5.1] `count_distinct`: the count of distinct values, on a
    bounded `sliding` window ([LSER.16.5.2]); `0` when cold ([LSER.19.8]). Two
    samples are the same value exactly when `==` between them is `true`, as
    the clause states ([LEXP.7.19]): `-0.0` and `+0.0` are one value, and two
    `String`s are one when equal codepoint by codepoint ([LSTR.3.1])."""
    distinct: list = []
    for x in xs:
        if not any(x == d for d in distinct):
            distinct.append(x)
    return len(distinct)


def count_of(xs: Sequence, value) -> int:
    """[LSER.16.6.1] `count_of(cursor, value)`: the count of `value` in the
    window, under the equality `count_distinct` names; `0` when cold."""
    return sum(1 for x in xs if x == value)


def contains(xs: Sequence, value) -> bool:
    """[LSER.16.7.1] `contains(cursor, value)`: whether `value` is in the
    window, under the equality `count_distinct` names; `false` when cold
    ([LSER.19.8])."""
    return any(x == value for x in xs)


# ---------------------------------------------------------------------------
# Sums ([LSER.16.2.2], [LSER.16.3.3], [LSER.17.2]).

def sum_int(xs: Sequence[int]) -> int:
    """[LSER.16.2.2] `sum` over an `Int` slot: the exact integer total in a
    64-bit signed accumulator, wrapping silently once it leaves the range
    ([LEXP.7.13]); `0` when cold ([LSER.19.8])."""
    total = 0
    for x in xs:
        total = _wrap64(total + x)
    return total


def sum_duration(xs: Sequence[int]) -> int:
    """[LSER.17.2] `sum` over a slot of the `time` dimension: [LSER.16.2.2]'s
    accumulation over the nanoseconds. A total the wrap leaves negative raises
    `NotRepresentable` ([LERR.1.4.10]); one of 2**64 nanoseconds or more wraps
    to a value the read cannot tell from a true one, and reads as that value."""
    total = sum_int(xs)
    if total < 0:
        raise NotRepresentable("a time total that wrapped negative")
    return total


def sum_float(xs: Sequence[float]) -> float:
    """[LSER.16.3.3] `sum` over a `Float` slot, every backing: S_0 = +0,
    S_k = S_{k-1} + x_k in the backing's order; `sum` is S_n, so `+0.0` when
    cold ([LSER.19.8]) and `+0.0` over a lone `-0.0`."""
    s = 0.0
    for x in xs:
        s = s + x
    return s


# ---------------------------------------------------------------------------
# Mean and dispersion ([LSER.16.3.3]).

class Moments(NamedTuple):
    """[LSER.16.3.3]'s n, mu and M for one backing."""
    n: int
    mean: float
    m: float


def moments(xs: Sequence, time_model: str) -> Optional[Moments]:
    """[LSER.16.3.3]: every step one correctly rounded binary64 operation, in
    the order written, over the samples as `Float` in the backing's order.
    `None` when cold.

    `all_time`: mu_1 = x_1, M_1 = +0; for k = 2..n, delta = x_k - mu_{k-1},
    mu_k = mu_{k-1} + delta / k, M_k = M_{k-1} + delta * (x_k - mu_k).
    `sample`: mu_0 = +0, M_0 = +0, and the same three steps for k = 1..n.
    `sliding`: two passes, mu = S_n / n, then Q_0 = +0, d = x_k - mu,
    Q_k = Q_{k-1} + d * d, and M = Q_n."""
    fs = [as_float(x) for x in xs]
    n = len(fs)
    if n == 0:
        return None
    if time_model == "all_time":
        mu = fs[0]
        m = 0.0
        for k in range(2, n + 1):
            x = fs[k - 1]
            delta = x - mu
            mu = mu + delta / float(k)
            m = m + delta * (x - mu)
    elif time_model == "sample":
        mu = 0.0
        m = 0.0
        for k in range(1, n + 1):
            x = fs[k - 1]
            delta = x - mu
            mu = mu + delta / float(k)
            m = m + delta * (x - mu)
    elif time_model == "sliding":
        mu = sum_float(fs) / float(n)
        q = 0.0
        for x in fs:
            d = x - mu
            q = q + d * d
        m = q
    else:
        raise ValueError(f"no backing for the time model {time_model!r}")
    return Moments(n, mu, m)


def mean(xs: Sequence, time_model: str) -> Optional[float]:
    """[LSER.16.2], [LSER.16.3.3] `mean`: mu_n of the backing; `null` when
    cold ([LSER.19.8])."""
    mo = moments(xs, time_model)
    return None if mo is None else mo.mean


def variance(xs: Sequence, time_model: str) -> Optional[float]:
    """[LSER.16.3.1], [LSER.16.3.3] `variance`, the sample form: M / (n - 1);
    `null` when cold and when one sample is held."""
    mo = moments(xs, time_model)
    if mo is None or mo.n == 1:
        return None
    return mo.m / float(mo.n - 1)


def pvariance(xs: Sequence, time_model: str) -> Optional[float]:
    """[LSER.16.3.1], [LSER.16.3.3] `pvariance`, the population form: M / n;
    `null` when cold."""
    mo = moments(xs, time_model)
    if mo is None:
        return None
    return mo.m / float(mo.n)


def _deviation(var: Optional[float], time_model: str) -> Optional[float]:
    """[LSER.16.3.3]: the square root of a variance; on `all_time` and
    `sliding` only, a variance not greater than 0 gives +0 instead."""
    if var is None:
        return None
    if time_model in ("all_time", "sliding") and not var > 0.0:
        return 0.0
    return _sqrt(var)


def stdev(xs: Sequence, time_model: str) -> Optional[float]:
    """[LSER.16.3.1], [LSER.16.3.3] `stdev`: sqrt(`variance`), under
    `_deviation`'s rule; `null` when cold and when one sample is held."""
    return _deviation(variance(xs, time_model), time_model)


def pstdev(xs: Sequence, time_model: str) -> Optional[float]:
    """[LSER.16.3.1], [LSER.16.3.3] `pstdev`: sqrt(`pvariance`), under
    `_deviation`'s rule; `null` when cold."""
    return _deviation(pvariance(xs, time_model), time_model)


# ---------------------------------------------------------------------------
# Quantiles ([LSER.16.4], [LSER.17.2]).

def percentile(xs: Sequence, p: int) -> Optional[float]:
    """[LSER.17.2] `pXX`, p the integer XX in 1..99 ([LSER.17.6]). The window's
    n samples sorted ascending as `Float`, `-0` before `+0`, give
    x_0 <= ... <= x_{n-1}. In exact integers num = (n - 1) p,
    lo = num div 100, frac = num mod 100. The result is x_lo when frac = 0,
    when x_lo = x_{lo+1}, or when x_lo = -inf and x_{lo+1} != +inf; otherwise
    x_lo + (frac / 100) (x_{lo+1} - x_lo), as correctly rounded operations in
    exactly this order: the subtraction, the division frac / 100, the
    multiplication, the addition. A cold window reads `null`; n = 1 reads x_0;
    a bracketing pair of -inf and +inf reads NaN."""
    if not 1 <= p <= 99:
        raise ValueError(f"p{p} is not a quantile in 1..99")
    n = len(xs)
    if n == 0:
        return None
    s = sorted((as_float(x) for x in xs), key=_sort_key)
    if n == 1:
        return s[0]
    lo, frac = divmod((n - 1) * p, 100)
    x_lo = s[lo]
    if frac == 0:
        return x_lo
    x_hi = s[lo + 1]
    if x_lo == x_hi:
        return x_lo
    if x_lo == -math.inf and x_hi != math.inf:
        return x_lo
    sub = x_hi - x_lo
    quo = frac / 100
    mul = quo * sub
    return x_lo + mul


def median(xs: Sequence) -> Optional[float]:
    """[LSER.16.4.2], [LSER.17.2] `median` is `p50`."""
    return percentile(xs, 50)


# ---------------------------------------------------------------------------
# Extremes ([LSER.16.2], [LSER.17.2]).

def min_(xs: Sequence):
    """[LSER.16.2] `min`: the least sample, in the slot's type; `null` when
    cold ([LSER.19.8]). Over `Float` the least under the order `pXX` sorts by,
    IEEE 754-2019's `minimum` order, as [LSER.17.2] states: of `-0.0` and
    `+0.0` it is `-0.0`, in whichever order the two arrived."""
    if not xs:
        return None
    if isinstance(xs[0], float):
        return min(xs, key=_sort_key)
    return min(xs)


def max_(xs: Sequence):
    """[LSER.16.2] `max`: the greatest sample, in the slot's type; `null` when
    cold. Over `Float` the greatest under the order `pXX` sorts by, IEEE
    754-2019's `maximum` order, as [LSER.17.2] states: of `-0.0` and `+0.0` it
    is `+0.0`, in whichever order the two arrived."""
    if not xs:
        return None
    if isinstance(xs[0], float):
        return max(xs, key=_sort_key)
    return max(xs)


# ---------------------------------------------------------------------------
# Boolean ([LSER.16.8]).

def bool_and(xs: Sequence[bool]) -> Optional[bool]:
    """[LSER.16.8] `bool_and`: true iff every sample is true; `null` when cold
    ([LSER.19.8]), never the vacuous `true`."""
    if not xs:
        return None
    return all(xs)


def bool_or(xs: Sequence[bool]) -> Optional[bool]:
    """[LSER.16.8] `bool_or`: true iff any sample is true; `null` when cold,
    never the vacuous `false`."""
    if not xs:
        return None
    return any(xs)


# ---------------------------------------------------------------------------
# Temporal ([LSER.16.9], [LSER.10.9]).

def first(xs: Sequence):
    """[LSER.16.9] `first`: the oldest sample's value, in the slot's type;
    `null` when cold."""
    return xs[0] if xs else None


def last(xs: Sequence):
    """[LSER.16.9] `last`: the newest sample's value, in the slot's type;
    `null` when cold."""
    return xs[-1] if xs else None


def direction(xs: Sequence) -> Optional[int]:
    """[LSER.10.9] `direction`: sgn(x_new - x_prev) over the two newest
    samples in the window, the sign decided by comparing the two samples and
    never from a wrapped `Int` or a rounded `Float` subtraction; `-0` and `+0`
    compare equal. `-1`, `0` or `+1`; `null` with fewer than two samples."""
    if len(xs) < 2:
        return None
    new, prev = xs[-1], xs[-2]
    return int(new > prev) - int(new < prev)


def rate(samples: Sequence[Sample]) -> Optional[float]:
    """[LSER.16.9] `rate`: `((x_l - x_f) * 10^9) / (t_l - t_f)` over the
    window's oldest and newest samples, in the order the clause states, each
    step one correctly rounded binary64 operation: the values as `Float`
    ([LSER.16.3.3]'s conversion), the subtraction, the multiplication by 1e9,
    the division by the exact `Int` difference of the absorption instants
    converted round-to-nearest-even. `null` when cold and when no time elapses
    between the two."""
    if len(samples) < 2:
        return None
    t_first, t_last = samples[0].t, samples[-1].t
    if t_last <= t_first:
        return None
    dv = as_float(samples[-1].v) - as_float(samples[0].v)
    return (dv * 1e9) / float(t_last - t_first)


# ---------------------------------------------------------------------------
# The `time` dimension's return ([LSER.17.2], [LTIM.4.1.1]).

def duration_of(x: Optional[float]) -> Optional[int]:
    """[LSER.17.2] over a slot of the `time` dimension, `mean`, `median`,
    `stdev`, `pstdev` and `pXX` return `Duration?`: the `Float` the clause
    states, rounded ties-to-even to a whole number of nanoseconds as a
    `Duration` scaled by a `Float` is ([LTIM.4.1.1]). A non-finite value, or
    one outside `Int`, raises `NotRepresentable` ([LERR.1.4.10]). `null` stays
    `null`."""
    if x is None:
        return None
    if not math.isfinite(x):
        raise NotRepresentable(repr(x))
    r = round(x)
    if not _INT64_MIN <= r <= _INT64_MAX:
        raise NotRepresentable(repr(x))
    return r

# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""End-to-end p1..p99 percentile validation (Option B / RFC_builtin_op_enum).

Under Option B every pN lowers to the SINGLE FN_SERIES_PERCENTILE op with the
percentile N threaded as the call's value argument, dispatched over the
SeriesBackendRingBuffer raw-sample ring buffer via query_with_value ->
ds_series_ring_buffer_percentile(N). This suite proves the whole range computes
the CORRECT value on each N, not just that it compiles.

Construction: over the ascending window val = 1,2,..,100 (100 samples), [LSER.17.2]'s
interpolation (Hyndman-Fan type 7) is closed-form: num = 99*N, lo = num // 100,
frac = num % 100, and pN = x[lo] + (frac/100)(x[lo+1] - x[lo]) with x[i] = i + 1,
evaluated as the clause's four IEEE-754 operations in its order. `_expected`
computes exactly that in Python doubles, which are the same operations, and the
rule compares against its shortest round-trip literal. One program carries 99
rules, `rule check_pN: Reading r where pN(r.val) == <expected> -> log
critical "pN"`; the alert for pN fires IFF the runtime computes pN to the bit. A
composition bug (N threaded to the wrong arg, all pN collapsing to one kind), a
nearest-rank answer (exactly N, which type 7 never gives here: 99N is never a
multiple of 100 for N in 1..99), or a fused multiply-add drops that pN's alert,
and the parametrized case for that N fails -- pinpointing exactly which
percentile broke.
"""

import pytest
from log_sink import capture_critical

import pyds

_WINDOW_NS = 3600000000000  # 1h, matching `sliding 1h`
_NS = list(range(1, 100))  # p1 .. p99


def _expected(n: int) -> float:
    """Return [LSER.17.2]'s pN over x[i] = i + 1, i in 0..99.

    The rank is computed in exact integers, then subtraction, division,
    multiplication, addition, in that order.
    """
    num = 99 * n
    lo, frac = num // 100, num % 100
    x_lo, x_hi = float(lo + 1), float(lo + 2)
    if frac == 0:
        return x_lo
    d = x_hi - x_lo
    f = frac / 100.0
    m = f * d
    return x_lo + m


def _program() -> str:
    decls = "\n".join(f"    p{n} sliding 1h" for n in _NS)
    rules = "\n\n".join(
        f"rule check_p{n}:\n"
        f"    Reading r where p{n}(r.val) == {_expected(n)!r}\n"
        f"->\n"
        f'    log critical "p{n}"'
        for n in _NS
    )
    return (
        "use default\n\n"
        "schema Reading scope logical:\n"
        "    entity_id: String key\n"
        "    val: Float mutable\n\n"
        f"series Reading.val:\n{decls}\n\n"
        f"{rules}\n"
    )


@pytest.fixture(scope="module")
def fired_percentiles() -> set[str]:
    """Return the pN labels whose alert fired over 100 ascending samples.

    The 99-rule program is compiled once and fed 100 ascending samples, so the
    exact window is 1..100. Fire-then-sample (LSER.8.6): the read on assert k sees the k-1
    already-absorbed samples, so a trailing trigger assert reads the full
    100-sample window.
    """
    eng = pyds.from_source(_program())
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    for i in range(1, 101):  # samples val = 1.0 .. 100.0
        eng.clock.set(i * 1_000_000_000)
        eng.assert_("Reading", entity_id="d1", val=float(i))
        eng.pump()
    # trigger: reads the full [1..100] window before its own sample absorbs.
    eng.clock.set(101 * 1_000_000_000)
    eng.assert_("Reading", entity_id="d1", val=1.0)
    eng.pump()

    return set(alerts)


@pytest.mark.parametrize("n", _NS)
def test_percentile_n_computes_exact_value(n: int, fired_percentiles: set[str]) -> None:
    """PN over 1..100 must equal [LSER.17.2]'s interpolated value, bit for bit.

    The alert fires iff the Option B path threaded N correctly and interpolated
    as the clause orders the operations.
    """
    assert f"p{n}" in fired_percentiles, (
        f"p{n}(1..100) did not compute {_expected(n)!r} -- no alert fired; the "
        f"percentile path mis-threaded N or did not interpolate as [LSER.17.2] "
        f"orders it"
    )

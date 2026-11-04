# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Whether pump cost scales with the live fact population.

The question is whether it scales with that rather than with the matchable one.

Three schemas, one rule, a constant probe, and one per-step shape: retract the
churned singleton, re-assert it, advance the mock clock past the emitted fact's
ttl, pump — and time ONLY the pump.

WHY IT IS SHAPED LIKE THIS. `Inert` is the discriminator and is why there are
three schemas rather than two. No rule mentions it, so it cannot be matched,
joined or activated. If pump time tracks `Keyed` but not `Inert`, the join is
scanning instead of using the key index. If it tracks BOTH, the cost is
per-pump working-memory bookkeeping and has nothing to do with joins.

`d.probe` never moves, so exactly one `Keyed` row matches on every pump at every
population size. Any rise with population is therefore not join work.

THIS TEST ASSERTS NOTHING ABOUT TIME. Wall-clock on a shared build host is not
a fact you can gate on: two runs of one configuration can differ by nearly
2x. It asserts the structural invariants (the populations are live,
the rule fires) and PRINTS the timings. Read them from the gate log; compare
two runs of the same host, never a number against a threshold.
"""

from __future__ import annotations

import os
import time
import warnings

import pyds


class PumpSweepReport(UserWarning):
    """The measurement, carried where it can be read.

    pytest captures stdout and discards it for a PASSING test, and the gate
    runs `-q -p no:cacheprovider -ra` with no `-s`, so a printed table never
    reaches the log — which is how the first run of this file produced numbers
    nobody could see. The warnings summary is printed for passing tests, so the
    table rides a warning. It is still printed too, for anyone running pytest
    by hand with `-s`.
    """


def _emit(text: str) -> None:
    print(text)
    warnings.warn(text, PumpSweepReport, stacklevel=2)


_DS_SOURCE = """
schema Drive scope logical:
    "The churned singleton: retracted and re-asserted by the host every pump."
    gen: Int mutable
    probe: Int mutable

schema Keyed scope logical:
    "A keyed population. Exactly one member matches, whatever N is."
    k: Int key
    v: Int mutable

schema Inert scope logical:
    "A population no rule mentions. Present only to be counted."
    k: Int key
    v: Int mutable

schema Hit scope ttl 1_h:
    "Emitted once per pump, so the pump has work to retire."
    v: Int

rule probe:
    Drive d
    Keyed m where m.k == d.probe
->
    emit Hit v: m.v
"""

_DAY_NS = 2 * 3600 * 1_000_000_000

# The reporter's grid. Rows 5-6 hold `Keyed` at 4096 and make up the rest of
# the population with `Inert`, so they are the same TOTAL as rows 3-4 with a
# completely different split — that pair is the whole experiment.
_GRID = [
    (4096, 0),
    (8192, 0),
    (16384, 0),
    (4096, 12288),  # same total as row 3
    (4096, 28672),  # same total as row 4 (32768 keyed) at 1/8 the keyed count
    (32768, 0),
]

_STEPS = int(os.environ.get("DS_PUMPSWEEP_STEPS", "200"))
_ROUNDS = int(os.environ.get("DS_PUMPSWEEP_ROUNDS", "3"))


def _one(dsc: bytes, n_keyed: int, n_inert: int, steps: int) -> tuple[float, int]:
    """One configuration. Returns (mean pump ns/step, live fact count)."""
    eng = pyds.Engine()
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    for i in range(n_keyed):
        eng.assert_("Keyed", k=i, v=i)
    for i in range(n_inert):
        eng.assert_("Inert", k=i, v=i)

    # The reporter's join.c also called set_wm_max, to arm the slab pools. In
    # this edition N_max is advisory and arms nothing ([NRTM.3.1]), so there
    # is no pool arrangement to mirror.

    probe = n_keyed // 2 if n_keyed else 0
    drive = eng.assert_("Drive", gen=0, probe=probe)

    t_pump = 0
    for s in range(1, steps + 1):
        eng.retract(drive)
        drive = eng.assert_("Drive", gen=s, probe=probe)
        eng.clock.advance(_DAY_NS)
        a = time.perf_counter_ns()
        eng.pump()
        t_pump += time.perf_counter_ns() - a

    return t_pump / steps, len(eng.facts)


def test_pump_cost_vs_population():
    dsc = pyds.compile(_DS_SOURCE, file="join.ds")

    # Interleave the rounds rather than repeating each configuration back to
    # back: on a shared host a slow neighbour arriving mid-run would otherwise
    # land entirely on one configuration and read as a scaling effect.
    best: dict[tuple[int, int], float] = {}
    facts: dict[tuple[int, int], int] = {}
    for _ in range(_ROUNDS):
        for cfg in _GRID:
            ns, fc = _one(dsc, cfg[0], cfg[1], _STEPS)
            if cfg not in best or ns < best[cfg]:
                best[cfg] = ns
            facts[cfg] = fc

    rows = [
        f"pump scaling: pump ns/step, min of {_ROUNDS} interleaved rounds x {_STEPS} steps",
        f"{'keyed':>8} {'inert':>8} {'total':>8} {'pump ns/step':>14} {'ns/fact':>9}",
    ]
    for cfg in _GRID:
        total = facts[cfg]
        rows.append(
            f"{cfg[0]:>8} {cfg[1]:>8} {total:>8} {best[cfg]:>14.1f} {best[cfg] / total:>9.2f}"
        )

    # The discriminator, reported rather than asserted: same total population,
    # different split. If these two ever diverge sharply the cost has become
    # join-shaped, which would be a different bug from the one filed.
    same_total = [(4096, 12288), (16384, 0)]
    if all(c in best for c in same_total):
        a, b = (best[c] for c in same_total)
        rows.append(
            f"same-total split (4096+12288 vs 16384+0): "
            f"{a:.1f} vs {b:.1f} ns -> "
            f"{abs(a - b) / max(a, b) * 100:.1f}% apart"
        )

    _emit("\n" + "\n".join(rows))

    # Structural invariants only. Every population is live, and the rule that
    # matches exactly one row still fires, so the timings above describe a
    # working engine rather than an early-exit.
    for cfg in _GRID:
        n_keyed, n_inert = cfg
        # keyed + inert + the Drive singleton; Hit is emitted and expires
        # within the same pump, so it is not live at the count.
        assert facts[cfg] >= n_keyed + n_inert, (
            f"{cfg}: expected at least {n_keyed + n_inert} live facts, got {facts[cfg]}"
        )

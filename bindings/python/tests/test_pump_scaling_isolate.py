# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Find WHERE a population-proportional pump cost is.

test_pump_scaling_perf.py shows whether the pump scales with the live fact
population; this file finds which part of the work does, by experiment rather
than by reading.

FOUR SHAPES, each dropping one ingredient of the `full` shape. Every one holds
the fact population identical; only the work the pump is asked to do changes.
Whichever shapes still scale with population contain the term.

    full     churn a Drive singleton, join it against a
             keyed population, emit a ttl fact each pump
    no_emit  same, but the RHS logs instead of emitting — so no TTL fact is
             created or retired per pump
    no_churn Drive is asserted ONCE and never re-asserted, so no rule can
             re-activate. The pump has nothing to do but its fixed work.
    no_rule  the schemas exist and the population is asserted, but the program
             declares no rule at all

`no_churn` and `no_rule` are the discriminating pair. If an idle pump over N
facts costs O(N), the term is unconditional per-pump work and `ds_rete_run` is
innocent. If they are flat and only `full` scales, the cost is in activation or
propagation, not in the TTL sweep.

`set_wm_max` arms nothing in this edition ([NRTM.3.1]), so population is the
only axis.

Prints, asserts nothing about time — same reasoning as
test_pump_scaling_perf.py.
"""

from __future__ import annotations

import os
import time
import warnings

from test_pump_scaling_perf import PumpSweepReport

import pyds

_SCHEMAS = """
schema Drive scope logical:
    gen: Int mutable
    probe: Int mutable

schema Keyed scope logical:
    k: Int key
    v: Int mutable

schema Inert scope logical:
    k: Int key
    v: Int mutable
"""

_HIT = """
schema Hit scope ttl 1_h:
    v: Int
"""

_RULE_EMIT = """
rule probe:
    Drive d
    Keyed m where m.k == d.probe
->
    emit Hit v: m.v
"""

_RULE_LOG = """
rule probe:
    Drive d
    Keyed m where m.k == d.probe
->
    log info "hit"
"""

_SHAPES = {
    "full": _SCHEMAS + _HIT + _RULE_EMIT,
    "no_emit": _SCHEMAS + _RULE_LOG,
    "no_churn": _SCHEMAS + _HIT + _RULE_EMIT,  # same program, different driver
    "no_rule": _SCHEMAS,
}

_DAY_NS = 2 * 3600 * 1_000_000_000
_STEPS = int(os.environ.get("DS_PUMPSWEEP_STEPS", "200"))
_ROUNDS = int(os.environ.get("DS_PUMPSWEEP_ROUNDS", "3"))
_SIZES = [4096, 32768]


def _run(shape: str, dsc: bytes, n_facts: int, steps: int) -> float:
    eng = pyds.Engine()
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    for i in range(n_facts):
        eng.assert_("Keyed", k=i, v=i)

    probe = n_facts // 2
    drive = eng.assert_("Drive", gen=0, probe=probe)
    churn = shape != "no_churn"

    t = 0
    for s in range(1, steps + 1):
        if churn:
            eng.retract(drive)
            drive = eng.assert_("Drive", gen=s, probe=probe)
        eng.clock.advance(_DAY_NS)
        a = time.perf_counter_ns()
        eng.pump()
        t += time.perf_counter_ns() - a
    return t / steps


def test_which_pump_phase_scales():
    dscs = {name: pyds.compile(src, file=f"{name}.ds") for name, src in _SHAPES.items()}

    cases = [(f"{n // 1024}k", n) for n in _SIZES]

    best: dict[tuple[str, str], float] = {}
    for _ in range(_ROUNDS):
        for shape in _SHAPES:
            for label, n in cases:
                ns = _run(shape, dscs[shape], n, _STEPS)
                key = (shape, label)
                if key not in best or ns < best[key]:
                    best[key] = ns

    rows = [
        f"pump scaling by shape: which scale with population? "
        f"min of {_ROUNDS} rounds x {_STEPS} steps",
        f"{'shape':>10} {'facts':>7} {'pump ns':>12}",
    ]
    for shape in _SHAPES:
        for label, _n in cases:
            rows.append(f"{shape:>10} {label:>7} {best[(shape, label)]:>12.1f}")

    text = "\n" + "\n".join(rows)
    print(text)
    warnings.warn(text, PumpSweepReport, stacklevel=2)

    for shape in _SHAPES:
        for label, _n in cases:
            assert best[(shape, label)] > 0

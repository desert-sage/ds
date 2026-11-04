# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`sum all_time` read through a companion slot.

WHY THIS EXISTS. A compiler fixture asserts that a program COMPILES, not the
VALUE a descriptive aggregation produces, so a `sum` answering 0 would be
invisible to it.

THE RULE-OBSERVABLE VALUE, through the companion slot `s.sum`. libds's own
series tests read the backing below every rule; there is no public series read
([NSBK.6.3]).

⚠ TWO WAYS TO MIS-MEASURE THIS, both of which produce a convincing fake 0:

1. THE READING RULE IS LOAD-BEARING. Backend emission is lazy ([RDSC.5a.2]): a
   series with no rule-side reference emits NO backend atoms, the engine gets
   `n_series_decls == 0`, `ds_rete_engine_absorb_pending` returns immediately
   and every read answers its cold-start 0.

2. THE FIRST ACTIVATION CORRECTLY READS 0. [LSER.8.6] is fire-then-sample:
   pump N's rules read a backing that does NOT yet include the fact that
   activated them; absorption runs after the run drains. So N observations
   yield N-1 totals' worth of history, and reading only the first one measures
   the ordering contract, not the sum. THREE observations are asserted here so
   the last read has a two-sample total (7) genuinely available to it.

   The output schema is keyed on `seq`, one key per observation, so every
   activation lands as its own `fact_assert`. Keyed on the series `by:` slot
   instead, the 2nd and 3rd emits would be `fact_modify` on one logical fact
   and a `fact_assert`-only callback would silently see the first read alone.
"""

import pyds

_SUM_DS = """
use default

schema Spend scope ttl 1_h:
    k: String
    seq: Int
    v: Int

series Spend.v (by: k):
    sum all_time

schema Total scope logical:
    seq: Int key
    total: Float mutable

rule read_total:
    Spend s
->
    emit Total logical
        seq: s.seq
        total: s.sum :: Float
"""

# `total: Int` is what the aggregation reference says a value-preserving agg
# returns ("min, max, sum -> slot type", and `v` is Int). The Float-slot
# program above measures the VALUE; since `s.sum` over an Int slot is
# statically an Int ([LSER.17.2]), reaching a Float slot takes the explicit
# cast [LEXP.7.3b] requires -- promotion stops at a slot. The Int-slot form
# below needs no cast.
_SUM_INT_SLOT_DS = _SUM_DS.replace("total: Float mutable", "total: Int mutable").replace(
    "total: s.sum :: Float", "total: s.sum"
)

# Three observations in ONE `by:` group. Pumped separately so absorption
# (end-of-pump, [LSER.8.6]) has run for each before the next arrives. The
# running total visible to each activation is therefore the sum of its
# PREDECESSORS: 0, then 3, then 7.
_OBSERVATIONS = ((1, 3), (2, 4), (3, 0))
_EXPECTED = [0.0, 3.0, 7.0]


def _run(src=_SUM_DS):
    eng = pyds.from_source(src)
    totals: list[float] = []

    def on_event(ev):
        if isinstance(ev, pyds.events.FactAssert):
            f = eng.facts[ev.fact_id]
            if f.schema == "Total":
                totals.append(f.slots.get("total"))

    eng.on_event = on_event
    eng.pump()
    for seq, v in _OBSERVATIONS:
        eng.assert_("Spend", k="g", seq=seq, v=v)
        eng.pump()
    return eng, totals


def test_sum_all_time_is_readable_through_the_companion_slot():
    """The rule fires and `s.sum` must not be a plausible 0.

    Asserts the whole sequence, not just the last value: [0, 3, 7] is the only
    series consistent with BOTH a working `sum` and fire-then-sample. A flat
    [0, 0, 0] is a `sum` that never accrues; [3, 7, 7] would be a correct sum with the ordering
    contract broken, which is a different bug and must not pass as this one.
    """
    _eng, totals = _run()
    assert totals, "rule read_total never emitted a Total"
    assert totals == _EXPECTED, (
        f"companion-slot `s.sum` read {totals!r}, want {_EXPECTED!r} "
        f"(each activation sees the total of its predecessors, [LSER.8.6])"
    )


def test_sum_over_an_int_slot_returns_an_int():
    """[LSER.16.2]: a value-preserving aggregation returns the SLOT's type.

    The aggregation table gives `min`/`max`/`sum` as returning the slot type
    and `count` as `Int`; `Spend.v` is `Int`, so `s.sum` is an `Int`. A Float
    here is not cosmetic: with `total: Int` every activation's emit would be
    refused with DS_ERR_SLOT_TYPE_MISMATCH.

    Drives the Int-slot declaration, so the whole sequence has to survive. The
    pre-sample read at the front is where a Float surfaces first: it is
    answered by the neutral zero, before any row exists, rather than by a
    backing — so the zero needs the declared type as much as the total does.
    """
    _eng, totals = _run(_SUM_INT_SLOT_DS)  # must not raise [-104]
    assert totals == [0, 3, 7], f"Int-slot totals {totals!r}"
    assert all(type(t) is int for t in totals), (
        f"`sum` over an Int slot must land in the slot as an Int; got "
        f"{[type(t).__name__ for t in totals]}"
    )

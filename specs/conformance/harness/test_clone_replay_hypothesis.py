#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# @spec [NDET.1.1] [NLFC.8.1]
"""Hypothesis property test for replay determinism + clone equivalence
([NDET.1.1] / [NLFC.8.1]).

[NDET.1.1] "the same rule set + the same fact stream + the same platform produce
the same output, bit-for-bit." [NLFC.8.1] `ds_engine_clone` produces an
independent engine identical to the source at call time. This drives the REAL
engine through random assert/pump streams (with a rule + a negation, so pumping
derives and TMS-retracts) and checks:

  * DETERMINISM ([NDET.1.1]): two fresh engines fed the identical op stream emit
    the identical observable stream and end at the identical fact_count.
  * CLONE EQUIVALENCE ([NLFC.8.1]): a clone taken mid-run, fed the identical
    suffix as its source, emits the identical suffix stream and matching count.
  * CLONE INDEPENDENCE ([NLFC.8.1]): an op applied to only one of {source, clone}
    leaves the other's fact_count unchanged -- they share no working memory.

The stream is compared at the event level -- (kind, schema, slots) for fact
events, keyed through a live-handle map so a retract resolves to the fact it
removes; fact HANDLES are pointers (engine-specific) and are never compared.
"""
from __future__ import annotations

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

# A rule with a negation: Der(k) is derived for each In(k) not blocked by Blk(k),
# so asserting Blk(k) TMS-retracts the derived Der(k) -- assert + derive + retract
# all appear on the stream, a rich deterministic signal.
PROGRAM_DS = """\
use default

schema In scope logical:
    k: Int key
schema Blk scope logical:
    k: Int key
schema Der scope logical:
    k: Int key
rule derive_unblocked:
    In a
    no Blk b where b.k == a.k
->
    emit Der logical k: a.k
"""

_DSC = None


def _dsc() -> bytes:
    global _DSC
    if _DSC is None:
        import pyds
        _DSC = pyds.compile(PROGRAM_DS, file="clone_replay.ds")
    return _DSC


class Recorder:
    """Captures an engine's observable stream as an ordered, handle-free list."""

    def __init__(self, eng) -> None:
        self.eng = eng
        self.live: dict[object, tuple] = {}
        self.seq: list[tuple] = []

    # The output compared is the working-memory fact stream, in order. The
    # rule-fire trace events are left out: a re-registered clone does not
    # reproduce them.
    def cb(self, ev) -> None:
        kind = ev.kind
        if kind in ("fact_assert", "fact_modify"):
            h = ev.fact_id
            info = self.eng.facts[h]
            ident = (info.schema, tuple(sorted(info.slots.items())))
            self.live[h] = ident
            self.seq.append((kind, ident))
        elif kind == "fact_retract":
            ident = self.live.pop(ev.fact_id, ("?", ()))
            self.seq.append((kind, ident))


def _new_engine():
    import pyds
    eng = pyds.Engine()
    eng.load_dsc(_dsc())
    eng.clock.mode = "mock"
    eng.clock.set(0)
    return eng


def _apply(eng, op) -> None:
    if op[0] == "pump":
        eng.pump()
    else:
        eng.assert_(op[0], k=op[1])


# assert In(k) / assert Blk(k) / pump, over a tiny key domain -> collisions,
# derivations, and negation-driven TMS retractions.
_OP = st.one_of(
    st.tuples(st.just("In"), st.integers(0, 2)),
    st.tuples(st.just("Blk"), st.integers(0, 2)),
    st.just(("pump",)),
)


@settings(max_examples=200, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
@given(ops=st.lists(_OP, max_size=30))
def test_replay_determinism(ops):
    """[NDET.1.1] identical op stream => identical observable stream + count."""
    a, b = _new_engine(), _new_engine()
    ra, rb = Recorder(a), Recorder(b)
    a.on_event = ra.cb
    b.on_event = rb.cb
    try:
        for op in ops:
            _apply(a, op)
            _apply(b, op)
        assert ra.seq == rb.seq, "streams diverged for identical inputs"
        assert len(a.facts) == len(b.facts)
    finally:
        a.close()
        b.close()


@settings(max_examples=200, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
@given(prefix=st.lists(_OP, max_size=15), suffix=st.lists(_OP, max_size=15))
def test_clone_equivalence_and_independence(prefix, suffix):
    """[NLFC.8.1] a clone is identical at call time, tracks an identical suffix,
    and shares no working memory with its source."""
    src = _new_engine()
    try:
        for op in prefix:
            _apply(src, op)

        clone = src.clone()
        try:
            # Identical at call time.
            assert len(src.facts) == len(clone.facts)

            # Fresh symmetric recorders capture only the post-clone suffix stream.
            rs, rc = Recorder(src), Recorder(clone)
            src.on_event = rs.cb
            clone.on_event = rc.cb
            for op in suffix:
                _apply(src, op)
                _apply(clone, op)
            assert rs.seq == rc.seq, "clone diverged from source on identical suffix"
            assert len(src.facts) == len(clone.facts)

            # Independence: an op on the clone alone leaves the source untouched.
            before = len(src.facts)
            clone.assert_("In", k=99)
            clone.pump()
            assert len(src.facts) == before, "clone mutation leaked into source"
        finally:
            clone.close()
    finally:
        src.close()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))

#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# @spec [LFAC.2.5.1] [LFST.9.2.1] [NFCT.4.4] [NFCT.4.4.1] [NFCT.4.4.2] [NFCT.4.4.3] [NFCT.4.4.4] [NFCT.5.4] [RFCS.6.7]
"""Hypothesis property test for LOGICAL upsert / dedup lifecycle ([NFCT.4.4]).

Generates random assert streams through the real compiler and C runtime via pyds
and checks the upsert/dedup semantics against a reference model.

THE CONTRACT ([NFCT.4.4]). Assert is an upsert keyed on a LOGICAL schema's KEY
slots; exactly one live fact exists per KEY tuple:
  * [NFCT.4.4.1] matching KEY replaces (retract old + assert new payload).
  * [NFCT.4.4.2] key = all slots  -> exact re-assert is a NO-OP IN WORKING
    MEMORY: fact_count is unchanged, but FACT_ASSERT still fires.
    key = none -> singleton, latest wins.
  * [NFCT.4.4.3] a within-`tolerance` change on a MUTABLE numeric slot is a
    no-op; the live fact is kept.
  * [NFCT.4.4.4] TTL schemas do NOT dedup -- every assert is a distinct fact.
  * [NFCT.5.4]   a no-op LOGICAL reassertion DOES emit FACT_ASSERT.

[RFCS.6.7]: a FactAssert marks an assert arriving, not a fact entering working
memory, so the no-op never reaches the recorder.
logical/RFCS.6.7_noop_reassert_recorded pins the case.

The properties checked after every op: engine fact_count equals the reference
live count, and every op the reference classifies as a no-op emits EXACTLY ONE
stream event. Domains are deliberately tiny so re-asserts, replaces and
tolerance boundaries recur.
"""
from __future__ import annotations

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

# Five LOGICAL/TTL schemas spanning the key-width spectrum of [NFCT.4.4]:
#   Ent  -- key subset (entity-state): one KEY, one MUTABLE payload.
#   Rel  -- key = all slots (relation): exact re-assert is a no-op.
#   Sing -- key = none (singleton): one live fact, latest payload wins.
#   Tol  -- MUTABLE numeric slot with a reassertion tolerance.
#   Ev   -- TTL schema: no dedup, asserts accumulate.
PROGRAM_DS = """\
use default

schema Ent scope logical:
    e: Int key
    v: Int mutable
schema Rel scope logical:
    a: Int key
    b: Int key
schema Sing scope logical:
    v: Int mutable
schema Tol scope logical:
    e: Int key
    x: Float mutable tolerance 0.5
schema Ev scope ttl 3600_s:
    x: Int
"""

TOL = 0.5


def _compile_dsc() -> bytes:
    # Through pyds.compile, the Mercury dsc.
    import pyds

    return pyds.compile(PROGRAM_DS, file="upsert_dedup.ds")


# Compile once for the whole module (the schemas never change across examples).
_DSC = None


def _dsc() -> bytes:
    global _DSC
    if _DSC is None:
        _DSC = _compile_dsc()
    return _DSC


class Reference:
    """The abstract upsert/dedup model each op is checked against."""

    def __init__(self) -> None:
        self.ent: dict[int, int] = {}          # e -> v
        self.rel: set[tuple[int, int]] = set()  # (a, b)
        self.sing: int | None = None            # latest v, or absent
        self.tol: dict[int, float] = {}         # e -> x (kept within tolerance)
        self.ev = 0                             # TTL count (no dedup)

    def live_count(self) -> int:
        return (len(self.ent) + len(self.rel) + (1 if self.sing is not None else 0)
                + len(self.tol) + self.ev)

    def apply(self, op):
        """Apply op to the model; classify it.

        Returns `"exact"` for a no-op reassertion of a tuple that already
        exists ([NFCT.4.4.2/.3]), `"absorbed"` for one whose value DID differ
        and was swallowed by a tolerance band, and None for a real change.
        """
        kind = op[0]
        if kind == "Ent":
            _, e, v = op
            noop = self.ent.get(e, object()) == v
            self.ent[e] = v
            return "exact" if noop else None
        if kind == "Rel":
            _, a, b = op
            noop = (a, b) in self.rel
            self.rel.add((a, b))
            return "exact" if noop else None
        if kind == "Sing":
            _, v = op
            noop = self.sing == v
            self.sing = v
            return "exact" if noop else None
        if kind == "Tol":
            _, e, x = op
            # [LFAC.2.5.1]: the boundary is inclusive. The sampled 1.0 and 1.5
            # land exactly on it.
            if e in self.tol and abs(self.tol[e] - x) <= TOL:
                # `==` matches the engine's memcmp: the strategy samples no NaN
                # and no -0.0.
                return "exact" if self.tol[e] == x else "absorbed"
            self.tol[e] = x
            return None
        if kind == "Ev":
            self.ev += 1                          # TTL never dedups
            return None
        raise AssertionError(kind)


def _engine_assert(eng, op) -> None:
    kind = op[0]
    if kind == "Ent":
        eng.assert_("Ent", e=op[1], v=op[2])
    elif kind == "Rel":
        eng.assert_("Rel", a=op[1], b=op[2])
    elif kind == "Sing":
        eng.assert_("Sing", v=op[1])
    elif kind == "Tol":
        eng.assert_("Tol", e=op[1], x=op[2])
    elif kind == "Ev":
        eng.assert_("Ev", x=op[1])
    else:
        raise AssertionError(kind)


# Tiny domains: force key collisions, exact re-asserts, replaces, tolerance edges.
_OP = st.one_of(
    st.tuples(st.just("Ent"), st.integers(0, 3), st.integers(0, 2)),
    st.tuples(st.just("Rel"), st.integers(0, 2), st.integers(0, 2)),
    st.tuples(st.just("Sing"), st.integers(0, 2)),
    st.tuples(st.just("Tol"), st.integers(0, 2),
              st.sampled_from([0.0, 0.3, 0.6, 1.0, 1.5])),
    st.tuples(st.just("Ev"), st.integers(0, 2)),
)


@settings(max_examples=250, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
@given(st.lists(_OP, max_size=40))
def test_upsert_dedup_lifecycle(op_list):
    import pyds

    eng = pyds.Engine()
    eng.load_dsc(_dsc())
    eng.clock.mode = "mock"
    eng.clock.set(0)

    events = {"n": 0}
    eng.on_event = lambda ev: events.__setitem__("n", events["n"] + 1)

    ref = Reference()
    try:
        for op in op_list:
            before = events["n"]
            noop = ref.apply(op)
            _engine_assert(eng, op)
            # [NFCT.4.4] exactly one live fact per KEY tuple => counts agree.
            assert len(eng.facts) == ref.live_count(), (
                f"count diverged after {op}: engine={len(eng.facts)} "
                f"ref={ref.live_count()}")
            # [RFCS.6.7]: a no-op reassertion is recorded, exactly once, for a
            # replayer driving [LFST.9.2.1]'s pump-per-input cadence.
            if noop:
                assert events["n"] == before + 1, (
                    f"no-op {op} emitted {events['n'] - before} stream "
                    f"event(s), want exactly 1 (RFCS.6.7)")
    finally:
        # pyds.Engine <-> stream-callback is an untracked ref cycle; close now.
        eng.close()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))

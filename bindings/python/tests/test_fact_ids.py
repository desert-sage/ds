# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A fact is named by its FactId, never by a pointer.

A fact's id is assigned by the engine when the fact enters working memory,
increases, and is never reused. pyds keeps a table of the live ones, fed by the
engine's own assert and retract events, and is the only way a Python value
reaches a fact: every call that takes a fact takes a FactId, and one that is
not live is a KeyError rather than a dereference.

The stream reports facts by id ("fact_id"); a fact-ref slot is written and
read as the target's id, whether or not the target is still live; a clone and
a replay keep a table of their own, which answers inside their own callbacks.
And replay leaves the stream callback registered.
"""

from __future__ import annotations

import json
import pickle
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

import pyds
from pyds import FactId

HELPER = Path(__file__).with_name("_dead_fact_ids.py")
SCRATCH = Path(__file__).resolve().parents[3] / ".build" / "pyds-tests"

SOURCE = """\
schema Motion scope logical:
    entity_id: String key
    state: Int mutable

schema Trace scope ttl 1_h:
    target: Motion

rule make_trace:
    Motion m where m.state > 0
->
    emit Trace target: m
"""


def test_fact_id_is_an_int_that_says_what_it_is():
    f = FactId(42)
    assert f == 42 and isinstance(f, int)
    assert repr(f) == "FactId(42)"
    assert str(f) == "42"
    assert json.dumps({"f": f}) == '{"f": 42}'
    g = pickle.loads(pickle.dumps(f))
    assert type(g) is FactId and g == 42


def test_assert_returns_increasing_fact_ids():
    eng = pyds.from_source(SOURCE)
    a = eng.assert_("Motion", entity_id="a", state=0)
    b = eng.assert_("Motion", entity_id="b", state=0)
    assert type(a) is FactId and type(b) is FactId
    assert b > a
    assert [f.id for f in eng.facts.of("Motion")] == [a, b]
    assert all(type(fid) is FactId for fid in eng.facts)


@pytest.mark.parametrize(
    "case", ["retract_twice", "retract_invented", "inspect_retracted", "ref_to_retracted"]
)
def test_a_fact_that_is_not_live_is_a_key_error(case):
    proc = subprocess.run(
        [sys.executable, str(HELPER), case], capture_output=True, text=True, timeout=300
    )
    assert proc.returncode == 0 and proc.stdout.strip() == "KeyError", (
        f"exit {proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    )


def test_the_stream_names_facts_by_id_and_they_inspect_inside_the_callback():
    eng = pyds.from_source(SOURCE)
    seen: list[tuple[str, FactId, str]] = []

    def on_event(ev):
        if isinstance(ev, (pyds.events.FactAssert, pyds.events.FactRetract)):
            assert not hasattr(ev, "fact_handle")
            fid = ev.fact_id
            seen.append((ev.kind, fid, eng.facts[fid].schema))

    eng.on_event = on_event
    m = eng.assert_("Motion", entity_id="a", state=0)
    eng.retract(m)
    assert seen == [("fact_assert", m, "Motion"), ("fact_retract", m, "Motion")]
    assert all(type(fid) is FactId for _, fid, _ in seen)


def test_a_fact_ref_slot_is_its_targets_id_live_or_not():
    eng = pyds.from_source(SOURCE)
    m = eng.assert_("Motion", entity_id="a", state=0)
    t = eng.assert_("Trace", target=m)
    assert eng.facts[t].slots["target"] == m
    assert type(eng.facts[t].slots["target"]) is FactId
    eng.retract(m)
    assert eng.facts[t].slots["target"] == m


def test_the_handle_methods_are_gone():
    for name in ("fact_handle", "fact_id", "slot_ref_id", "fact_inspect", "fact_count"):
        assert not hasattr(pyds.Engine, name), name


def test_a_clone_knows_the_facts_it_was_cloned_with():
    eng = pyds.from_source(SOURCE)
    m = eng.assert_("Motion", entity_id="a", state=0)
    twin = eng.clone()
    twin.retract(m)
    assert len(twin.facts) == 0 and len(eng.facts) == 1
    with pytest.raises(KeyError):
        twin.retract(m)
    eng.retract(m)


def _inspecting(eng, seen: list[tuple[str, str]]):
    """Return a stream callback that looks up every fact it is told about."""

    def on_event(ev):
        if isinstance(ev, (pyds.events.FactAssert, pyds.events.FactRetract)):
            seen.append((ev.kind, eng.facts[ev.fact_id].schema))

    return on_event


def test_a_clone_inspects_its_facts_inside_its_own_callback():
    eng = pyds.from_source(SOURCE)
    m = eng.assert_("Motion", entity_id="a", state=0)
    twin = eng.clone()
    seen: list[tuple[str, str]] = []
    twin.on_event = _inspecting(twin, seen)
    twin.assert_("Motion", entity_id="b", state=0)
    twin.retract(m)
    assert seen == [("fact_assert", "Motion"), ("fact_retract", "Motion")]


# The fact-body codec does not carry a fact-ref slot ([RFCS.4]), so what is
# recorded is a program whose facts have none.
RECORDABLE = """\
schema Motion scope logical:
    entity_id: String key
    state: Int mutable

schema Trace scope ttl 1_h:
    entity_id: String

rule make_trace:
    Motion m where m.state > 0
->
    emit Trace entity_id: m.entity_id
"""


def _recording(path: Path) -> bytes:
    eng = pyds.from_source(RECORDABLE)
    eng.clock.mode = "mock"
    with eng.record(path):
        eng.assert_("Motion", entity_id="a", state=1)
        eng.pump()
    eng.close()
    return path.read_bytes()


def test_replay_keeps_the_stream_callback_and_the_table():
    SCRATCH.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(dir=SCRATCH))
    try:
        data = _recording(work / "run.dstrace")
    finally:
        for p in work.iterdir():
            p.unlink()
        work.rmdir()

    eng = pyds.from_source(RECORDABLE)
    eng.clock.mode = "mock"
    seen: list[tuple[str, str]] = []
    eng.on_event = _inspecting(eng, seen)
    eng.replay(data)

    seen.clear()
    n = eng.assert_("Motion", entity_id="b", state=0)
    assert seen == [("fact_assert", "Motion")]  # still registered
    replayed = {f.schema: f.id for f in eng.facts.values() if f.id != n}
    assert set(replayed) == {"Motion", "Trace"}
    eng.retract(replayed["Motion"])  # replayed in, so in the table
    eng.retract(n)

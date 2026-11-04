# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""ds_engine_clone end-to-end through pyds (Engine.clone()).

This is the runtime proof of the RETE NODE GRAPH clone — the part the libds
C test (test_engine_clone) cannot reach because it loads no rules. A real
ruleful engine is driven to a mid-run state, cloned, and then the source and the
clone are driven with an IDENTICAL input sequence; their observable rule firings
must be identical ([LDET.2.2b] clone-diverge-compare check).

The rule exercises the graph broadly: an alpha test (`state > 50`), a beta join,
a negated CE (`no Suppress ...` → a beta NOT node with per-token block counts),
and a logical `emit` (→ a TMS-justified Alarm fact). A correct clone must have
reproduced the alpha/beta/terminal nodes, the left-memory tokens, the agenda,
the NOT-node block map and the TMS justifier table. (The rule graph is a DAG —
Alarm is emitted but never consumed, Suppress is consumed but never emitted — so
it does not trip the self-feeding-cycle check, LCYC.3.1.)
"""

from log_sink import capture_critical

import pyds

_SRC = """
schema Sensor scope logical:
    entity_id: String key
    state: Int mutable

schema Suppress scope logical:
    entity_id: String key

schema Alarm scope logical:
    entity_id: String key

rule raise_alarm:
    Sensor s where s.state > 50
    no Suppress x where x.entity_id == s.entity_id
->
    emit Alarm logical entity_id: s.entity_id
    log critical "alarm {s.entity_id}"
"""


def _sensor(eng, entity_id, state):
    eng.assert_("Sensor", entity_id=entity_id, state=state)
    eng.pump()


def test_clone_reproduces_node_graph_and_diverges_identically():
    # Drive the source to a non-trivial mid-run state: dev1 alarmed (its logical
    # Alarm fact TMS-justified), a live token set, a populated agenda history.
    src = pyds.from_source(_SRC)
    src_alerts: list[str] = []
    capture_critical(src, src_alerts)
    _sensor(src, "dev1", 99)
    assert src_alerts == ["alarm dev1"], src_alerts

    # ---- Clone mid-run (quiescent, between pumps) ----
    clone = src.clone()
    clone_alerts: list[str] = []
    capture_critical(clone, clone_alerts)
    src_alerts.clear()

    # ---- Identical continuation on BOTH engines ----
    def drive(eng):
        eng.assert_("Suppress", entity_id="dev2")  # arm the NOT node for dev2
        _sensor(eng, "dev2", 90)  # blocked by no-Suppress
        _sensor(eng, "dev3", 88)  # fresh → fires
        _sensor(eng, "dev4", 40)  # alpha test fails → no fire
        _sensor(eng, "dev5", 60)  # fresh → fires

    drive(src)
    drive(clone)

    # Byte-identical observable rule firings — the equivalence check.
    assert src_alerts == clone_alerts, (
        f"clone diverged from source:\n src={src_alerts}\n clone={clone_alerts}"
    )
    assert src_alerts == ["alarm dev3", "alarm dev5"], src_alerts

    # Identical fact populations (Sensors + TMS-justified Alarms), distinct objs.
    assert len(src.facts) == len(clone.facts)
    assert clone is not src

    # Independence both ways: a fact asserted into one is invisible to the other.
    _sensor(src, "dev9", 90)
    assert "alarm dev9" in src_alerts
    assert "alarm dev9" not in clone_alerts

    # ---- Free-in-any-order: drop the source; the clone stays fully live ----
    del src
    clone_alerts.clear()
    _sensor(clone, "dev6", 66)
    assert clone_alerts == ["alarm dev6"], clone_alerts


_CALL_SRC = """
schema FooReply scope ttl 1_min:
    corr: String

service svc.foo:
    "clone-diverge call stub"
    response FooReply

schema Trig scope logical:
    id: String key

rule dispatch:
    Trig t
->
    call svc.foo nocooldown as t.id
"""


def test_clone_dispatches_post_clone_calls_identically():
    """The post-clone `call` path clones and fires identically.

    A rule's RHS dispatches an outbound call; after cloning mid-run, the source
    and the clone each re-register a call callback and are driven identically —
    their outbound call correlations must match.
    """
    src = pyds.from_source(_CALL_SRC)
    src_calls: list = []
    src.set_call_callback(src_calls.append)
    src.assert_("Trig", id="pre")
    src.pump()
    assert [c["correlation"] for c in src_calls] == ["pre"], src_calls

    clone = src.clone()
    clone_calls: list = []
    clone.set_call_callback(clone_calls.append)
    src_calls.clear()

    for cid in ("a", "b", "c"):
        src.assert_("Trig", id=cid)
        src.pump()
        clone.assert_("Trig", id=cid)
        clone.pump()

    src_corr = [c["correlation"] for c in src_calls]
    clone_corr = [c["correlation"] for c in clone_calls]
    assert src_corr == clone_corr, f"call streams diverged: {src_corr} vs {clone_corr}"
    assert src_corr == ["a", "b", "c"], src_corr

    # free-in-any-order: drop src, the clone still dispatches
    del src
    clone_calls.clear()
    clone.assert_("Trig", id="post")
    clone.pump()
    assert [c["correlation"] for c in clone_calls] == ["post"], clone_calls


_REF_SRC = """
schema Motion scope logical:
    entity_id: String key
    state: Int mutable

schema Trace scope logical:
    target: Motion key

rule make_trace:
    Motion m where m.state > 0
->
    emit Trace logical target: m
"""


def test_clone_remaps_fact_ref_slots():
    """A clone repoints every FACT_REF slot at its own fact.

    A Trace fact carries a schema-typed `target`
    slot referencing a Motion fact. The clone
    must repoint every FACT_REF at the CLONE's fact, not leave a dangling
    pointer into the source. (v1 forbids chained access through the ref, so the
    remap is proven structurally rather than by dereferencing it.)
    """
    src = pyds.from_source(_REF_SRC)
    src.assert_("Motion", entity_id="kitchen", state=1)
    src.pump()
    # make_trace fired: WM holds the Motion + its TMS-justified Trace(target=m).
    assert len(src.facts) == 2, len(src.facts)

    # Clone mid-run: the Trace and its FACT_REF -> kitchen Motion are copied; a
    # correct clone remapped that ref to the CLONE's kitchen Motion.
    clone = src.clone()
    assert len(clone.facts) == 2, len(clone.facts)

    # Drive both identically: each Motion emits a Trace with a fresh FACT_REF.
    for eid in ("hall", "porch"):
        src.assert_("Motion", entity_id=eid, state=1)
        src.pump()
        clone.assert_("Motion", entity_id=eid, state=1)
        clone.pump()
    assert len(src.facts) == len(clone.facts) == 6, (len(src.facts), len(clone.facts))

    # Free the source while the clone still holds Trace facts whose FACT_REF
    # targets point into the CLONE's Motion facts. If any ref had been left
    # dangling into the (now freed) source, the clone's next pump — which walks
    # working memory and the TMS justifier table — would use-after-free.
    del src
    clone.assert_("Motion", entity_id="garage", state=1)
    clone.pump()
    assert len(clone.facts) == 8, len(clone.facts)


def test_clone_of_empty_engine_is_independent():
    """A clone taken before any rule fires is still an independent, working engine.

    This exercises the no-tokens / empty-agenda clone path.
    """
    src = pyds.from_source(_SRC)
    clone = src.clone()

    src_alerts: list[str] = []
    clone_alerts: list[str] = []
    capture_critical(src, src_alerts)
    capture_critical(clone, clone_alerts)

    _sensor(clone, "x", 80)
    assert clone_alerts == ["alarm x"]
    assert src_alerts == []  # clone activity never touched the source
    assert len(src.facts) == 0


def test_a_clone_does_not_call_the_source_s_handlers():
    """A clone starts with none of the source's callbacks ([NLFC.8.3]).

    The source's log handler is registered BEFORE the clone is taken, and none is
    registered on the clone, so the clone's firing reaches no Python code: it
    must not land in the source's list. pyds does no clearing of its own;
    this holds because libds starts the clone empty.
    """
    src = pyds.from_source(_SRC)
    src_alerts: list[str] = []
    capture_critical(src, src_alerts)
    clone = src.clone()

    _sensor(clone, "x", 80)
    assert len(clone.facts) == 2  # Sensor x, and the Alarm its firing emitted
    assert src_alerts == []

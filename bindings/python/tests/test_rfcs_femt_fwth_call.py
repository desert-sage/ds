# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""FactEmit, FactWithdraw and CallIssued, as libds's recorder writes them.

The C recorder writes a rule's emit as a FactEmit, an engine withdrawal as a
FactWithdraw and an outbound call as a CallIssued. These read a real C
recording through libds's reader (`pyds.atoms`) and each atom's generated
message.
"""

import pyds
from pyds import AtomKind, atoms

_SEC = 1_000_000_000

_PROGRAM = """
schema FooReply scope ttl 1_min:
    corr: String
    ok: Bool

service svc.foo:
    "test stub"
    kwarg level: Float
    kwarg tag: String
    response FooReply

schema Reading scope logical:
    entity_id: String key
    level: Float mutable

schema Alarm scope ttl 5_s:
    entity_id: String
    level: Float

schema Hot scope logical:
    entity_id: String key

rule hot:
    Reading r where r.level > 80.0
->
    emit Hot logical entity_id: r.entity_id

rule alarm:
    Reading r where r.level > 90.0
->
    emit Alarm entity_id: r.entity_id level: r.level
    call svc.foo level: r.level tag: "hot" nocooldown as r.entity_id

rule answered:
    FooReply c
->
    log info "reply {c.corr}"
"""


def _recording(tmp_path) -> list:
    """Record emits, three withdrawal causes, a call and its reply, as libds's atoms."""
    eng = pyds.from_source(_PROGRAM)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    eng.set_call_callback(lambda *a, **k: None)
    path = tmp_path / "run.dstrace"
    with eng.record(path):
        eng.assert_("Reading", entity_id="a", level=85.0)
        eng.pump()
        b = eng.assert_("Reading", entity_id="b", level=95.0)
        eng.pump()
        for _ in range(7):  # Alarm b's TTL runs out: TTL_EXPIRED
            eng.clock.advance(_SEC)
            eng.pump()
        eng.assert_("FooReply", corr="b", ok=True)
        eng.pump()
        eng.assert_("Reading", entity_id="a", level=70.0)  # SUPERSEDED, JUSTIFIER_ENDED
        eng.pump()
        eng.retract(b)
        eng.pump()
    return list(atoms.iter_atoms(path.read_bytes()))


def _enum_name(msg, field: str) -> str:
    value = getattr(msg, field)
    return msg.DESCRIPTOR.fields_by_name[field].enum_type.values_by_number[value].name


def test_a_c_recording_carries_all_three(tmp_path):
    seen = {a.kind for a in _recording(tmp_path)}
    assert {AtomKind.FACT_EMIT, AtomKind.FACT_WITHDRAW, AtomKind.CALL_ISSUED} <= seen, seen


def test_fact_withdraw_causes_read_by_name(tmp_path):
    causes = {
        _enum_name(a.message(), "cause")
        for a in _recording(tmp_path)
        if a.kind is AtomKind.FACT_WITHDRAW
    }
    assert {"TTL_EXPIRED", "SUPERSEDED", "JUSTIFIER_ENDED"} <= causes, causes


def test_a_recorded_call_carries_its_typed_arguments(tmp_path):
    calls = [a.message() for a in _recording(tmp_path) if a.kind is AtomKind.CALL_ISSUED]
    got = [
        (
            c.service,
            c.correlation,
            [
                (arg.name, _enum_name(arg, "kind"), getattr(arg, arg.WhichOneof("value")))
                for arg in c.args
            ],
        )
        for c in calls
    ]
    assert got == [
        ("svc.foo", "b", [("level", "KIND_FLOAT", 95.0), ("tag", "KIND_STRING", "hot")]),
    ], got

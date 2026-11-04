# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""libds's replayer, given libds's own recordings and edits of them.

Every stream here starts as what libds's recorder wrote (`Engine.record`). A
stream that must break a rule (an unannounced schema, a fire or call with no
counterpart) is that recording with one atom taken out or added, through
libds's framing (`pyds.atoms.frame`) and the generated message. No second
codec writes any of it.
"""

import pytest

import pyds
from pyds import AtomKind, atoms

_SRC = """
schema Ping scope logical:
    name: String key
    n: Int mutable
"""

# A different program, so its DSC hashes differently (RBND.1.3).
_OTHER_SRC = """
schema Pong scope logical:
    label: String key
"""


def _record(tmp_path, src, run, name="run.dstrace"):
    """Return what libds's recorder writes while ``run(eng)`` runs, on the mock clock."""
    path = tmp_path / name
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    with eng.record(path):
        run(eng)
    return path.read_bytes()


def _pings(tmp_path, facts, name="run.dstrace"):
    """Record one Ping assert per ``(name, n)``."""

    def run(eng):
        for label, value in facts:
            eng.assert_("Ping", name=label, n=value)

    return _record(tmp_path, _SRC, run, name)


def _last_seq(stream):
    """Return the highest ``seq`` any atom of ``stream`` carries."""
    seqs = [
        a.message().seq
        for a in atoms.iter_atoms(stream)
        if isinstance(a.kind, AtomKind) and "seq" in a.message().DESCRIPTOR.fields_by_name
    ]
    return max(seqs)


def _empty(kind):
    """Return an empty message of ``kind``'s generated class, to fill in."""
    return atoms.Atom(kind, b"", 0, 0).message()


def test_c_refuses_a_fact_assert_no_schema_def_announced(tmp_path):
    """The C replayer refuses a FactAssert no SchemaDef announced ([RFCS.5.4]).

    This is [RFCS.5.4]'s first case: the reader holds Ping, and the stream
    asserts it without announcing it ([RFCS.5.3]). The C replayer refuses the
    FactAssert with DS_ERR_SCHEMA_UNKNOWN and applies nothing. The stream is
    libds's recording with Ping's SchemaDef and Slot atoms taken out; the same
    recording whole is test_c_replays_libds_s_recording.
    """
    stream = _pings(tmp_path, [("a", 1)])
    kept = [
        stream[a.offset : a.end]
        for a in atoms.iter_atoms(stream)
        if not (
            a.kind in (AtomKind.SCHEMA_DEF, AtomKind.SLOT) and a.message().schema_name == "Ping"
        )
    ]
    unannounced = b"".join(kept)
    assert len(unannounced) < len(stream), "the recording announced Ping"

    reader = pyds.from_source(_SRC)
    with pytest.raises(pyds.Error) as refused:
        reader.replay(unannounced)
    assert refused.value.status is pyds.Status.SCHEMA_UNKNOWN, refused.value
    assert "no SchemaDef announced" in refused.value.detail, refused.value
    assert len(reader.facts) == 0


def test_c_replays_libds_s_recording(tmp_path):
    stream = _pings(tmp_path, [("a", 1), ("b", 2)])

    reader = pyds.from_source(_SRC)
    res = reader.replay(stream)

    # header_verified is the StreamHeader matching the reader's own loaded DSC.
    assert res.header_verified is True
    assert res.asserts == 2
    assert res.retracts == 0
    assert len(reader.facts) == 2


def test_replay_reports_retracts(tmp_path):
    def run(eng):
        eng.retract(eng.assert_("Ping", name="a", n=1))

    stream = _record(tmp_path, _SRC, run)

    reader = pyds.from_source(_SRC)
    res = reader.replay(stream)
    assert res.asserts == 1
    assert res.retracts == 1
    assert len(reader.facts) == 0


def test_verify_mode_rejects_a_fire_it_cannot_re_derive(tmp_path):
    # RuleFireAnnotation is a COMPARE atom in verify mode, not merely an
    # informational one: replay re-derives rule fires and matches them against
    # what was recorded. _SRC has no rules, so a recorded RuleFireAnnotation
    # has no counterpart and verify must refuse. This is the determinism check
    # actually checking: a replay that accepted this would be reporting
    # agreement it never established.
    stream = _pings(tmp_path, [("a", 1)])
    fire = _empty(AtomKind.RULE_FIRE_ANNOTATION)
    fire.seq = _last_seq(stream) + 1
    fire.rule_name = "r"
    stream += atoms.frame(AtomKind.RULE_FIRE_ANNOTATION, fire.SerializeToString())

    reader = pyds.from_source(_SRC)
    with pytest.raises(pyds.Error) as refused:
        reader.replay(stream)
    # Refused as a divergence (codec.c's verify_match), not for some other
    # fault in the stream: any pyds.Error would satisfy the `raises` alone.
    assert refused.value.status is pyds.Status.FS_DIVERGENCE, refused.value
    assert "no re-derived counterpart" in refused.value.detail, refused.value


def test_c_refuses_a_stream_recorded_under_a_different_dsc(tmp_path):
    # RBND.1.3: a dsc_hash disagreement between the stream's StreamHeader and
    # the engine's loaded DSC applies nothing past the header.
    stream = _pings(tmp_path, [("a", 1)])

    other = pyds.from_source(_OTHER_SRC)
    with pytest.raises(pyds.Error):
        other.replay(stream)
    assert len(other.facts) == 0


def test_two_replays_on_one_engine_keep_both_arenas(tmp_path):
    # Each call gets its own decode arena, and the engine goes on reading
    # String slots after both. A single reused (or freed) arena would leave
    # the first replay's facts pointing at released memory, which is why
    # memcheck is the gate that matters for this one.
    first = _pings(tmp_path, [("first", 1)], "first.dstrace")
    second = _pings(tmp_path, [("second", 2)], "second.dstrace")

    reader = pyds.from_source(_SRC)
    assert reader.replay(first).asserts == 1
    assert reader.replay(second).asserts == 1
    assert len(reader.facts) == 2

    # Force a collection: if the first arena were reachable only through a
    # dropped local it would go here, and the surviving fact would dangle.
    import gc

    gc.collect()
    assert len(reader.facts) == 2


def test_there_is_no_apply_only_replay(tmp_path):
    """Replay is one operation; asking for an apply-only replay is an error ([LFST.9.6]).

    "Rebuilding working memory by
    re-applying recorded events, without running the engine, is not a mode of
    this operation and is not a second one". `replay` takes no `hydrate`
    argument, and libds has no entry point for such a mode. Asking for it is an
    error, not a silent replay.
    """
    stream = _pings(tmp_path, [("a", 1)])

    reader = pyds.from_source(_SRC)
    with pytest.raises(TypeError):
        reader.replay(stream, hydrate=True)
    assert len(reader.facts) == 0


def test_verify_mode_rejects_a_call_it_cannot_re_derive(tmp_path):
    # The CallIssued analogue of test_verify_mode_rejects_a_fire_it_cannot_re_derive.
    # CallIssued is a COMPARE atom in verify mode exactly as
    # RuleFireAnnotation is ([RFCS.15.4]; codec.c's replay loop sends it to
    # verify_match). _SRC declares no service and no rule, so a recorded call
    # has no re-derived counterpart and verify must refuse it as a divergence.
    stream = _pings(tmp_path, [("a", 1)])
    call = _empty(AtomKind.CALL_ISSUED)
    call.seq = _last_seq(stream) + 1
    call.rule_name = "r"
    call.service = "svc.thing"
    call.correlation = "corr-1"
    stream += atoms.frame(AtomKind.CALL_ISSUED, call.SerializeToString())

    reader = pyds.from_source(_SRC)
    with pytest.raises(pyds.Error) as refused:
        reader.replay(stream)
    assert refused.value.status is pyds.Status.FS_DIVERGENCE, refused.value
    assert "no re-derived counterpart" in refused.value.detail, refused.value


_NOW_SRC = """
schema S scope logical:
    entity_id: String key

schema Seen scope logical:
    k: String key

rule stamp:
    S
->
    let t = now()
    log info "stamp {t}"
    emit Seen logical k: "a"
"""


def test_an_unset_wall_clock_replays_to_the_same_domain_fault(tmp_path):
    """An unset wall clock replays to the same DOMAIN fault ([RFCS.10.1], [RFCS.10.5]).

    A recording made before the wall clock was set carries has_wall false, and
    the C replayer restores the wall clock
    as UNSET, so the replayed now() is the same DOMAIN computation error
    ([LTIM.2.8.3]) and not a read of the epoch.

    The recording is the C recorder's own, on the mock clock with the wall
    clock never set. The rule's `let` faults before any action runs, so the
    activation is abandoned and `Seen` is never emitted -- in the run, and
    in a faithful replay. A replayer that set the wall clock to the epoch
    would read `now()`, run the actions and emit `Seen`, which the writer
    never had. The fault itself is a fact on both sides.
    """
    path = tmp_path / "unset_wall.dstrace"
    writer = pyds.from_source(_NOW_SRC)
    writer.clock.mode = "mock"
    with writer.record(path):
        writer.assert_("S", entity_id="a")
        writer.pump()
    stream = path.read_bytes()
    assert writer.facts.of("Seen") == [], "the run abandoned the activation"
    assert len(writer.facts.of("ComputationError")) == 1

    recorded = list(atoms.iter_atoms(stream))
    clka = [a.message() for a in recorded if a.kind is AtomKind.CLOCK_ADVANCE]
    assert clka and not any(c.has_wall for c in clka), clka
    assert AtomKind.COMPUTATION_ERROR in [a.kind for a in recorded]

    reader = pyds.from_source(_NOW_SRC)
    res = reader.replay(stream)
    # `asserts` counts the input the replayer injects and the emitted facts it
    # compares: here S, and the fault fact the run emitted.
    assert res.asserts == 2 and res.clocks >= 1, res
    assert reader.facts.of("Seen") == [], "the replay read a wall clock the run did not have"
    assert len(reader.facts) == len(writer.facts)


def test_a_recording_attached_after_the_first_pump_is_refused(tmp_path):
    """A recording attached after the first pump is refused ([LTIM.2.8.5], [LFST.5.3]).

    A recording is complete only if its stream callback is attached before the
    engine's first input or sample. Here the
    writer pumps once (its first sample, and the events that go with it take
    seq 0 and up) and only then starts recording, so the recording's first
    event has a seq above 0, and the C replayer refuses it with
    DS_ERR_FS_RECORDING_INCOMPLETE (-729) rather than replaying a run that
    lacks its start. Drives the seen_event check in codec.c's
    replay_apply_atom.
    """
    path = tmp_path / "late.dstrace"
    writer = pyds.from_source(_SRC)
    writer.clock.mode = "mock"
    writer.pump()
    with writer.record(path):
        writer.assert_("Ping", name="a", n=1)
        writer.pump()
    stream = path.read_bytes()

    reader = pyds.from_source(_SRC)
    with pytest.raises(pyds.TraceError) as refused:
        reader.replay(stream)
    assert refused.value.status is pyds.Status.FS_RECORDING_INCOMPLETE
    assert len(reader.facts) == 0, "nothing was delivered"

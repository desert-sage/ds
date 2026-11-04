# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""What libds's recorder writes, read back through libds's reader.

Each recording here is the C recorder's own (`Engine.record`), and each atom
is read with `pyds.atoms`, libds's reader, and the generated message. A fact
body is typed by libds against the loaded artefact
(`Engine.decode_fact_body`). No Python codec reads any of it.

The schema is compiled, as every schema an engine holds is ([NFCT.1.1]: "A
schema reaches the engine from a compiled artefact, and in no other way"). The
prelude announces the artefact's built-in schemas beside it ([LIMP.12.2]), so
these tests pick `Pkt`'s atoms out by name.
"""

import struct

import pytest

import pyds
from pyds import AtomKind, atoms

_PKT_DS = """use default

schema Pkt scope logical:
    n: Int key
    tag: String key
"""


def _record_pkt(tmp_path):
    """Load Pkt and record an assert and a retract through the C recorder.

    Return (engine, stream_bytes, declared slots). Mirrors the C fixture in
    runtime/tests/libds/impl/test_rfcs_record.c, so a disagreement between the
    two is a reading difference and not a scenario difference.
    """
    eng = pyds.from_source(_PKT_DS)

    # THE MOCK CLOCK, so the clock records are a fact of the scenario: the
    # assert takes the engine's first sample, recorded as a ClockAdvance before
    # it ([LTIM.2.8.5]), and the retract's sample is unchanged, so it records
    # none. On the live clock the second ClockAdvance would depend on whether
    # the host clock moved between two calls.
    eng.clock.mode = "mock"
    path = tmp_path / "pkt.dstrace"
    with eng.record(path):
        fact = eng.assert_("Pkt", n=42, tag="hi")
        eng.retract(fact)

    declared = [(s.name, s.type.name) for s in eng.schemas["Pkt"].slots]
    return eng, path.read_bytes(), declared


_NAN_CALL_DS = """use default

service svc.diff:
    kwarg v: Float
    no response

service svc.big:
    kwarg w: Float
    no response

schema Trig scope logical:
    k: Int key
    a: Float mutable

rule r:
    Trig t
->
    call svc.diff v: t.a * 10.0 - t.a * 10.0 nocooldown
    call svc.big w: t.a * 10.0 nocooldown
"""


def _nan_call_engine():
    eng = pyds.from_source(_NAN_CALL_DS)
    eng.clock.mode = "mock"
    eng.set_call_callback(lambda req: None)
    return eng


def test_rfcs_6_7__a_nan_refused_call_replays_past_its_pump(tmp_path):
    """[RFCS.6.7]: a pump's DS_ERR_NAN_REJECTED is an outcome.

    a=1e308 makes `svc.diff`'s argument Inf - Inf, so that call is refused and
    the pump reports it; the run goes on to a=2.0. The later firing is in the
    recording, so a replay that stopped at the status compares one firing and
    returns -216. PATH PINNED: rfcs/codec.c's PumpBoundary arm.
    """
    eng = _nan_call_engine()
    path = tmp_path / "nan.dstrace"
    with eng.record(path):
        eng.assert_("Trig", k=1, a=1e308)
        with pytest.raises(pyds.Error) as refused:
            eng.pump()
        assert refused.value.status is pyds.Status.NAN_REJECTED
        eng.assert_("Trig", k=2, a=2.0)
        eng.pump()

    res = pyds.from_source(_NAN_CALL_DS).replay(path.read_bytes())

    assert (res.asserts, res.calls) == (2, 3)


def test_rfcs_6_7__a_recorded_call_the_replay_refuses_diverges(tmp_path):
    """[RFCS.6.7]: the compare decides, not the pump's status.

    The run asserts a=2.0, so both calls are issued. Its recording is edited to
    a=1e308, so the replay refuses `svc.diff`, which the recording holds. PATH
    PINNED: the PumpBoundary arm goes on, and the CallIssued compare refuses.
    """
    eng = _nan_call_engine()
    path = tmp_path / "nan.dstrace"
    with eng.record(path):
        eng.assert_("Trig", k=1, a=2.0)
        eng.pump()
    stream = path.read_bytes()
    recorded, edited = struct.pack("<d", 2.0), struct.pack("<d", 1e308)
    assert stream.count(recorded) == 1

    with pytest.raises(pyds.TraceError) as diverged:
        pyds.from_source(_NAN_CALL_DS).replay(stream.replace(recorded, edited))

    assert diverged.value.status is pyds.Status.FS_DIVERGENCE


def _slot_kind(slot) -> str:
    """Return a Slot message's kind as the engine names a slot type (``INT``)."""
    name = slot.DESCRIPTOR.fields_by_name["kind"].enum_type.values_by_number[slot.kind].name
    return name.removeprefix("SLOT_KIND_")


def _messages(stream, kind):
    return [a.message() for a in atoms.iter_atoms(stream) if a.kind is kind]


def test_libds_s_recording_reads_through_libds_s_reader(tmp_path):
    """A recording libds made reads back through libds's reader as it was recorded.

    [RFCS.4.1] the StreamHeader first, [LDET.1.10] its ds_version, Pkt's
    SchemaDef carrying the compiler's .proto text ([RFCS.12.3]), the FactAssert
    body typed by libds back to the values asserted, and the retract naming the
    fact the assert asserted.
    """
    eng, stream, _ = _record_pkt(tmp_path)
    recorded = list(atoms.iter_atoms(stream))

    assert recorded[0].kind is AtomKind.STREAM_HEADER
    # Compared against the ENGINE's own report rather than a literal: they are
    # the same string by construction, and a literal would fail on every
    # release instead of catching a writer that stamps nothing.
    header = recorded[0].message()
    assert header.ds_version == pyds.Engine().session_header.ds_version != ""

    (sdef,) = [m for m in _messages(stream, AtomKind.SCHEMA_DEF) if m.schema_name == "Pkt"]
    assert b"message Pkt" in sdef.proto_source

    (fa,) = _messages(stream, AtomKind.FACT_ASSERT)
    assert fa.schema_name == "Pkt"
    assert eng.decode_fact_body("Pkt", fa.fact) == {"n": 42, "tag": "hi"}

    (fr,) = _messages(stream, AtomKind.FACT_RETRACT)
    assert fr.fact_id == fa.fact_id


def test_libds_s_slot_atoms_describe_the_schema(tmp_path):
    """The Slot atoms say what the engine itself says the schema is ([RFCS.5.1]).

    That is names, kinds and DECLARATION ORDER. Order is not cosmetic: fact-body
    field numbers are assigned 1..N in it, so a reordered announcement would
    mistype every fact that followed.
    """
    _, stream, declared = _record_pkt(tmp_path)

    slots = [s for s in _messages(stream, AtomKind.SLOT) if s.schema_name == "Pkt"]
    assert [(s.slot_name, _slot_kind(s)) for s in slots] == declared


def test_temporal_kinds_are_announced_and_recorded(tmp_path):
    """Time, Date and Duration are slot kinds of their own, each Int-represented (RDSC.5.5.8).

    A schema declaring all three takes an int for each; the
    engine reports each under its own kind; the C recorder announces those
    kinds in its Slot atoms ([RFCS.5.1]); and libds types the recorded body
    back to the same ints.
    """
    eng = pyds.from_source(
        "use default\n\n"
        "schema Visit scope ttl 1_min:\n"
        "    seen: Time\n"
        "    due: Date\n"
        "    span: Duration\n"
    )
    declared = [(s.name, s.type.name) for s in eng.schemas["Visit"].slots]
    assert declared == [("seen", "TIME"), ("due", "DATE"), ("span", "DURATION")]

    eng.clock.mode = "mock"
    path = tmp_path / "visit.dstrace"
    values = {"seen": 1_760_000_000_000_000_000, "due": 20_372, "span": 90_000_000_000}
    with eng.record(path):
        eng.assert_("Visit", **values)
    stream = path.read_bytes()

    visit = [s for s in _messages(stream, AtomKind.SLOT) if s.schema_name == "Visit"]
    assert [(s.slot_name, _slot_kind(s)) for s in visit] == declared

    (fa,) = _messages(stream, AtomKind.FACT_ASSERT)
    assert eng.decode_fact_body("Visit", fa.fact) == values


def test_atom_sequence_is_exactly_what_the_c_recorder_emits(tmp_path):
    """The C recorder's framing and ORDER, pinned independently of body decoding.

    The header, then the prelude -- nothing but SchemaDefs, each followed by its
    own Slots, Pkt's two among them -- then the run's three records, exactly.
    """
    _, stream, _ = _record_pkt(tmp_path)
    recorded = list(atoms.iter_atoms(stream))
    kinds = [a.kind for a in recorded]

    assert kinds[0] is AtomKind.STREAM_HEADER
    end = 1
    while end < len(kinds) and kinds[end] in (AtomKind.SCHEMA_DEF, AtomKind.SLOT):
        end += 1
    prelude = recorded[1:end]
    assert prelude and prelude[0].kind is AtomKind.SCHEMA_DEF
    pkt = [
        i
        for i, a in enumerate(prelude)
        if a.kind is AtomKind.SCHEMA_DEF and a.message().schema_name == "Pkt"
    ]
    assert len(pkt) == 1
    assert [a.kind for a in prelude[pkt[0] : pkt[0] + 3]] == [
        AtomKind.SCHEMA_DEF,
        AtomKind.SLOT,
        AtomKind.SLOT,
    ]
    assert kinds[end:] == [
        # The assert's sample: announced schemas come at record_begin, the
        # clock record with the first input ([LTIM.2.8.5]).
        AtomKind.CLOCK_ADVANCE,
        AtomKind.FACT_ASSERT,
        AtomKind.FACT_RETRACT,
    ]


_SHARE_DS = """
schema Trig scope logical:
    k: String key
    v: Int mutable

schema Derived scope logical:
    k: String key

rule derive:
    Trig t where t.v > 1
->
    emit Derived logical k: t.k
"""


def _share_run(eng) -> None:
    eng.clock.mode = "mock"
    eng.clock.set(0)
    eng.assert_("Trig", k="a", v=2)
    eng.pump()
    eng.assert_("Trig", k="a", v=0)  # supersedes; Derived's support ends
    eng.pump()


def _bodies(path):
    return [(a.kind, a.body) for a in atoms.iter_atoms(path.read_bytes())]


def test_a_recording_and_a_stream_callback_share_the_slot(tmp_path):
    """The recorder and a Python stream callback both hear every event.

    The recording is byte-identical to one made with no callback, and
    the callback sees what it sees with no recording. Either may be set first,
    and the callback can be swapped or removed mid-recording.
    """
    plain = tmp_path / "plain.dstrace"
    alone = pyds.from_source(_SHARE_DS)
    with alone.record(plain):
        _share_run(alone)

    heard_alone: list[str] = []
    solo = pyds.from_source(_SHARE_DS)
    solo.on_event = lambda ev: heard_alone.append(ev.kind)
    _share_run(solo)

    shared = tmp_path / "shared.dstrace"
    heard: list[str] = []
    eng = pyds.from_source(_SHARE_DS)
    eng.on_event = lambda ev: heard.append(ev.kind)  # first
    with eng.record(shared):  # then
        _share_run(eng)

    # Every atom byte for byte, the header and each event_id included: the
    # engine mints no session id, and these engines are given no run id or
    # tier id, so nothing in a recording depends on which engine made it
    # ([NLFC.1.2], [RFCS.4.3]).
    assert _bodies(shared) == _bodies(plain)
    assert heard == heard_alone and "fact_retract" in heard

    # After the recording closes the callback keeps the slot on its own.
    before = len(heard)
    eng.assert_("Trig", k="b", v=5)
    eng.pump()
    assert len(heard) > before

    # Set during a recording: swapped and removed without detaching the recorder.
    later: list[str] = []
    eng2 = pyds.from_source(_SHARE_DS)
    with eng2.record(tmp_path / "later.dstrace"):
        eng2.on_event = lambda ev: later.append(ev.kind)
        _share_run(eng2)
        eng2.on_event = None
    assert later and _bodies(tmp_path / "later.dstrace") == _bodies(plain)

    with eng.record(tmp_path / "x.dstrace"):
        with pytest.raises(RuntimeError, match="already recording"):
            eng.record(tmp_path / "y.dstrace")


def test_flush_makes_a_recording_readable_while_written(tmp_path):
    """With flush=True every atom is on disk when its event returns.

    So a reader can follow the recording before it closes.
    """
    path = tmp_path / "live.dstrace"
    eng = pyds.from_source(_SHARE_DS)
    with eng.record(path, flush=True):
        eng.clock.mode = "mock"
        eng.clock.set(0)
        eng.assert_("Trig", k="a", v=2)
        eng.pump()
        mid = [a.kind for a in atoms.iter_atoms(path.read_bytes())]
        assert AtomKind.FACT_ASSERT in mid and AtomKind.FACT_EMIT in mid


# ---------------------------------------------------------------------------
# A fault atom in libds's recording.
# ---------------------------------------------------------------------------

_TRAP_DIVIDE_BY_ZERO = 1  # proto/engine_error.proto#TrapKind

# Both operands `Int`: only an all-`Int` division by zero traps ([LEXP.7.15.1]).
# With a `Float` operand the division is IEEE 754's and gives `+Inf`.
_DIV_BY_ZERO = """
schema S scope logical:
    entity_id: String key
    a: Int mutable
    b: Int mutable

rule div:
    S s where s.a / s.b > 1.0
->
    log info "fired"
"""


def test_libds_records_a_computation_error(tmp_path):
    """The trap the engine raised reaches the stream as a ComputationError with its cause.

    `b = 0` is a RUNTIME zero -- a literal one is refused at
    compile time ([LEXP.10.2.2]) -- so the trap is raised by the join test.
    """
    eng = pyds.from_source(_DIV_BY_ZERO)
    path = tmp_path / "fault.dstrace"
    with eng.record(path):
        eng.assert_("S", entity_id="a", a=1, b=0)
        eng.pump()

    eerr = _messages(path.read_bytes(), AtomKind.COMPUTATION_ERROR)
    assert eerr, "no ComputationError atom in a run whose only rule divides by zero"
    assert eerr[0].kind == _TRAP_DIVIDE_BY_ZERO
    # `recoverable` is constant across TrapKinds: a ComputationError abandons
    # the activation and leaves the engine intact.
    assert eerr[0].recoverable is True

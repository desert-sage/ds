# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""What the binding owes libds's contracts.

`get_justifiers` releasing libds's arrays with `ds_free` has no test here: the
default build's weak `ds_free` IS `free`, so only a strong allocator override
([IALC.5.1]) could tell the two apart, and pyds links none.
"""

import importlib.util
from pathlib import Path

import pytest

import pyds

# The harness's sealer, loaded by path rather than copied, as
# test_rete_loader_pin.py loads it.
_SEAL = Path(__file__).resolve().parents[3] / "specs" / "conformance" / "harness" / "dsc_seal.py"
_spec = importlib.util.spec_from_file_location("dsc_seal", _SEAL)
_dsc_seal = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_dsc_seal)


_CALL = """
service svc.a:
    kwarg x: Int
    no response

schema P scope logical:
    id: Int key

rule send:
    P p
->
    call svc.a x: p.id nocooldown
"""


def test_a_call_request_carries_the_firing_activation():
    """A call request carries the firing's `timetag` and `rule_name`.

    `ds_call_request_t` carries both, the CallIssued/RuleFireAnnotation join
    key ([RFCS.15]), and so does the dict handed to Python. A rule fired
    the call, so the timetag is not the outside-a-fire 0 and the rule name is
    the rule's.
    """
    eng = pyds.from_source(_CALL)
    calls = []
    eng.set_call_callback(calls.append)
    eng.assert_("P", id=7)
    eng.pump()
    assert len(calls) == 1, calls
    assert calls[0]["rule_name"] == "send", calls[0]
    assert isinstance(calls[0]["timetag"], int)
    assert calls[0]["timetag"] != 0, calls[0]


# A HALT A TEST CAN REACH ON PURPOSE: an artefact that lies. The program does
# arithmetic on an Int slot; the `.dsc` is then edited so that slot's Slot atom
# declares String. The engine holds a String where the compiled rule reads an
# Int, a present value of the wrong type that no Json taint explains, so the
# fault is the artefact's (ARTEFACT_LIED), the EngineError class, and an
# EngineError halts the engine ([LERR.1] rung 7).
#
# It is the artefact, not the language, because every route through the
# language alone is a ComputationError, which does not halt: an unknown
# computed `to_string` format among them. A lying artefact is what rung 7
# exists for.
_HALTS = """
schema P scope logical:
    id: Int key
    lied: Int mutable

rule halt:
    P p where p.lied + 1 > 0
->
    log info "never"
"""

# The Slot atom's `slot_name = "lied"` (field 2) then `kind = SLOT_KIND_INT`
# (field 3, value 1); the lie is the same bytes with SLOT_KIND_STRING (3).
# proto/slot.proto.
_SLOT_INT = b"\x12\x04lied\x18\x01"
_SLOT_STRING = b"\x12\x04lied\x18\x03"


def _lying(dsc: bytes) -> bytes:
    """Return `dsc` with slot `lied` declared String, and resealed.

    The edit is one byte inside one atom, so no length prefix moves; finding
    the bytes exactly once is what says the edit landed where it was meant to.

    A runtime refuses an artefact whose `dsc_sha256` does not match
    ([RDSC.3.6]) before it reads any Slot atom, so the edit is resealed as the
    compiler seals. Otherwise the load is refused for its hash, and the halt
    these tests are about never happens.
    """
    assert dsc.count(_SLOT_INT) == 1, "the Slot atom for `lied` is not where this test expects it"
    lied = dsc.replace(_SLOT_INT, _SLOT_STRING)
    assert _dsc_seal.sha256_offset(lied) is not None, "the artefact has no dsc_sha256 to reseal"
    return _dsc_seal.seal(lied)


def test_closing_a_halted_engine_with_callbacks_is_clean():
    """Teardown of a halted engine frees it before releasing the callables.

    A halted engine refuses every callback setter ([NCBK.2.9]), so teardown
    frees the engine BEFORE releasing the callables rather than trying to
    unregister them first.

    A SMOKE TEST, and it says so: the other order would fail nothing
    observable either, because `ds_engine_free` emits nothing during teardown. What it
    pins is that the halted path closes, stays closed, and leaves the
    callables collectable.
    """
    eng = pyds.Engine()
    eng.load_dsc(_lying(pyds.compile(_HALTS, file="halts.ds")))
    seen = []
    eng.on_event = lambda ev: seen.append("stream")
    eng.set_call_callback(lambda *a: seen.append("call"))
    eng.on_log = lambda record: seen.append("log")
    # The `where` is evaluated as the fact joins, so the halt can surface at
    # the assert as well as at the pump.
    with pytest.raises(pyds.Error) as caught:
        eng.assert_("P", id=1, lied="x")
        eng.pump()
    assert caught.value.status is pyds.Status.ENGINE_HALTED
    eng.close()
    eng.close()  # idempotent
    with pytest.raises(ValueError, match="closed"):
        eng.pump()


def test_halted_reads_the_latch_and_the_fault_that_set_it():
    """`halted` is None while the engine runs, and names the fault after it halts ([NCBK.2.11]).

    After an EngineError it is the same EngineFault the engine_error event
    carried, on an engine that now refuses every call but this one and the
    load-time reads ([NCBK.2.9]).
    """
    eng = pyds.Engine()
    eng.load_dsc(_lying(pyds.compile(_HALTS, file="halts.ds")))
    faults = []

    def on_event(ev):
        if isinstance(ev, pyds.events.EngineError):
            faults.append(ev.engine_fault)

    eng.on_event = on_event
    assert eng.halted is None
    with pytest.raises(pyds.Error) as caught:
        eng.assert_("P", id=1, lied="x")
        eng.pump()
    assert caught.value.status is pyds.Status.ENGINE_HALTED
    assert len(faults) == 1, faults
    assert eng.halted is faults[0]
    # An EngineError's own fault, never UNSPECIFIED, which is a failed load's.
    assert isinstance(eng.halted, pyds.EngineFault)
    assert eng.halted is not pyds.EngineFault.UNSPECIFIED
    eng.close()


# @spec [NCBK.2.11]
def test_ncbk_2_11__a_failed_load_reads_unspecified():
    """An engine a failed load spent reads ``EngineFault.UNSPECIFIED``.

    [RDSC.9.8]: a load that fails once it has begun reading sets the latch;
    [NCBK.2.11]: ``halted`` is then true with no fault, as no EngineError was
    raised. The artefact is a real one with its last byte cut, so the read
    begins and fails. Which refusal stops it is not this test's question,
    only that the engine is spent and says so as a member of the enum.
    CONTROL: test_halted_reads_the_latch_and_the_fault_that_set_it, where an
    EngineError's own fault is read and is not UNSPECIFIED.
    """
    dsc = pyds.compile(_HALTS, file="halts.ds")
    eng = pyds.Engine()
    assert eng.halted is None
    with pytest.raises(pyds.Error):
        eng.load_dsc(dsc[:-1])
    assert eng.halted is pyds.EngineFault.UNSPECIFIED
    with pytest.raises(pyds.Error) as caught:
        eng.load_dsc(dsc)
    assert caught.value.status is pyds.Status.ENGINE_HALTED
    eng.close()


def test_halted_answers_without_a_stream_callback():
    """An integrator that saw no event can still learn the halt's cause.

    That is the point of the read: one that learned of the halt only from
    [-10] reads its cause here.
    """
    eng = pyds.Engine()
    eng.load_dsc(_lying(pyds.compile(_HALTS, file="halts.ds")))
    with pytest.raises(pyds.Error) as caught:
        eng.assert_("P", id=1, lied="x")
        eng.pump()
    assert caught.value.status is pyds.Status.ENGINE_HALTED
    assert isinstance(eng.halted, pyds.EngineFault)
    eng.close()

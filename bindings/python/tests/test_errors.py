# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A libds status is an attribute, and its range a class.

`pyds.Status` is `proto/status.proto`'s `DsStatus`: the number is the identity
and the name a label ([STYL.2.13.3]). A libds failure raises `pyds.Error`, or
the subclass for its range of [NERR.3.1], carrying `.status` and `.detail`, so
a caller catches the failure they mean without reading the message. Python
misuse raises the builtin for it; a closed engine is ValueError, as a closed
file is.
"""

from __future__ import annotations

import pickle

import pytest

import pyds
from pyds import Status, atoms
from pyds.errors import _error_for

# [NERR.3.1]'s ranges, stated here as this test's own reference rather than read
# from the module under test. The fact-stream row runs to -730, as [NERR.3.1]
# and [NERR.13] state (DS_ERR_FS_UNKNOWN_FACT_ID).
FAMILIES = [
    (range(-199, -99), "InputError"),
    (range(-299, -199), "ExecutionError"),
    (range(-499, -399), "StorageError"),
    (range(-599, -499), "LoadError"),
    (range(-610, -599), "ReteError"),
    (range(-625, -619), "BackendError"),
    (range(-704, -699), "ArtefactMismatchError"),
    (range(-714, -709), "ContractError"),
    (range(-730, -719), "TraceError"),
]


def _family(n: int) -> type:
    for numbers, name in FAMILIES:
        if n in numbers:
            return getattr(pyds, name)
    return pyds.Error


def test_status_is_the_proto_dictionary():
    assert Status.OK == 0
    assert Status.WM_FULL == -606
    assert Status(-606) is Status.WM_FULL
    assert isinstance(Status.WM_FULL, int)
    with pytest.raises(ValueError):
        Status(-204)  # retired: DS_ERR_CLIPS_ERROR, never reused


@pytest.mark.parametrize("status", [s for s in Status if s is not Status.OK], ids=lambda s: s.name)
def test_every_status_raises_its_family(status):
    e = _error_for(int(status), "detail")
    assert type(e) is _family(int(status))
    assert e.status is status
    assert e.detail == "detail"
    assert str(e) == f"[{int(status)} {status.name}] detail"


def test_a_status_outside_the_dictionary_is_kept_as_an_int():
    e = _error_for(-10001, "the integrator's own")
    assert type(e) is pyds.Error
    assert e.status == -10001 and not isinstance(e.status, Status)
    assert str(e) == "[-10001] the integrator's own"


def test_every_family_is_an_error():
    for _, name in FAMILIES:
        assert issubclass(getattr(pyds, name), pyds.Error), name
    assert issubclass(pyds.CompileRefusedError, pyds.Error)
    assert pyds.CompileRefusedError("a.ds", "diagnostics").status is None


def test_the_input_family_is_named_for_its_category():
    """The -100..-199 band's family is InputError, named for its category ([NERR.3.1]).

    [NERR.3.1] names the band Input, and a binding names each family type for
    its category. No other name for it exists.
    """
    assert pyds.InputError.__name__ == "InputError"
    assert not hasattr(pyds, "CompileError")
    assert not hasattr(pyds.errors, "CompileError")


def test_errors_survive_pickling():
    e = _error_for(-606, "full")
    f = pickle.loads(pickle.dumps(e))
    assert (type(f), f.status, f.detail) == (type(e), e.status, e.detail)
    r = pickle.loads(pickle.dumps(pyds.CompileRefusedError("a.ds", "DS_X at 1:1")))
    assert (r.file, r.diagnostics, r.status) == ("a.ds", "DS_X at 1:1", None)


def test_a_bad_artefact_raises_load_error():
    with pytest.raises(pyds.LoadError) as caught:
        pyds.Engine().load_dsc(b"not a dsc")
    e = caught.value
    assert isinstance(e.status, Status) and -599 <= e.status <= -500
    assert str(e).startswith(f"[{int(e.status)} {e.status.name}] ")


def test_a_generic_failure_raises_error_itself():
    eng = pyds.Engine()
    eng.clock.mode = "live"
    with pytest.raises(pyds.Error) as caught:
        eng.clock.set(5)  # mock mode only
    assert type(caught.value) is pyds.Error
    assert caught.value.status is Status.STATE


@pytest.mark.parametrize(
    "call",
    [
        lambda e: e.pump(),
        lambda e: len(e.facts),
        lambda e: e.facts[1],
        lambda e: 1 in e.facts,
        lambda e: list(e.facts),
        lambda e: e.facts.of("Absent"),
        lambda e: e.halted,
        lambda e: e.platform_signature,
        lambda e: e.session_header,
        lambda e: e.memory_usage(),
        lambda e: e.clock.set_wall(0),
        lambda e: setattr(e, "on_event", print),
        lambda e: setattr(e, "on_log", print),
        lambda e: setattr(e, "on_cache_set", print),
    ],
    ids=[
        "pump",
        "len(facts)",
        "facts[id]",
        "id in facts",
        "iter(facts)",
        "facts.of",
        "halted",
        "platform_signature",
        "session_header",
        "memory_usage",
        "clock.set_wall",
        "on_event",
        "on_log",
        "on_cache_set",
    ],
)
def test_a_closed_engine_raises_value_error(call):
    """A closed engine refuses as io refuses a closed file: ValueError, with no status.

    halted and clock.set_wall are here because they raised
    RuntimeError("Engine not initialised") instead.
    """
    eng = pyds.Engine()
    eng.close()
    with pytest.raises(ValueError, match="operation on a closed Engine"):
        call(eng)


def test_a_malformed_atom_carries_its_status():
    with pytest.raises(pyds.Error, match="at byte 0") as caught:
        list(atoms.iter_atoms(b"\x0a\x05\x01"))  # a frame promising 5 bytes, holding 1
    assert caught.value.status is Status.PARSE
    with pytest.raises(pyds.Error, match="at byte 0") as caught:
        atoms.wire_fields(b"\x0a\x05")
    assert caught.value.status is Status.PARSE

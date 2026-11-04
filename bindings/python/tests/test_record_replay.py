# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Recording an engine's fact stream, and replaying one.

``record`` returns a ``Recording``, which closes as ``open()``'s file does:
by ``close()`` or at the end of a ``with`` block. ``replay`` returns a frozen
``ReplayResult``.
"""

import dataclasses

import pytest

import pyds

_SRC = """
schema Ping scope logical:
    name: String key
    n: Int mutable
"""


def _asserts(path):
    """How many asserts a fresh engine replays from the recording at path."""
    return pyds.from_source(_SRC).replay(path.read_bytes()).asserts


def test_a_recording_closes_at_the_end_of_a_with_block(tmp_path):
    eng = pyds.from_source(_SRC)
    path = tmp_path / "run.dstrace"
    with eng.record(path) as recording:
        assert isinstance(recording, pyds.Recording)
        assert not recording.closed
        eng.assert_("Ping", name="a", n=1)
    assert recording.closed
    assert _asserts(path) == 1


def test_record_takes_a_str_path_as_well(tmp_path):
    eng = pyds.from_source(_SRC)
    path = tmp_path / "run.dstrace"
    recording = eng.record(str(path))
    eng.assert_("Ping", name="a", n=1)
    recording.close()
    recording.close()  # idempotent
    assert recording.path == path
    assert _asserts(path) == 1


def test_a_second_recording_while_one_runs_is_refused(tmp_path):
    eng = pyds.from_source(_SRC)
    with eng.record(tmp_path / "a.dstrace"):
        with pytest.raises(RuntimeError, match="already recording"):
            eng.record(tmp_path / "b.dstrace")


def test_closing_a_finished_recording_leaves_a_later_one_running(tmp_path):
    eng = pyds.from_source(_SRC)
    first = eng.record(tmp_path / "a.dstrace")
    first.close()
    second = eng.record(tmp_path / "b.dstrace")
    first.close()  # its recording is over
    assert not second.closed
    eng.assert_("Ping", name="b", n=2)
    second.close()
    assert _asserts(tmp_path / "b.dstrace") == 1


def test_replay_returns_a_frozen_result(tmp_path):
    writer = pyds.from_source(_SRC)
    path = tmp_path / "run.dstrace"
    with writer.record(path):
        writer.assert_("Ping", name="a", n=1)
        writer.assert_("Ping", name="b", n=2)

    result = pyds.from_source(_SRC).replay(path.read_bytes())
    assert isinstance(result, pyds.ReplayResult)
    assert result.asserts == 2
    assert result.header_verified is True
    with pytest.raises(dataclasses.FrozenInstanceError):
        result.asserts = 0  # type: ignore[misc]  # the assignment under test


def test_replay_refuses_a_chunk_size_below_one():
    eng = pyds.from_source(_SRC)
    with pytest.raises(ValueError, match="chunk_size"):
        eng.replay(b"", chunk_size=0)


def test_the_old_spellings_are_gone():
    eng = pyds.Engine()
    for name in ("record_to", "stop_recording", "replay_stream"):
        assert not hasattr(eng, name), name

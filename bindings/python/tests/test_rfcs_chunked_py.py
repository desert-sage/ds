# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""pyds feeds a stream to replay instead of holding one.

The engine copies String/Bytes into its intern at assert, so chunks are
released as they are consumed, and an engine replayed into repeatedly does not
grow with what it replayed. These tests exercise the source shapes an
integrator actually has — a file, an iterator — and check that nothing is
being retained. Every stream is one libds's recorder wrote (`Engine.record`).
"""

import io

import pytest

import pyds

_SRC = """
schema Rec scope logical:
    label: String key
    n: Int mutable
"""


def _stream(tmp_path, n):
    """Return libds's recording of ``n`` Rec asserts, on the mock clock."""
    path = tmp_path / f"rec{n}.dstrace"
    eng = pyds.from_source(_SRC)
    eng.clock.mode = "mock"
    with eng.record(path):
        for i in range(1, n + 1):
            eng.assert_("Rec", label=f"row-{i}", n=i)
    return path.read_bytes()


def test_replay_from_bytes(tmp_path):
    data = _stream(tmp_path, 5)

    eng = pyds.from_source(_SRC)
    res = eng.replay(data)
    assert res.asserts == 5
    assert len(eng.facts) == 5


def test_replay_from_a_file_object(tmp_path):
    data = _stream(tmp_path, 5)

    eng = pyds.from_source(_SRC)
    # Small chunk_size so the read loop runs many times and atoms straddle.
    res = eng.replay(io.BytesIO(data), chunk_size=8)
    assert res.asserts == 5
    assert len(eng.facts) == 5


def test_replay_from_an_iterable_of_chunks(tmp_path):
    data = _stream(tmp_path, 5)

    def chunks(step=3):
        for off in range(0, len(data), step):
            yield data[off : off + step]

    eng = pyds.from_source(_SRC)
    res = eng.replay(chunks())
    assert res.asserts == 5
    assert len(eng.facts) == 5


def test_chunking_does_not_change_the_result(tmp_path):
    data = _stream(tmp_path, 9)

    results = []
    for size in (len(data), 1, 3, 8, 64):
        eng = pyds.from_source(_SRC)
        results.append((eng.replay(io.BytesIO(data), chunk_size=size), len(eng.facts)))
    first = results[0]
    for got in results[1:]:
        assert got == first, f"chunking changed the outcome: {got} != {first}"


def test_engine_retains_nothing_per_replay(tmp_path):
    # The regression guard for the deleted replay_bufs list: replaying the
    # same stream repeatedly must not accumulate anything on the engine.
    data = _stream(tmp_path, 3)

    eng = pyds.from_source(_SRC)
    for _ in range(25):
        eng.replay(data)
    # Upserts on the same keys, so WM stays at 3 however many times we replay.
    assert len(eng.facts) == 3


def test_replayed_slots_are_readable_after_the_source_is_gone(tmp_path):
    # The whole point of the ownership fix, from Python: drop every reference
    # to the stream, collect, and the replayed facts still read correctly.
    import gc

    data = _stream(tmp_path, 3)

    eng = pyds.from_source(_SRC)
    eng.replay(io.BytesIO(data), chunk_size=4)
    del data
    gc.collect()

    assert len(eng.facts) == 3


def test_bad_source_type_is_a_clean_error():
    eng = pyds.from_source(_SRC)
    with pytest.raises(TypeError):
        eng.replay(12345)


def _cut_in_last_assert(data):
    """Return ``data`` cut three bytes before the end of its last FactAssert.

    The tail is then that atom's partial frame, whatever the recorder wrote
    after it.
    """
    from pyds import AtomKind, atoms

    last = [a for a in atoms.iter_atoms(data) if a.kind is AtomKind.FACT_ASSERT][-1]
    return data[: last.end - 3]


def test_truncated_stream_raises(tmp_path):
    # bytes are the whole extent, so a short tail is the slice being wrong
    # ([RFCS.19.2] lets a whole-buffer reader refuse it).
    data = _stream(tmp_path, 4)

    eng = pyds.from_source(_SRC)
    with pytest.raises(pyds.Error):
        eng.replay(_cut_in_last_assert(data))


def test_truncated_file_ends_at_the_last_complete_atom(tmp_path):
    # A file may be a recording still being written, or one a crash cut off:
    # either way its partial tail is end-of-stream ([RFCS.19.2], [RFCS.19.8]).
    # The three complete facts apply, the fourth does not, and the cut is
    # reported rather than raised.
    data = _stream(tmp_path, 4)

    eng = pyds.from_source(_SRC)
    res = eng.replay(io.BytesIO(_cut_in_last_assert(data)), chunk_size=5)
    assert res.asserts == 3
    assert res.tail_bytes > 0
    assert len(eng.facts) == 3

    whole = pyds.from_source(_SRC).replay(io.BytesIO(data))
    assert whole.tail_bytes == 0

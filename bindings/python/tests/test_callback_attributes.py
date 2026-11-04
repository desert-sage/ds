# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""An engine's callbacks are attributes, as ``sqlite3.Connection``'s are.

Each is assigned a callable to set it and ``None`` to clear it, and reads back
as what was assigned. Delivery through each is tested where its payload is;
this file holds the contract the five share.
"""

import pytest

import pyds

_CALLBACKS = [
    "on_event",
    "on_log",
    "on_metric",
    "on_cache_set",
    "on_cache_delete",
]


def _callback(*args):
    return None


@pytest.fixture
def engine():
    eng = pyds.from_source("schema Trig scope logical:\n    v: Int key\n")
    yield eng
    eng.close()


@pytest.mark.parametrize("name", _CALLBACKS)
def test_a_new_engine_has_none(engine, name):
    assert getattr(engine, name) is None


@pytest.mark.parametrize("name", _CALLBACKS)
def test_a_callback_reads_back_as_assigned_and_clears_with_none(engine, name):
    setattr(engine, name, _callback)
    assert getattr(engine, name) is _callback
    setattr(engine, name, None)
    assert getattr(engine, name) is None


@pytest.mark.parametrize("name", _CALLBACKS)
def test_what_is_not_callable_is_refused_and_changes_nothing(engine, name):
    setattr(engine, name, _callback)
    with pytest.raises(TypeError, match=f"^{name} must be a callable or None, not int$"):
        setattr(engine, name, 1)
    assert getattr(engine, name) is _callback


@pytest.mark.parametrize("name", _CALLBACKS)
def test_close_lets_go_of_every_callback(engine, name):
    setattr(engine, name, _callback)
    engine.close()
    assert getattr(engine, name) is None


@pytest.mark.parametrize("name", _CALLBACKS)
def test_leaving_a_with_block_lets_go_of_every_callback(name):
    with pyds.from_source("schema Trig scope logical:\n    v: Int key\n") as eng:
        setattr(eng, name, _callback)
    assert getattr(eng, name) is None


@pytest.mark.parametrize("name", _CALLBACKS)
def test_assigning_on_a_closed_engine_raises(engine, name):
    engine.close()
    with pytest.raises(ValueError, match=r"^operation on a closed Engine$"):
        setattr(engine, name, _callback)
    assert getattr(engine, name) is None


@pytest.mark.parametrize("name", _CALLBACKS)
def test_a_clone_starts_with_none(engine, name):
    setattr(engine, name, _callback)
    with engine.clone() as clone:
        assert getattr(clone, name) is None


def test_a_clone_does_not_deliver_to_its_sources_callback(engine):
    seen = []
    engine.on_event = seen.append
    with engine.clone() as clone:
        clone.assert_("Trig", v=1)
    assert seen == []

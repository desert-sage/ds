# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for Bytes-typed slots asserted via the pyds Python binding.

Bytes slots accept Python bytes/bytearray and give back bytes. The
language never converts a Bytes value (LSTR.4.6), so these read the
value back from the engine's working memory rather than through a
rule.
"""

import pytest

import pyds

_BYTES_SLOT = """
schema Raw scope logical:
    entity_id: String key
    payload: Bytes mutable

rule seen:
    Raw r
->
    log info "{r.entity_id}"
"""


def _stored(payload) -> bytes:
    eng = pyds.from_source(_BYTES_SLOT)
    eng.assert_("Raw", entity_id="m1", payload=payload)
    eng.pump()
    (fact,) = eng.facts.of("Raw")
    return fact.slots["payload"]


@pytest.mark.parametrize(
    "payload",
    [
        b"hello world",
        b"",
        bytes(range(256)),
        b"a\x00b",  # length-delimited, not cut at a zero byte
    ],
)
def test_bytes_slot_round_trips(payload):
    """A `bytes` value reaches the slot unchanged and reads back as `bytes`."""
    stored = _stored(payload)
    assert type(stored) is bytes
    assert stored == payload


def test_bytes_slot_accepts_bytearray():
    """`bytearray` is accepted, and reads back as `bytes`."""
    stored = _stored(bytearray(b"hello"))
    assert type(stored) is bytes
    assert stored == b"hello"


def test_bytes_slot_rejects_non_bytes_input():
    """Asserting a Bytes slot with a Python str raises TypeError rather than encoding it."""
    eng = pyds.from_source(_BYTES_SLOT)
    with pytest.raises(TypeError):
        eng.assert_("Raw", entity_id="m1", payload="hello")

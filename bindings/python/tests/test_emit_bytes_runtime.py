# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Emit into a Bytes-typed slot from a fact-bound source.

A rule whose RHS does `emit Schema slot: p.raw_log`, where Schema's slot is
`Bytes` and `p.raw_log` is a fact-bound Bytes value, emits the value as Bytes:
the pump never refuses it with DS_ERR_SLOT_TYPE_MISMATCH.
"""

import pyds

_EMIT_BYTES = """
schema InEvent scope logical:
    src: String key
    raw: Bytes mutable

schema OutEvent scope ttl 1h:
    src: String
    raw: Bytes

rule pass_through:
    InEvent i
->
    emit OutEvent src: i.src raw: i.raw

rule observe:
    OutEvent o
->
    log info "saw {o.src}"
"""


def test_emit_bytes_slot_from_fact_bound_source():
    """A fact-bound Bytes value flows through emit without [-104].

    The pass-through rule fires when an InEvent is asserted; it emits OutEvent
    with the raw bytes carried over verbatim. The observe rule logs to confirm
    the OutEvent landed.
    """
    eng = pyds.from_source(_EMIT_BYTES)
    logs: list[str] = []
    eng.on_log = lambda ev: logs.append(ev.message)
    eng.assert_("InEvent", src="ws1", raw=b"hello-bytes")
    eng.pump()
    assert any(m == "saw ws1" for m in logs), (
        f"emit-Bytes pass-through didn't reach observer: {logs!r}"
    )

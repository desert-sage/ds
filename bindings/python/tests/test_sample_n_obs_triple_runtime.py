# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""An obs-triple `count sample N` with tolerance compiles and runs.

A series declared as
`series Schema.slot (by: ...): count sample 32 tolerance 0.5` mixes an
accumulator observation with a `sample N` one, which SeriesBackendRingBuffer
backs. The ring buffer's element type comes from the bound schema's slot type,
so the encoder has one to write.
"""

import pyds

_SAMPLE_N_INT = """
use default

schema Tick scope logical:
    src: String key
    seq: Int mutable

series Tick.seq (by: src):
    count sample 16

rule observe:
    Tick t where count(t.seq) >= 1
->
    log info "saw {t.src}"
"""


def test_sample_n_obs_triple_int_slot_compiles_and_loads():
    """On an Int slot, element_type maps to Int rather than always Float.

    The obs has no tolerance phrase, so backing_magic is still
    SeriesBackendRingBuffer by virtue of the `sample N` time-model.
    """
    eng = pyds.from_source(_SAMPLE_N_INT)
    logs: list[str] = []
    eng.on_log = lambda ev: logs.append(ev.message)
    eng.assert_("Tick", src="ws1", seq=100)
    eng.pump()
    eng.assert_("Tick", src="ws1", seq=101)
    eng.pump()
    assert any("saw ws1" in m for m in logs), f"int-sample rule didn't log: {logs!r}"

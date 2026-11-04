# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for log/alert message interpolation.

`log info "{<binding>.<slot>} ..."` interpolates the bound slot
value into the message at activation time. Multiple paths and
mixed literal text are supported.
"""

from log_sink import capture_critical

import pyds

_INTERP = """
schema Reading scope logical:
    entity_id: String key
    state: Int mutable
    label: String mutable

rule alert_with_interp:
    Reading r
->
    log critical "{r.entity_id}: {r.state} ({r.label})"
"""


def test_interp_assembles_multiple_slot_values():
    """An alert message with three interp segments carries all three resolved values."""
    eng = pyds.from_source(_INTERP)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Reading", entity_id="kitchen", state=72, label="ok")
    eng.pump()
    assert alerts == ["kitchen: 72 (ok)"], f"interp assembly mismatch: {alerts!r}"


_INTERP_FORMAT = """
schema Reading scope logical:
    entity_id: String key
    state: Float mutable

rule alert_formatted:
    Reading r
->
    log critical "{r.entity_id} = {r.state:.2f}"
"""


def test_interp_format_spec_truncates_float_precision():
    """The `:.2f` format spec rounds the Float to 2 decimal places."""
    eng = pyds.from_source(_INTERP_FORMAT)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Reading", entity_id="kitchen", state=3.14159)
    eng.pump()
    assert alerts == ["kitchen = 3.14"], f"interp format mismatch: {alerts!r}"


# A `let` bound to an arithmetic expression, interpolated by name, evaluates
# at the native Rete backend; the Author's Reference shows the form.

_INTERP_LET_INT_ARITH = """
schema C scope logical:
    id: String key
    a: Int mutable
    b: Int mutable

rule r:
    C c
->
    let s = c.a + c.b
    log critical "v:{c.id}:{s}"
"""


def test_interp_let_bound_int_arithmetic():
    eng = pyds.from_source(_INTERP_LET_INT_ARITH)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("C", id="x", a=4, b=6)
    eng.pump()
    assert alerts == ["v:x:10"], f"let-arith interp mismatch: {alerts!r}"


_INTERP_LET_FLOORDIV = """
schema C scope logical:
    id: String key
    a: Int mutable
    b: Int mutable

rule r:
    C c
->
    let s = 10 + 5 * ((c.a + c.b + 1) // 2)
    log critical "v:{c.id}:{s}"
"""


def test_interp_let_bound_nested_int_arithmetic():
    """Nested integer arithmetic (+, *, //) interpolates exactly as Int.

    The auto format picks %ld, so 35 prints as `35`, not `35.0`.
    """
    eng = pyds.from_source(_INTERP_LET_FLOORDIV)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("C", id="x", a=4, b=6)
    eng.pump()
    # 10 + 5 * ((4 + 6 + 1) // 2) = 10 + 5 * 5 = 35
    assert alerts == ["v:x:35"], f"floordiv interp mismatch: {alerts!r}"


_INTERP_LET_FLOAT = """
schema C scope logical:
    id: String key
    x: Float mutable
    y: Float mutable

rule r:
    C c
->
    let s = c.x + c.y
    log critical "v:{c.id}:{s}"
"""


def test_interp_let_bound_float_arithmetic():
    """Float arithmetic interpolates via the auto %g format (3.5, not 3)."""
    eng = pyds.from_source(_INTERP_LET_FLOAT)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("C", id="x", x=1.5, y=2.0)
    eng.pump()
    assert alerts == ["v:x:3.5"], f"float-arith interp mismatch: {alerts!r}"


_INTERP_BINARY = """
schema Flags scope logical:
    entity_id: String key
    v: Int mutable

rule show:
    Flags f
->
    log critical "[{f.v:b}][{f.v:08b}]"
"""


def test_interp_binary_spec_lowers_to_ds_binfmt():
    # `:b` renders binary: 5 -> "101";
    # `:08b` zero-pads to width 8 -> "00000101".
    eng = pyds.from_source(_INTERP_BINARY)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("Flags", entity_id="a", v=5)
    eng.pump()
    assert alerts == ["[101][00000101]"], alerts


_INTERP_STRFTIME = """
schema Event scope logical:
    entity_id: String key
    ts: Time

rule show:
    Event e
->
    log critical "at {e.ts:%Y-%m-%d}"
"""


def test_interp_timestamp_spec_renders_the_date():
    # [LGRA.2.9.6.4]: `:%...` on a Time is a TimePrim of fields and text, rendered
    # by libds in the value's own offset. A Time slot stores its instant,
    # so 0 ns reads back as 1970-01-01 UTC. A timestamp spec on an Int is refused.
    eng = pyds.from_source(_INTERP_STRFTIME)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("Event", entity_id="a", ts=0)
    eng.pump()
    assert alerts == ["at 1970-01-01"], alerts


_INTERP_CAST = """
schema S scope logical:
    entity_id: String key
    f: Float mutable

rule r:
    S s
->
    let n = s.f::Int
    log critical "n={n}"
"""


def test_interp_of_scalar_cast_lowers():
    # N3 — `{n}` where n = s.f::Int now lowers (ir.py emit_expr Cast case).
    # 3.7 -> float_to_int truncate-toward-zero -> 3.
    eng = pyds.from_source(_INTERP_CAST)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("S", entity_id="a", f=3.7)
    eng.pump()
    assert alerts == ["n=3"], alerts

# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
r"""Runtime tests for the LECC.1.2 surface: CallError ingestion validates the `code` slot.

The regex is `[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*` (wm.c hook). Malformed codes
get rewritten to "internal.invariant" so author rules never see a malformed
identifier.

The segment-boundary matching of an `error <pattern>:` continuation
(LCCO.8.3.2) is the conformance vector
logical/LCCO.8.3.2_error_matches_at_segment_boundaries, on both runtimes.
It was a test here that called `ds-error-code-matches(...)`, which DS lexes
as subtraction, so the compile always threw and the test always skipped.
"""

from log_sink import capture_critical

import pyds

_CODE_REWRITE = """
rule reflect:
    CallError e
->
    log critical "{e.code}"
"""


def test_malformed_call_error_code_rewrites_to_internal_invariant():
    """A CallError with a hyphenated code lands in WM with the code 'internal.invariant'.

    A hyphen fails the LECC.1.2 regex, so the code is overwritten.
    """
    eng = pyds.from_source(_CODE_REWRITE)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    # Hyphens aren't legal in error codes — the wm.c hook rewrites.
    eng.assert_("CallError", corr="c1", code="auth-failed", message="rejected", ts=0)
    eng.pump()
    assert alerts == ["internal.invariant"], f"got {alerts!r}"


def test_well_formed_call_error_code_passes_through_unchanged():
    """A code matching the regex reaches author rules untouched."""
    eng = pyds.from_source(_CODE_REWRITE)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("CallError", corr="c1", code="auth.failed", message="rejected", ts=0)
    eng.pump()
    assert alerts == ["auth.failed"], f"got {alerts!r}"

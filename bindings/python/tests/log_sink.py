# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Author-log capture for the pyds suite.

The tests observe a rule through `log critical`. The log callback carries
more than a rule's own messages: it also carries ENGINE-INTERNAL lines. A
DSC loader emitting "skipping atom with unknown magic (RDSC.9.4)" arrives on
the same callback as a rule's own message — engine internals and author `log`
actions share one callback, distinguished by `category` (NCBK).

That difference is not cosmetic: a test asserting `sink == [...]` would see a
loader notice first. Filtering to the `critical` level keeps the sink to what
the rule said.
"""

import pyds


def capture_critical(engine, sink: list) -> None:
    """Append every author `log critical` message to `sink`, in order."""
    engine.on_log = lambda ev: (
        sink.append(ev.message) if ev.level is pyds.LogLevel.CRITICAL else None
    )

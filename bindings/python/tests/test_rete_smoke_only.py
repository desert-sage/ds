# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Load smoke tests for the smallest bundles.

Sequence: schema-only DSC (no rules → no AlphaNode/BetaNode/TerminalNode
atoms, ds_dsc_apply_rete_network never called) → minimal-rule DSC (one
AlphaNode, one BetaNode, one TerminalNode, simplest possible).
"""

from __future__ import annotations

import pyds


def _compile(source: str) -> bytes:
    return pyds.compile(source, file="t.ds")


_SCHEMA_ONLY = """\
schema Trig scope logical:
    v: Int key
"""


def test_rete_backend_loads_schema_only_bundle():
    """A schema-only bundle loads; the Rete network loader is never invoked.

    No AlphaNode/BetaNode/TerminalNode atoms get emitted at all. Verifies the
    engine creation + DSC walk-without-atoms path is clean.
    """
    dsc = _compile(_SCHEMA_ONLY)
    eng = pyds.Engine()
    eng.load_dsc(dsc)


_MINIMAL = """\
schema Trig scope logical:
    v: Int key

rule trig_logger:
    Trig
->
    log info "trig fired"
"""


def test_rete_backend_loads_minimal_rule_bundle():
    """A one-rule bundle loads: 1 AlphaNode + 1 BetaNode + 1 TerminalNode.

    The smallest bundle that actually exercises ds_dsc_apply_rete_network.
    """
    dsc = _compile(_MINIMAL)
    eng = pyds.Engine()
    eng.load_dsc(dsc)

# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The session header a fact stream opens with."""

from __future__ import annotations

from dataclasses import dataclass

from pyds._capability import Capability

__all__ = ["SessionHeader"]


@dataclass(frozen=True, slots=True)
class SessionHeader:
    """A fact stream's session header ([RFCS.4.1]): what wrote it, and for what.

    ``Engine.session_header`` reports the engine's, which libds's recorder
    writes as a stream's first atom.
    """

    ds_version: str
    """The DS version that wrote the stream ([LDET.1.10]). A reader accepts
    only its own ``<major>.<minor>.`` series."""
    session_id: str = ""
    """The run id the integrator gave the engine, or empty if it gave none
    ([LFST.4.4])."""
    tier_id: str = ""
    """Which tier wrote the stream: the integrator's own string
    ([LFST.4.5]), empty on an engine given none."""
    dsc_hash: bytes | None = None
    """The loaded artefact's 32-byte hash; None before one is loaded."""
    capabilities: tuple[Capability, ...] = ()
    """The loaded artefact's capabilities, in the ascending order its header
    holds them ([RBND.1.3]); empty before one is loaded."""
    dialect_def_sha256: bytes | None = None
    """The loaded artefact's 32-byte dialect-definition hash ([RBND.1.3]);
    None before one is loaded.

    With ``dsc_hash`` and ``capabilities`` it is the dialect binding a
    replay checks a stream against, all three fields together
    ([RBND.5.1])."""


SessionHeader.__module__ = "pyds"

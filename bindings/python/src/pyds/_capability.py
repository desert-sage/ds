# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
#
# GENERATED from proto/capabilities.proto
# -- do not edit. The `pyds` gate lane runs `--check`, so a hand edit is a
# red build. The numbers are normative; the names are labels.
"""The capability registry: `proto/capabilities.proto`'s `Capability`."""

import enum

__all__ = ["Capability"]


class Capability(enum.IntEnum):
    """A capability, as a ``use`` block or a dialect names it.

    The name a program writes is the member's in lower case:
    ``Capability.LINEAR_SCAN`` is ``linear_scan``.
    """

    REALTIME = 1
    CONSTSPACE = 2
    LINEAR_SCAN = 3
    LOGICAL = 4
    DYNAMIC_TTL = 5
    REGEX = 6
    FLOAT = 7
    CALL = 8
    PUBLISH = 9
    CACHE = 10
    CACHE_DELETE = 11
    NOCOOLDOWN = 13
    SERIES = 14
    SAMPLED_SLOTS = 15
    PERSIST_ON_SERIES = 16
    STORAGE_HYDRATE_FACTS = 20
    STORAGE_HYDRATE_SAMPLES = 21

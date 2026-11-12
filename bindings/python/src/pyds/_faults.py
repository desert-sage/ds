# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
#
# GENERATED from proto/engine_error.proto,
# proto/bounds_error.proto and proto/engine_fault.proto -- do not edit.
# The `pyds` gate lane runs `--check`, so a hand edit is a red build. The
# numbers are normative; the names are labels.
"""The fault causes the fault events carry, from their protos."""

import enum

__all__ = ["TrapKind", "CapName", "EngineFault"]


class TrapKind(enum.IntEnum):
    """Why a computation had no answer: ``ComputationError.trap_kind``."""

    DIVIDE_BY_ZERO = 1
    DOMAIN = 2
    NOT_REPRESENTABLE = 3


class CapName(enum.IntEnum):
    """The declared limit that was reached: ``BoundsError.cap``."""

    WM_MAX = 1
    AGENDA = 2
    MAX_FIRES_PER_PUMP = 3
    TOKEN_POOL = 4
    INTERN = 5
    INTERN_BYTES = 6
    PUMP_WCET_NS = 7
    CACHE = 8
    CACHE_BYTES = 9
    NODE_CAPACITY = 10
    SERIES_CAPACITY = 11
    VALUE_CAPACITY = 12


class EngineFault(enum.IntEnum):
    """What halted the engine: ``EngineError.engine_fault``, or a failed load."""

    UNSPECIFIED = 0
    ARTEFACT_LIED = 1
    PATTERN_INDEX = 2
    BINDING_ORDER = 3
    ORDER_KEY = 4
    ALLOCATION = 6
    PUMP_WCET = 7
    INTERNAL = 8

# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The closed vocabularies pyds reports and takes.

Each is a ``StrEnum`` whose values are the DS language's own words, so a
member compares equal to the string a program or another binding uses:
``Lifecycle.LOGICAL == "logical"``, ``SlotType.INT == "Int"``. The four that
name libds's enums (``EventKind``, ``LogLevel``, ``MetricKind`` and
``CacheRemovalReason``) take their values from
``runtime/src/bindings/ds_names.h``, the table every binding names them by; a
pyds test holds each to the extension's own rendering of it. ``NodeKind`` and
``MatchResult`` take theirs from the words ``libds.h`` gives its Rete readers.

NO SERIES VOCABULARY. No public function reads a series ([NSBK.6.3]), and
the samples plane is deferred, so there is no aggregation, storage mode or
element type to name.

``Admission`` is the one ``IntEnum``: it names no word of the language, only a
policy libds numbers, so its values are ``libds.h``'s own, taken from the
extension.
"""

from __future__ import annotations

from enum import IntEnum, StrEnum

from pyds._pyds import _ADMIT_EITHER, _ADMIT_FALSE_ONLY, _ADMIT_TRUE_ONLY

__all__ = [
    "Admission",
    "CacheRemovalReason",
    "ClockMode",
    "EventKind",
    "IdentityRole",
    "Lifecycle",
    "LogLevel",
    "MatchResult",
    "MetricKind",
    "NodeKind",
    "SlotType",
]


class Admission(IntEnum):
    """Which settings of one capability an engine admits.

    ``Engine.set_admission`` takes one.
    """

    EITHER = _ADMIT_EITHER
    """Both settings load; an engine's policy for every capability until set."""
    TRUE_ONLY = _ADMIT_TRUE_ONLY
    """Only an artefact with the capability ``true``."""
    FALSE_ONLY = _ADMIT_FALSE_ONLY
    """Only an artefact with the capability ``false``."""


class EventKind(StrEnum):
    """The kind of a stream event: each ``pyds.events`` class's ``kind``."""

    FACT_ASSERT = "fact_assert"
    FACT_RETRACT = "fact_retract"
    FACT_MODIFY = "fact_modify"
    RULE_FIRE_BEGIN = "rule_fire_begin"
    RULE_FIRE_END = "rule_fire_end"
    ACTION_CALL = "action_call"
    ACTION_EMIT = "action_emit"
    ACTION_PUBLISH = "action_publish"
    ACTION_CACHE_SET = "action_cache_set"
    ACTION_CACHE_GET = "action_cache_get"
    ACTION_LOG = "action_log"
    TICK = "tick"
    ACTION_CACHE_DELETE = "action_cache_delete"
    RULE_LHS_FACTS = "rule_lhs_facts"
    TIMER_ARMED = "timer_armed"
    TIMER_FIRED = "timer_fired"
    """Reserved: libds never emits it, so no ``pyds.events`` class has it."""
    TYPE_ERROR = "type_error"
    BOUNDS_ERROR = "bounds_error"
    ENGINE_ERROR = "engine_error"
    COMPUTATION_ERROR = "computation_error"
    PUMP = "pump"


class LogLevel(StrEnum):
    """A ``log`` action's severity."""

    DEBUG = "DEBUG"
    INFO = "INFO"
    WARNING = "WARNING"
    ERROR = "ERROR"
    CRITICAL = "CRITICAL"


class MetricKind(StrEnum):
    """What a metric measures."""

    COUNTER = "counter"
    GAUGE = "gauge"
    HISTOGRAM = "histogram"


class CacheRemovalReason(StrEnum):
    """Why a key left the engine's cache."""

    DELETE = "delete"
    """A rule's ``cache_delete``."""
    TTL = "ttl"
    """Its time to live ran out."""


class ClockMode(StrEnum):
    """Where an engine's clocks read their time ([NDET.4])."""

    LIVE = "live"
    """From the host: the monotonic clock and the wall clock."""
    MOCK = "mock"
    """From the integrator, who sets and advances them: tests and replay."""


class Lifecycle(StrEnum):
    """How long a schema's facts live: its scope ([LSCP.2])."""

    LOGICAL = "logical"
    """Held while the rules that derived it still support it, or until
    retracted."""
    TTL = "ttl"
    """Held until retracted, or until its time to live, ``Schema.ttl_ns``,
    runs out."""
    INTERNAL = "internal"
    """A schema the engine declares itself: ``ComputationError`` and
    ``TypeError``."""


class SlotType(StrEnum):
    """A slot's declared type."""

    INT = "Int"
    FLOAT = "Float"
    STRING = "String"
    BOOL = "Bool"
    JSON = "Json"
    BYTES = "Bytes"
    TIME = "Time"
    DATE = "Date"
    DURATION = "Duration"
    SCHEMA = "Schema"
    """A reference to a fact; ``Slot.schema_ref`` names the schema."""


class IdentityRole(StrEnum):
    """A slot's part in a logical fact's identity ([LFAC.1.7])."""

    KEY = "key"
    """Part of the identity key: facts equal on every key slot are one fact."""
    MUTABLE = "mutable"
    """Payload: a new value supersedes the fact."""
    ENGINE = "engine"
    """Set by the engine, outside identity: a logical schema's ``ts``."""


class NodeKind(StrEnum):
    """A node of the Rete network ([NDBG.4.1])."""

    ALPHA = "alpha"
    """Tests one fact of a schema."""
    BETA = "beta"
    """Joins two inputs; ``ReteNode.is_negative`` for a ``no`` pattern."""
    TERMINAL = "terminal"
    """Fires a rule."""


class MatchResult(StrEnum):
    """What an alpha node did with a fact, in a match trace ([NDBG.4.2])."""

    PASSED = "passed"
    """The fact met the node's test."""
    FILTERED = "filtered"
    """The fact failed it."""

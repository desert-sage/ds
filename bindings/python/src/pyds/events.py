# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""What an engine reports: its stream events and its callbacks' payloads.

Every value here is a frozen, slotted dataclass, a snapshot taken when the
engine reported it, so a handler can keep it, compare it, and take it apart
with ``match``::

    match ev:
        case events.FactAssert(fact_id=fid): ...
        case events.ComputationError(trap_kind=TrapKind.DIVIDE_BY_ZERO): ...

A stream event's class is named as ``runtime/src/bindings/ds_names.h`` names
its kind, in CapWords, and its ``kind`` is that name as an ``EventKind``. Its
fields keep the stream's names. Every event carries ``seq``, its place in the
stream, and ``clock_ns``, the engine clock when it happened.

``TypeError`` here is the ``type_error`` event, not the builtin exception.
Use it qualified, ``events.TypeError``; ``pyds`` does not re-export it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, ClassVar

from pyds._faults import CapName, EngineFault, TrapKind
from pyds.enums import EventKind, LogLevel, MetricKind
from pyds.facts import FactId

__all__ = [
    "ActionCacheDelete",
    "ActionCacheGet",
    "ActionCacheSet",
    "ActionCall",
    "ActionEmit",
    "ActionLog",
    "ActionPublish",
    "BoundsError",
    "ComputationError",
    "EngineError",
    "Event",
    "FactAssert",
    "FactModify",
    "FactRetract",
    "LogEvent",
    "Metric",
    "Pump",
    "RuleFireBegin",
    "RuleFireEnd",
    "RuleLhsFacts",
    "Tick",
    "TimerArmed",
    "TypeError",
]


@dataclass(frozen=True, slots=True)
class _StreamEvent:
    """What every stream event carries."""

    seq: int
    """Its place in the engine's stream, from 0."""
    clock_ns: int
    """The engine clock when it happened."""


@dataclass(frozen=True, slots=True)
class FactAssert(_StreamEvent):
    """A fact entered working memory."""

    kind: ClassVar[EventKind] = EventKind.FACT_ASSERT
    fact_id: FactId


@dataclass(frozen=True, slots=True)
class FactRetract(_StreamEvent):
    """A fact left working memory. Inside the callback, it is still live."""

    kind: ClassVar[EventKind] = EventKind.FACT_RETRACT
    fact_id: FactId


@dataclass(frozen=True, slots=True)
class FactModify(_StreamEvent):
    """A logical fact's mutable slots changed in place; its id stays."""

    kind: ClassVar[EventKind] = EventKind.FACT_MODIFY
    fact_id: FactId


@dataclass(frozen=True, slots=True)
class RuleFireBegin(_StreamEvent):
    """A rule began firing."""

    kind: ClassVar[EventKind] = EventKind.RULE_FIRE_BEGIN
    rule_name: str
    timetag: int
    """The firing's identity, shared by every event it causes."""


@dataclass(frozen=True, slots=True)
class RuleFireEnd(_StreamEvent):
    """A rule finished firing."""

    kind: ClassVar[EventKind] = EventKind.RULE_FIRE_END
    rule_name: str
    timetag: int


@dataclass(frozen=True, slots=True)
class RuleLhsFacts(_StreamEvent):
    """The facts a firing matched, reported just before it begins."""

    kind: ClassVar[EventKind] = EventKind.RULE_LHS_FACTS
    rule_name: str
    timetag: int
    lhs_facts: tuple[FactId, ...]
    """The facts the firing matched, in pattern order."""


@dataclass(frozen=True, slots=True)
class ActionEmit(_StreamEvent):
    """A rule emitted a fact."""

    kind: ClassVar[EventKind] = EventKind.ACTION_EMIT
    fact_id: FactId


@dataclass(frozen=True, slots=True)
class ActionPublish(_StreamEvent):
    """A rule published a fact to another tier.

    The fact is in no working memory of this engine, so it has no ``FactId``:
    ``schema`` and ``slots`` are copies of it, taken while the engine reported
    it.
    """

    kind: ClassVar[EventKind] = EventKind.ACTION_PUBLISH
    schema: str
    """The published fact's schema."""
    slots: dict[str, object]
    """Its slot values by name, as ``Engine.facts`` gives a fact's."""
    external: bytes
    """Its FactExternal encoding, which ``Engine.assert_external`` takes."""

    # As ActionCall: it holds a dict, so it is not hashable.
    __hash__ = None  # type: ignore[assignment]  # unhashable, as a dict is


@dataclass(frozen=True, slots=True)
class ActionLog(_StreamEvent):
    """A rule logged a message."""

    kind: ClassVar[EventKind] = EventKind.ACTION_LOG
    level: LogLevel
    category: str
    message: str


@dataclass(frozen=True, slots=True)
class ActionCacheSet(_StreamEvent):
    """A rule wrote a key of the engine's cache."""

    kind: ClassVar[EventKind] = EventKind.ACTION_CACHE_SET
    key: str
    value_json: str
    """The value as its canonical JSON text."""
    ttl_ns: int
    """Its time to live; 0 for none."""


@dataclass(frozen=True, slots=True)
class ActionCacheGet(_StreamEvent):
    """A rule read a key of the engine's cache."""

    kind: ClassVar[EventKind] = EventKind.ACTION_CACHE_GET
    key: str
    value_json: str | None
    """The value read, as its canonical JSON text; None for a key with none."""


@dataclass(frozen=True, slots=True)
class ActionCacheDelete(_StreamEvent):
    """A rule deleted a key of the engine's cache."""

    kind: ClassVar[EventKind] = EventKind.ACTION_CACHE_DELETE
    key: str


@dataclass(frozen=True, slots=True)
class ActionCall(_StreamEvent):
    """A rule called a service."""

    kind: ClassVar[EventKind] = EventKind.ACTION_CALL
    service: str
    correlation: str
    """The call's ``as`` value, or the one generated for a call with none
    ([LCRS.3.1]); never empty."""
    args: dict[str, object]
    """Its arguments by name, the event's own copy: each as a fact's slot
    reads, and a fact argument as a ``pyds.EncodedFact``. An argument the call
    omits is absent."""
    timetag: int
    rule_name: str

    # It holds a dict, so it compares by value and is not hashable (data
    # model §3.3.1); the dataclass would otherwise generate a hash that fails.
    __hash__ = None  # type: ignore[assignment]  # unhashable, as a dict is


@dataclass(frozen=True, slots=True)
class TimerArmed(_StreamEvent):
    """A firing started a timer: a cooldown, or an ``after``."""

    kind: ClassVar[EventKind] = EventKind.TIMER_ARMED
    rule_name: str
    timetag: int
    """The arming firing's."""
    timer_kind: str
    window_ns: int
    fire_at_ns: int
    """``clock_ns + window_ns``."""


@dataclass(frozen=True, slots=True)
class Tick(_StreamEvent):
    """The engine took a clock sample that differs from the last one.

    ``clock_ns`` is the monotonic sample.
    """

    kind: ClassVar[EventKind] = EventKind.TICK
    wall_ns: int | None
    """The wall clock sample, UTC; None while the wall clock has no value."""


@dataclass(frozen=True, slots=True)
class Pump(_StreamEvent):
    """A host pump began, after its clock sample and before anything it does."""

    kind: ClassVar[EventKind] = EventKind.PUMP


@dataclass(frozen=True, slots=True)
class TypeError(_StreamEvent):  # type_error's standard name; used qualified
    """An operation met a value of a type it does not take.

    The activation is abandoned, and the fault is also a ``TypeError`` fact.
    """

    kind: ClassVar[EventKind] = EventKind.TYPE_ERROR
    node_id: int
    schema_name: str | None
    slot_name: str | None
    actual: str | None
    """The type it met."""
    rule_name: str


@dataclass(frozen=True, slots=True)
class BoundsError(_StreamEvent):
    """An operation reached a declared limit and was refused."""

    kind: ClassVar[EventKind] = EventKind.BOUNDS_ERROR
    cap: CapName
    limit: int
    observed: int
    rule_name: str | None
    timetag: int


@dataclass(frozen=True, slots=True)
class EngineError(_StreamEvent):
    """The engine halted; nearly every call now raises.

    ``halted``, ``platform_signature``, ``session_header`` and ``close`` still
    answer ([NCBK.2.9]).
    """

    kind: ClassVar[EventKind] = EventKind.ENGINE_ERROR
    engine_fault: EngineFault
    node_id: int
    rule_name: str


@dataclass(frozen=True, slots=True)
class ComputationError(_StreamEvent):
    """A well-typed computation had no answer.

    The activation is abandoned, and the fault is also a ``ComputationError``
    fact.
    """

    kind: ClassVar[EventKind] = EventKind.COMPUTATION_ERROR
    trap_kind: TrapKind
    rule_name: str
    timetag: int
    schema_name: str | None
    slot_name: str | None
    fact_id: FactId | None
    node_id: int


type Event = (
    FactAssert
    | FactRetract
    | FactModify
    | RuleFireBegin
    | RuleFireEnd
    | RuleLhsFacts
    | ActionEmit
    | ActionPublish
    | ActionLog
    | ActionCall
    | ActionCacheSet
    | ActionCacheGet
    | ActionCacheDelete
    | TimerArmed
    | Tick
    | Pump
    | TypeError
    | BoundsError
    | EngineError
    | ComputationError
)
"""Any stream event: what ``Engine.on_event`` is called with."""


@dataclass(frozen=True, slots=True)
class LogEvent:
    """A log record: what ``Engine.on_log`` is called with."""

    level: LogLevel
    category: str
    message: str


@dataclass(frozen=True, slots=True)
class Metric:
    """A metric reading: what ``Engine.on_metric`` is called with."""

    name: str
    kind: MetricKind
    value: float
    labels: dict[str, str]
    """The event's own copy."""

    # As ActionCall: it holds a dict, so it is not hashable.
    __hash__ = None  # type: ignore[assignment]  # unhashable, as a dict is


# NO `Sample` AND NO `SeriesDeclaration`: there is no samples plane, and
# NSTG.5 is deferred.

_EVENT_CLASSES: tuple[type[Event], ...] = (
    FactAssert,
    FactRetract,
    FactModify,
    RuleFireBegin,
    RuleFireEnd,
    RuleLhsFacts,
    ActionEmit,
    ActionPublish,
    ActionLog,
    ActionCall,
    ActionCacheSet,
    ActionCacheGet,
    ActionCacheDelete,
    TimerArmed,
    Tick,
    Pump,
    TypeError,
    BoundsError,
    EngineError,
    ComputationError,
)
_BY_KIND: dict[str, type[Event]] = {cls.kind: cls for cls in _EVENT_CLASSES}


# The extension hands each payload over as a plain dict of its fields, whose
# value types depend on the field: the one boundary in this module that takes
# anything, so the records below are dict[str, Any] (PY.12).
type _Record = dict[str, Any]


def _event(record: _Record) -> Event:
    """Build the event the extension's record of one describes.

    A record is a dict of the event's fields, with ``kind`` naming its class;
    the closed vocabularies arrive as their names or numbers and leave as
    enums. A kind with no class raises ``ValueError``: it is an event this
    pyds cannot describe, and passing it on as anything else would hide that.
    """
    fields = dict(record)
    kind = fields.pop("kind")
    cls = _BY_KIND.get(kind)
    if cls is None:
        raise ValueError(f"a stream event of kind {kind!r}, which pyds does not know")
    if "level" in fields:
        fields["level"] = LogLevel(fields["level"])
    if "cap" in fields:
        fields["cap"] = CapName(fields["cap"])
    if "engine_fault" in fields:
        fields["engine_fault"] = EngineFault(fields["engine_fault"])
    if "trap_kind" in fields:
        fields["trap_kind"] = TrapKind(fields["trap_kind"])
    if "lhs_facts" in fields:
        fields["lhs_facts"] = tuple(fields["lhs_facts"])
    event: Event = cls(**fields)
    return event


def _log_event(record: _Record) -> LogEvent:
    """Build a LogEvent from the extension's record of one."""
    return LogEvent(
        level=LogLevel(record["level"]), category=record["category"], message=record["message"]
    )


def _metric(record: _Record) -> Metric:
    """Build a Metric from the extension's record of one."""
    return Metric(
        name=record["name"],
        kind=MetricKind(record["kind"]),
        value=record["value"],
        labels=record["labels"],
    )

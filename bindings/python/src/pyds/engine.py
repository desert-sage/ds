# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The engine: one libds engine, and the program loaded into it."""

from __future__ import annotations

import functools
import operator
import os
from collections.abc import Buffer, Callable, Iterable, Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Literal, Protocol, SupportsIndex

from pyds._capability import Capability
from pyds._faults import EngineFault
from pyds._pyds import _Engine
from pyds.enums import (
    Admission,
    CacheRemovalReason,
    ClockMode,
    IdentityRole,
    Lifecycle,
    MatchResult,
    NodeKind,
    SlotType,
)
from pyds.events import (
    Event,
    LogEvent,
    Metric,
    _event,
    _log_event,
    _metric,
)
from pyds.facts import Fact, FactId, _fact
from pyds.session import SessionHeader

if TYPE_CHECKING:
    # The extension's record shapes, which only its stub names.
    from pyds._pyds import _RuleRecord, _SchemaRecord, _Source

__all__ = [
    "Cache",
    "Clock",
    "Debug",
    "Engine",
    "Facts",
    "Justifier",
    "LineSpan",
    "LineSpans",
    "MemoryUsage",
    "PlatformSignature",
    "ProgramSource",
    "Recording",
    "RefractedActivation",
    "ReplayResult",
    "ReteEdge",
    "ReteNetwork",
    "ReteNode",
    "Rule",
    "Rules",
    "Schema",
    "Schemas",
    "Slot",
    "Source",
    "Sources",
    "TraceStep",
]


@dataclass(frozen=True, slots=True)
class Source:
    """Where a declaration is in the program's source."""

    file: str
    line: int
    column: int


@dataclass(frozen=True, slots=True)
class Slot:
    """One slot of a schema, as declared."""

    name: str
    type: SlotType
    schema_ref: str | None
    """The schema a fact-reference slot names; None for any other slot."""
    nullable: bool
    """Declared ``T?``: the slot may hold no value."""
    identity: IdentityRole | None
    """Its part in a logical fact's identity; None outside a logical schema."""
    sampled: bool
    retained: bool
    hydration_eligible: bool
    tolerance: float | None
    docstring: str | None


@dataclass(frozen=True, slots=True)
class Schema:
    """A schema the engine knows, as it was when read.

    A snapshot: it holds nothing of the engine's.
    """

    name: str
    lifecycle: Lifecycle
    ttl_ns: int
    """The time to live of its facts; 0 for none."""
    slots: tuple[Slot, ...]
    """In declaration order."""
    source: Source | None
    """Where the program declares it; None for a schema the engine declares
    itself."""
    proto_source: str | None
    """The ``.proto`` text the compiler generated for its facts, if the
    artefact carries it."""


@dataclass(frozen=True, slots=True)
class Rule:
    """A rule of the loaded program, from the artefact's metadata."""

    name: str
    cooldown_ns: int | None
    """Its cooldown window; None for a rule with no cooldown."""
    source: Source | None
    debug_name_template: str | None
    """The template a debugger names its firings by, if the program gives
    one."""


@dataclass(frozen=True, slots=True)
class ProgramSource:
    """One source file of the loaded program, as the artefact carries it."""

    module_id: int
    """The module's id, by which its spans name it."""
    file: str
    """Its path as given to the compiler: a display name, which two modules
    may share."""
    text: str
    """The module's DS source."""


@dataclass(frozen=True, slots=True)
class LineSpan:
    """Where in the program's source a node of the rule network comes from.

    Its position is named as a ``Source``'s is.
    """

    node_id: int
    """The node's index among all the network's alpha, beta and terminal
    nodes, unique in the program, as a runtime diagnostic names it."""
    module_id: int
    """The module it comes from: a key of ``Engine.sources`` when the
    artefact carries that module's source."""
    file: str | None
    """The module's file, as its ``ProgramSource`` names it; None when the
    artefact carries no source for the module."""
    line: int
    column: int


@dataclass(frozen=True, slots=True)
class PlatformSignature:
    """The platform an engine runs on ([LDET.2.3]).

    It is provenance, not a scope on the determinism guarantee: a recording
    replays bit for bit whether or not two engines' signatures match
    ([NDET.2.1]).
    """

    os_family: str
    cpu_arch: str
    libc: str
    compiler: str
    libds_version: str
    """The DS version this libds was built as, which it stamps into every
    stream it records."""
    backends: tuple[str, ...]
    """Each registered series backend as ``"<atom>:<name>:<version>"``, in
    registration order."""


@dataclass(frozen=True, slots=True)
class MemoryUsage:
    """What an engine's working memory and network hold, in bytes and counts.

    JSON trees are not counted, and an interned string is counted once
    however many facts share it.
    """

    wm_fact_count: int
    wm_fact_bytes: int
    wm_index_bytes: int
    alpha_node_count: int
    alpha_match_count: int
    alpha_index_bytes: int
    beta_node_count: int
    beta_token_count: int
    beta_token_bytes: int
    beta_index_bytes: int
    intern_count: int
    intern_string_bytes: int
    intern_index_bytes: int
    pool_reserved_bytes: int
    total_bytes: int
    """The sum of the ``_bytes`` fields above."""


@dataclass(frozen=True, slots=True)
class ReplayResult:
    """What ``Engine.replay`` delivered and checked, by atom."""

    asserts: int
    """Facts asserted: the inputs delivered and the emitted facts compared.

    A recorded assert a bound refused again counts, and asserts nothing.
    """
    retracts: int
    clocks: int
    """Clock samples delivered."""
    rule_fires: int
    """Rule fires re-derived and found identical to the recording's."""
    calls: int
    """Calls re-derived and found identical to the recording's."""
    withdrawals: int
    skipped: int
    """Atoms passed over as carrying nothing to replay: announcements, and a
    BoundsError on ``pump_wcet_ns``."""
    header_verified: bool
    """Whether the stream's header names the artefact this engine loaded."""
    tail_bytes: int
    """Bytes of a partial last atom: a file or iterable may end mid-atom, as
    a recording still being written does. Always 0 for a bytes-like stream,
    which is refused instead."""


@dataclass(frozen=True, slots=True)
class Justifier:
    """An activation that logically supports a fact: ``debug.justifiers``."""

    rule_name: str
    timetag: int
    """The activation's timetag, as the stream's ``rule_fire_begin`` names it."""


@dataclass(frozen=True, slots=True)
class ReteNode:
    """A node of the Rete network, as ``debug.network`` reports it."""

    id: str
    """The node's id in the artefact."""
    kind: NodeKind
    label: str
    """The schema an alpha node tests, or the rule a terminal fires."""
    filter: str
    """The node's test, formatted; empty for none."""
    occupancy: int | None
    """The facts or tokens the node holds, when ``include_occupancy`` asked
    for it while the engine was paused between pumps; otherwise None."""
    is_negative: bool
    """A beta node for a ``no`` pattern."""


@dataclass(frozen=True, slots=True)
class ReteEdge:
    """An edge of the Rete network, from one node's id to another's."""

    from_id: str
    to_id: str


@dataclass(frozen=True, slots=True)
class ReteNetwork:
    """The Rete network the engine loaded: ``debug.network``."""

    nodes: tuple[ReteNode, ...]
    edges: tuple[ReteEdge, ...]


@dataclass(frozen=True, slots=True)
class TraceStep:
    """One alpha node's verdict on a fact: ``debug.match_trace``."""

    node_id: str
    node_kind: NodeKind
    result: MatchResult
    detail: str
    """Why, in the program's names."""


@dataclass(frozen=True, slots=True)
class RefractedActivation:
    """An activation refraction holds back from firing again: ``debug.refracted``.

    It stays listed until the activation is re-created.
    """

    rule_name: str
    reason: str
    """Why it is held back: ``"refraction"``."""
    detail: str
    fact_ids: tuple[FactId, ...]
    """The facts the rule's patterns bound, in pattern order, every one live
    ([NDBG.4.3]). A fact the compiler made (a clock tick, an ``after`` timer)
    is not among them."""


class _Reader(Protocol):
    """A binary file, or anything else ``replay`` can read from."""

    def read(self, size: int, /) -> Buffer: ...


class Recording:
    """A recording of an engine's fact stream: what ``Engine.record`` returns.

    It writes from ``record`` until it closes, by ``close()`` or at the end
    of a ``with`` block, as ``open()``'s file does. Closing the engine closes
    it too, without reporting a failure.
    """

    __slots__ = ("_closed", "_engine", "_path")

    def __init__(self, engine: Engine, path: Path) -> None:
        """Hold the recording ``engine`` writes to ``path``; ``Engine.record`` makes one."""
        self._engine = engine
        self._path = path
        self._closed = False

    @property
    def path(self) -> Path:
        """The file the recording writes."""
        return self._path

    @property
    def closed(self) -> bool:
        """Whether the recording has stopped."""
        return self._closed

    def close(self) -> None:
        """Stop the recording and close its file; idempotent.

        Raises ``pyds.Error`` if the recorder failed to encode or write
        anything during the recording, which was also the status of the
        engine call that fired the event ([NCBK.1.5]), and ``OSError`` if the
        file did not close cleanly. The recording has stopped either way.
        """
        if self._closed:
            return
        self._closed = True
        if self._engine._recording is self:
            del self._engine._recording
            self._engine._record_stop()

    def __enter__(self) -> Recording:
        """Return the recording, for a ``with`` block."""
        return self

    def __exit__(self, *exc_info: object) -> None:
        """Close the recording at the end of a ``with`` block."""
        self.close()

    def __repr__(self) -> str:
        """Show the file and whether the recording has stopped."""
        state = "closed" if self._closed else "recording"
        return f"<pyds.Recording {state} {str(self._path)!r}>"


def _source(record: _Source | None) -> Source | None:
    return None if record is None else Source(*record)


def _schema(record: _SchemaRecord) -> Schema:
    name, lifecycle, ttl_ns, slots, source, proto_source = record
    return Schema(
        name=name,
        lifecycle=Lifecycle(lifecycle),
        ttl_ns=ttl_ns,
        slots=tuple(
            Slot(
                name=s[0],
                type=SlotType(s[1]),
                schema_ref=s[2],
                nullable=s[3],
                identity=None if s[4] is None else IdentityRole(s[4]),
                sampled=s[5],
                retained=s[6],
                hydration_eligible=s[7],
                tolerance=s[8],
                docstring=s[9],
            )
            for s in slots
        ),
        source=_source(source),
        proto_source=proto_source,
    )


def _rule(record: _RuleRecord) -> Rule:
    name, cooldown_ns, source, debug_name_template = record
    return Rule(name, cooldown_ns, _source(source), debug_name_template)


class Schemas(Mapping[str, Schema]):
    """The schemas an engine knows, by name: ``engine.schemas``.

    A view, as ``dict.keys()`` is: it reads the engine each time it is
    used, so a program loaded after it was taken is in it. It iterates in the
    engine's own order.
    """

    __slots__ = ("_engine",)

    def __init__(self, engine: _Engine) -> None:
        """Take the engine the view reads; ``engine.schemas`` makes one."""
        self._engine = engine

    def __getitem__(self, name: str) -> Schema:
        """Return the schema named ``name``; ``KeyError`` if the engine has none."""
        if not isinstance(name, str):
            raise KeyError(name)
        record = self._engine._schema_find(name)
        if record is None:
            raise KeyError(name)
        return _schema(record)

    def __iter__(self) -> Iterator[str]:
        """Yield each schema's name, in the engine's order."""
        for i in range(self._engine._schema_count()):
            yield self._engine._schema_at(i)[0]

    def __len__(self) -> int:
        """Return how many schemas the engine knows."""
        return self._engine._schema_count()

    def __repr__(self) -> str:
        """Show the schemas' names."""
        return f"<pyds.Schemas {list(self)!r}>"


class Rules(Mapping[str, Rule]):
    """The loaded program's rules, by name: ``engine.rules``.

    A view, as ``Schemas`` is, in the order the program declares them.
    """

    __slots__ = ("_engine",)

    def __init__(self, engine: _Engine) -> None:
        """Take the engine the view reads; ``engine.rules`` makes one."""
        self._engine = engine

    def __getitem__(self, name: str) -> Rule:
        """Return the rule named ``name``; ``KeyError`` if the program has none."""
        if not isinstance(name, str):
            raise KeyError(name)
        record = self._engine._rule_find(name)
        if record is None:
            raise KeyError(name)
        return _rule(record)

    def __iter__(self) -> Iterator[str]:
        """Yield each rule's name, in the order the program declares them."""
        for i in range(self._engine._rule_count()):
            yield self._engine._rule_at(i)[0]

    def __len__(self) -> int:
        """Return how many rules the loaded program has."""
        return self._engine._rule_count()

    def __repr__(self) -> str:
        """Show the rules' names."""
        return f"<pyds.Rules {list(self)!r}>"


class Sources(Mapping[int, ProgramSource]):
    """The loaded program's source files, by module id: ``engine.sources``.

    A view, as ``Schemas`` is, in the artefact's order. A program carries one
    source per module, so the ids are unique. Empty before a load.
    """

    __slots__ = ("_engine",)

    def __init__(self, engine: _Engine) -> None:
        """Take the engine the view reads; ``engine.sources`` makes one."""
        self._engine = engine

    def _records(self) -> Iterator[tuple[int, str, str]]:
        for i in range(self._engine._ds_source_count()):
            yield self._engine._ds_source_at(i)

    def __getitem__(self, module_id: int) -> ProgramSource:
        """Return the source of module ``module_id``; ``KeyError`` if no module has it."""
        key = _id_key(module_id)
        if key is None:
            raise KeyError(module_id)
        # libds finds a source only by position, and a program has few.
        for record in self._records():
            if record[0] == key:
                return ProgramSource(*record)
        raise KeyError(module_id)

    def __iter__(self) -> Iterator[int]:
        """Yield each module id, in the artefact's order."""
        for record in self._records():
            yield record[0]

    def __len__(self) -> int:
        """Return how many source files the program carries."""
        return self._engine._ds_source_count()

    def __repr__(self) -> str:
        """Show the module ids."""
        return f"<pyds.Sources {list(self)!r}>"


class LineSpans(Mapping[int, LineSpan]):
    """Where each attributed node comes from, by node id: ``engine.line_spans``.

    A view, as ``Schemas`` is, in the artefact's order. A node id is unique in
    a program, so a node has at most one span. Empty before a load.
    """

    __slots__ = ("_engine",)

    def __init__(self, engine: _Engine) -> None:
        """Take the engine the view reads; ``engine.line_spans`` makes one."""
        self._engine = engine

    def __getitem__(self, node_id: int) -> LineSpan:
        """Return node ``node_id``'s span; ``KeyError`` if the node has none."""
        key = _id_key(node_id)
        if key is None or not 0 <= key <= 0xFFFF_FFFF:
            raise KeyError(node_id)
        record = self._engine._line_span_find(key)
        if record is None:
            raise KeyError(node_id)
        return LineSpan(*record)

    def __iter__(self) -> Iterator[int]:
        """Yield each attributed node's id, in the artefact's order."""
        for i in range(self._engine._line_span_count()):
            yield self._engine._line_span_at(i)[0]

    def __len__(self) -> int:
        """Return how many nodes carry a span."""
        return self._engine._line_span_count()

    def __repr__(self) -> str:
        """Show how many spans there are."""
        return f"<pyds.LineSpans len={len(self)}>"


def _id_key(key: object) -> int | None:
    """Return the int an id-keyed view's key names, or None if no entry can have it.

    A FactId, or anything with ``__index__`` but a bool, as a dict keyed by
    int would find it. Facts, Sources and LineSpans take their keys so.
    """
    if isinstance(key, bool) or not isinstance(key, SupportsIndex):
        return None
    return operator.index(key)


class Facts(Mapping[FactId, Fact]):
    """Working memory, by fact id: ``engine.facts``.

    A view, as ``dict.keys()`` is: it reads the engine each time it is used.
    Indexing it reads one live fact as a ``Fact`` snapshot, and a fact that
    is not live (retracted, expired, superseded, or never asserted) is a
    ``KeyError``; ``fid in engine.facts`` asks whether it is live. Inside a
    stream callback for a fact's retract, that fact is still live.

    It iterates in id order, which is the order the facts were asserted.
    Iterating, and ``of``, read working memory itself and never the stream,
    so they can be held against a reader of the stream. Each iteration reads
    the ids when it starts; a fact retracted while the walk goes on is then a
    ``KeyError`` when its value is read.
    """

    __slots__ = ("_engine",)

    def __init__(self, engine: _Engine) -> None:
        """Take the engine the view reads; ``engine.facts`` makes one."""
        self._engine = engine

    def __getitem__(self, fact_id: FactId) -> Fact:
        """Return a snapshot of live fact ``fact_id``; ``KeyError`` if it is not live."""
        key = _id_key(fact_id)
        if key is None:
            raise KeyError(fact_id)
        return _fact(self._engine._fact(FactId(key)))

    def __contains__(self, fact_id: object) -> bool:
        """Return whether ``fact_id`` names a live fact."""
        key = _id_key(fact_id)
        return key is not None and self._engine._fact_live(FactId(key))

    def __iter__(self) -> Iterator[FactId]:
        """Iterate over the live facts' ids, in id order, read when it starts."""
        return iter(sorted(self._engine._fact_ids(None)))

    def __len__(self) -> int:
        """Return how many facts are live."""
        return self._engine._fact_count()

    def of(self, schema: str, /) -> list[Fact]:
        """Return the live facts of one schema, in id order.

        A schema name the engine does not know raises ``ValueError``, where
        an empty list would read as a schema with no facts.
        """
        records = self._engine._facts(schema)
        return [_fact(record) for record in sorted(records, key=lambda r: r[0])]

    def __repr__(self) -> str:
        """Show how many facts are live."""
        return f"<pyds.Facts len={len(self)}>"


class Clock:
    """An engine's two clocks: ``engine.clock``.

    The monotonic clock is the engine's time for TTLs, cooldowns and
    windows; the wall clock is UTC, for ``now()``, dates and times of day
    ([NLFC.5.1]). Both are integer nanoseconds. In ``ClockMode.LIVE`` they read the host; in
    ``ClockMode.MOCK`` the integrator sets and advances them, which is how a
    test or a replay gets a reproducible run.
    """

    __slots__ = ("_engine",)

    def __init__(self, engine: _Engine) -> None:
        """Take the engine whose clocks these are; ``engine.clock`` makes one."""
        self._engine = engine

    @property
    def mode(self) -> ClockMode:
        """Where the clocks read their time; assign a ``ClockMode`` to switch.

        A str naming a member is taken too. Switching to ``MOCK`` is refused
        once the live clock has been sampled.
        """
        return ClockMode(self._engine._clock_mode())

    @mode.setter
    def mode(self, mode: ClockMode | str) -> None:
        # ClockMode() raises ValueError for anything it cannot look up, so
        # the type is checked first (PY.6). A ClockMode is a str.
        if not isinstance(mode, str):
            raise TypeError(f"clock mode must be a ClockMode or str, not {type(mode).__name__}")
        self._engine._clock_set_mode(ClockMode(mode).value)

    @property
    def now_ns(self) -> int:
        """The monotonic clock's value. Reading it takes no sample."""
        return self._engine._clock_now()

    @property
    def next_deadline_ns(self) -> int | None:
        """The earliest deadline after the clock's current value, or ``None``.

        A deadline is a live timer's ``fire_at``, a live fact's TTL expiry or a
        cache entry's expiry. Reading it takes no sample and records nothing.
        """
        return self._engine._clock_next_deadline()

    def set(self, now_ns: int, /) -> None:
        """Set the mock monotonic clock to ``now_ns``.

        Mock mode only. Once the engine has had an input, a time before the
        current one is refused.
        """
        self._engine._clock_set(now_ns)

    def advance(self, delta_ns: int, /) -> None:
        """Advance the mock clocks by ``delta_ns``: the wall clock too, once set.

        Mock mode only.
        """
        self._engine._clock_advance(delta_ns)

    def set_wall(self, utc_ns: int, /) -> None:
        """Set the mock wall clock to ``utc_ns``, nanoseconds since the epoch.

        Any instant, before the epoch included. Mock mode only.
        """
        self._engine._wall_clock_set(utc_ns)

    def __repr__(self) -> str:
        """Show the clock mode and the monotonic clock's value."""
        return f"<pyds.Clock {self.mode.value} now_ns={self.now_ns}>"


class Cache:
    """The engine-owned cache, from the integrator's side: ``engine.cache``.

    Rules write the cache with ``cache`` and read it with ``cached()``, and
    ``on_cache_set`` and ``on_cache_delete`` observe those writes. Here an
    integrator seeds it before a run and bounds it.
    """

    __slots__ = ("_engine",)

    def __init__(self, engine: _Engine) -> None:
        """Take the engine whose cache this is; ``engine.cache`` makes one."""
        self._engine = engine

    def seed(self, key: str, value_json: str | bytes, *, ttl_ns: int = 0) -> None:
        """Store ``value_json`` under ``key`` before the first stream event.

        ``value_json`` is JSON text, the form a cache value is read back in;
        libds stores its canonical form, so a seed and a rule's write of the
        same JSON store the same bytes. As ``bytes`` it is the text's UTF-8,
        handed to libds unchanged, which refuses octets that are not
        well-formed UTF-8 with ``pyds.Error`` and ``Status.ENCODING``
        ([LSTR.8.5]). ``ttl_ns`` is its time to live, 0 for none. A seed is
        not a rule's write: it raises no ``on_cache_set`` and no event. Once
        the engine has emitted a stream event, as an assert, a retract and a
        pump each do, it is refused with ``pyds.Error`` and ``Status.STATE``
        ([NLFC.9.2]), and past a bound ``set_cap`` set with ``ContractError``.
        """
        self._engine._cache_seed(key, value_json, ttl_ns)

    def set_cap(self, *, keys: int = 0, bytes: int = 0) -> None:
        """Bound the cache: ``keys`` live keys and ``bytes`` value bytes.

        Each is 0 for unbounded. libds refuses a cache write past either with
        ``Status.CONTRACT_BREACH`` and changes nothing.
        """
        self._engine._set_cache_cap(cap_keys=keys, cap_bytes=bytes)

    def __repr__(self) -> str:
        """Name the object; the cache's contents are the engine's to report."""
        return "<pyds.Cache>"


def _live_fact_id(engine: _Engine, fact_id: SupportsIndex) -> FactId:
    """``fact_id`` as a ``FactId``, if a live fact has it.

    Raises ``TypeError`` for a non-integer (PY.6), and ``KeyError`` for an id
    no live fact has, out of range included: libds answers such an id with
    nothing, which would read as a fact with nothing to report.
    """
    if isinstance(fact_id, bool):
        raise TypeError("a fact id is an int, not bool")
    key = operator.index(fact_id)  # TypeError for anything not an integer
    if key not in Facts(engine):
        raise KeyError(fact_id)
    return FactId(key)


def _rule_filter(engine: _Engine, rule_filter: str | None) -> str | None:
    """``rule_filter``, if it names one of the program's rules, or None.

    A name the program does not have is a ``ValueError``, where libds would
    answer with nothing, as ``facts.of`` refuses an unknown schema.
    """
    if rule_filter is None:
        return None
    if not isinstance(rule_filter, str):
        raise TypeError(f"rule_filter must be a str or None, not {type(rule_filter).__name__}")
    if rule_filter not in Rules(engine):
        raise ValueError(f"the program has no rule {rule_filter!r}")
    return rule_filter


class Debug:
    """What an engine can tell a debugger about its state: ``engine.debug``.

    Each call reads the engine as it is then, and returns values that do not
    change after. The engine's truth maintenance and network are settled
    between pumps, so that is when these are read. Inside one of the
    engine's own callbacks every call raises ``pyds.Error``.
    """

    __slots__ = ("_engine",)

    def __init__(self, engine: _Engine) -> None:
        """Take the engine to report on; ``engine.debug`` makes one."""
        self._engine = engine

    def justifiers(self, fact_id: FactId, /) -> list[Justifier]:
        """Return the activations that logically support a live fact ([NDBG.5.1]).

        Empty for a fact no rule supports, such as one the host asserted.
        Raises ``KeyError`` for an id with no live fact.
        """
        fid = _live_fact_id(self._engine, fact_id)
        return [
            Justifier(rule_name=r["rule_name"], timetag=r["timetag"])
            for r in self._engine._justifiers(fid)
        ]

    def network(
        self, *, rule_filter: str | None = None, include_occupancy: bool = False
    ) -> ReteNetwork:
        """Return the Rete network, its nodes and edges ([NDBG.4.1]).

        ``rule_filter`` keeps the nodes that rule's terminal is reached
        through; a name the program has no rule for is a ``ValueError``.
        ``include_occupancy=True`` fills each node's ``occupancy``.
        """
        if not isinstance(include_occupancy, bool):
            raise TypeError(
                f"include_occupancy must be a bool, not {type(include_occupancy).__name__}"
            )
        record = self._engine._rete_network(
            _rule_filter(self._engine, rule_filter), include_occupancy
        )
        # List comprehensions, not generator expressions: on CPython 3.12 a
        # generator expression crashes the interpreter when an allocation in it
        # fails, where 3.12's inlined comprehension raises MemoryError.
        return ReteNetwork(
            nodes=tuple(
                [
                    ReteNode(
                        id=n["id"],
                        kind=NodeKind(n["kind"]),
                        label=n["label"],
                        filter=n["filter"],
                        occupancy=n["occupancy"],
                        is_negative=n["is_negative"],
                    )
                    for n in record["nodes"]
                ]
            ),
            edges=tuple(
                [ReteEdge(from_id=e["from_id"], to_id=e["to_id"]) for e in record["edges"]]
            ),
        )

    def match_trace(self, fact_id: FactId, /) -> list[TraceStep]:
        """Return a live fact's path through the alpha nodes that test its schema.

        One ``TraceStep`` per node, in the order they test it ([NDBG.4.2]).
        Raises ``KeyError`` for an id with no live fact.
        """
        fid = _live_fact_id(self._engine, fact_id)
        return [
            TraceStep(
                node_id=t["node_id"],
                node_kind=NodeKind(t["node_kind"]),
                result=MatchResult(t["result"]),
                detail=t["detail"],
            )
            for t in self._engine._rete_match_trace(fid)
        ]

    def refracted(self, *, rule_filter: str | None = None) -> list[RefractedActivation]:
        """Return the activations that fired and are held back from firing again.

        Rule by rule in the agenda's order, and within a rule by the facts
        they bound ([NDBG.4.3]). ``rule_filter`` keeps one rule's; a name the
        program has no rule for is a ``ValueError``.
        """
        return [
            RefractedActivation(
                rule_name=r["rule_name"],
                reason=r["reason"],
                detail=r["detail"],
                fact_ids=tuple(r["fact_ids"]),
            )
            for r in self._engine._refracted_activations(_rule_filter(self._engine, rule_filter))
        ]

    def __repr__(self) -> str:
        """Name the object; its reads are its methods."""
        return "<pyds.Debug>"


def _checked(fn: object, name: str) -> None:
    """Refuse a callback that is neither callable nor None (PY.6)."""
    if fn is not None and not callable(fn):
        raise TypeError(f"{name} must be a callable or None, not {type(fn).__name__}")


def _delivering[R](
    fn: Callable[[R], object], convert: Callable[[dict[str, Any]], R]
) -> Callable[..., object]:
    """Wrap ``fn`` for the extension to call, with the record made a value.

    Named and documented as ``fn`` is, so the report of an exception it
    raises names the caller's function.
    """

    @functools.wraps(fn)
    def deliver(record: dict[str, Any]) -> object:
        return fn(convert(record))

    return deliver


# The callbacks an engine holds, by attribute; close() lets go of them.
_CALLBACKS = (
    "_on_event",
    "_on_log",
    "_on_metric",
    "_on_cache_set",
    "_on_cache_delete",
)


class Engine(_Engine):
    """A libds engine.

    It holds working memory and runs the program loaded into it. The calls
    that do the work (``assert_``, ``pump``) are the extension's own methods,
    with no Python frame between the caller and libds.

    ``Engine(*, run_id=None, tier_id=None)`` gives the engine its identity,
    which is the integrator's to choose: libds derives every fact's event id
    from the two and the fact's sequence number, and a recording's session
    header carries them. ``run_id`` and ``tier_id`` read them back, None for
    one not given; an empty string is the same as none. A ``clone()`` keeps
    them. A value that is not a str is a ``TypeError``, and one holding a NUL
    a ``ValueError``.

    An engine holds native memory until ``close()`` releases it. It is a
    context manager, so ``with Engine() as e:`` closes it on the way out, and
    ``closed`` says whether it has been. Every other call on a closed engine
    raises ``ValueError``.

    Its callbacks are attributes, as ``sqlite3.Connection.row_factory`` is:
    assign a callable to set one, ``None`` to clear it, and read it back.
    Assigning anything else raises ``TypeError``. A callback runs inside the
    engine call that caused it, so it must not call back into the engine
    ([RARC.13.16]). Only ``facts[fid]`` and ``fid in facts`` answer there;
    ``len(facts)``, iterating ``facts`` and ``facts.of`` are refused.
    ``on_event`` observes and cannot fail the call, and libds drops what
    ``on_log`` and ``on_metric`` report ([NCBK.1.5]); every other callback's
    failure is libds's to report, as each says. The first exception a callback
    raises during an engine call is kept: if the call fails, the
    ``pyds.Error`` it raises carries it as ``__cause__``, and if it succeeds,
    the exception goes to ``sys.unraisablehook``, as does any later one. A
    ``clone()`` starts with none.
    """

    # Named where it is imported from, as sqlite3.Connection is: help(), a
    # repr and a traceback say pyds.Engine.
    __module__ = "pyds"

    # The callbacks the engine holds, and its recording: each setter makes an
    # instance attribute, and close() deletes it, which leaves the class's
    # None to read.
    _on_event: Callable[[Event], object] | None = None
    _on_log: Callable[[LogEvent], object] | None = None
    _on_metric: Callable[[Metric], object] | None = None
    _on_cache_set: Callable[[str, str, int], object] | None = None
    _on_cache_delete: Callable[[str, CacheRemovalReason], object] | None = None
    _recording: Recording | None = None

    @property
    def on_event(self) -> Callable[[Event], object] | None:
        """Called with every stream event, a ``pyds.events`` value, in order."""
        return self._on_event

    @on_event.setter
    def on_event(self, fn: Callable[[Event], object] | None) -> None:
        _checked(fn, "on_event")
        self._set_stream_callback(None if fn is None else _delivering(fn, _event))
        self._on_event = fn

    @property
    def on_log(self) -> Callable[[LogEvent], object] | None:
        """Called with every log line, a ``pyds.events.LogEvent``.

        A line is a rule's ``log`` or the engine's own ([NCBK.4.1]).
        """
        return self._on_log

    @on_log.setter
    def on_log(self, fn: Callable[[LogEvent], object] | None) -> None:
        _checked(fn, "on_log")
        self._set_log_callback(None if fn is None else _delivering(fn, _log_event))
        self._on_log = fn

    @property
    def on_metric(self) -> Callable[[Metric], object] | None:
        """Called with every metric reading, a ``pyds.events.Metric``."""
        return self._on_metric

    @on_metric.setter
    def on_metric(self, fn: Callable[[Metric], object] | None) -> None:
        _checked(fn, "on_metric")
        self._set_metric_callback(None if fn is None else _delivering(fn, _metric))
        self._on_metric = fn

    # NO `on_sample` AND NO `on_series_declared`: there is no samples plane,
    # and NSTG.5 is deferred.

    def _set_cache(
        self,
        set_fn: Callable[[str, str, int], object] | None,
        delete_fn: Callable[[str, CacheRemovalReason], object] | None,
    ) -> None:
        # libds registers the two cache callbacks together.
        deliver_delete: Callable[[str, str], object] | None = None
        if delete_fn is not None:
            removed = delete_fn

            @functools.wraps(removed)
            def deliver_delete(key: str, reason: str) -> object:
                return removed(key, CacheRemovalReason(reason))

        self._set_cache_callbacks(set_cb=set_fn, delete_cb=deliver_delete)

    @property
    def on_cache_set(self) -> Callable[[str, str, int], object] | None:
        """Called as ``fn(key, value_json, ttl_ns)`` when a rule writes the cache.

        The cache is the engine's own and is read from the engine; this only
        mirrors writes to a durable store. ``value_json`` is the canonical JSON
        text, and ``ttl_ns`` 0 for no time to live. One that raises fails the
        write, which libds reports.
        """
        return self._on_cache_set

    @on_cache_set.setter
    def on_cache_set(self, fn: Callable[[str, str, int], object] | None) -> None:
        _checked(fn, "on_cache_set")
        self._set_cache(fn, self.on_cache_delete)
        self._on_cache_set = fn

    @property
    def on_cache_delete(self) -> Callable[[str, CacheRemovalReason], object] | None:
        """Called as ``fn(key, reason)`` when a key leaves the engine's cache.

        ``reason`` is a ``CacheRemovalReason``: ``DELETE`` for a rule's
        ``cache_delete``, ``TTL`` when its time to live ran out. It means the
        key is gone, not that a rule asked for it, so it comes for keys no
        rule named and a store's delete must be idempotent.
        """
        return self._on_cache_delete

    @on_cache_delete.setter
    def on_cache_delete(self, fn: Callable[[str, CacheRemovalReason], object] | None) -> None:
        _checked(fn, "on_cache_delete")
        self._set_cache(self.on_cache_set, fn)
        self._on_cache_delete = fn

    def close(self) -> None:
        """Release the engine's native memory, and its callbacks; idempotent.

        From inside one of the engine's own callbacks it raises, and changes
        nothing.
        """
        super().close()
        for name in _CALLBACKS:
            self.__dict__.pop(name, None)
        # The extension stopped the recorder with the engine.
        recording = self._recording
        if recording is not None:
            del self._recording
            recording._closed = True

    def __exit__(self, *exc_info: object) -> Literal[False]:
        """Close the engine at the end of a ``with`` block; never suppress an exception."""
        # Through close(), so the callbacks go too; never suppresses (PY.4),
        # and returns False as the extension's __exit__ does.
        self.close()
        return False

    @property
    def clock(self) -> Clock:
        """The engine's clocks: their mode, and the mock clocks' setters."""
        return Clock(self)

    @property
    def cache(self) -> Cache:
        """The engine-owned cache: seed it and bound it."""
        return Cache(self)

    @property
    def debug(self) -> Debug:
        """What the engine can tell a debugger: justifiers, network, traces."""
        return Debug(self)

    @property
    def facts(self) -> Facts:
        """Working memory, by fact id: a ``Mapping`` view of ``Fact``s."""
        return Facts(self)

    @property
    def schemas(self) -> Schemas:
        """The schemas the engine knows, by name: a ``Mapping`` view."""
        return Schemas(self)

    def slot_to_stored(self, schema: str, slot: str, value: int | float) -> int | float:
        """Return a number in the unit a slot names as the number the slot stores.

        The slot's declared type is a unit symbol (NFCT.1.4.6): ``value`` is in
        that unit, and the result is what ``value::<unit>`` gives a rule, which
        ``assert_`` takes. An ``int`` for a slot stored as an integer, a
        ``Duration``'s nanoseconds among them, and a ``float`` for one stored as
        a float. Changes nothing. Refused with ``pyds.Error``:
        ``SCHEMA_UNKNOWN`` or ``SLOT_UNKNOWN`` for a name the engine has no
        schema or slot by, then libds's statuses: ``INVAL`` for a slot that
        names no unit, ``SLOT_TYPE_MISMATCH``, ``NAN_REJECTED``, and
        ``NOT_REPRESENTABLE`` where the conversion has no result for the
        number.
        """
        return self._slot_convert(schema, slot, value, True)

    def slot_from_stored(self, schema: str, slot: str, value: int | float) -> int | float:
        """Return a number a slot stores in the unit the slot names.

        The inverse of ``slot_to_stored``: what a kwarg of the slot's unit
        receives (NFCT.1.4.6), and refused as it is.
        """
        return self._slot_convert(schema, slot, value, False)

    @property
    def rules(self) -> Rules:
        """The loaded program's rules, by name: a ``Mapping`` view."""
        return Rules(self)

    @property
    def sources(self) -> Sources:
        """The loaded program's source files, by module id: a ``Mapping`` view."""
        return Sources(self)

    @property
    def line_spans(self) -> LineSpans:
        """Where each attributed node comes from, by node id: a ``Mapping`` view."""
        return LineSpans(self)

    @property
    def halted(self) -> EngineFault | None:
        """The fault that halted the engine, or None while it runs.

        Once an ``EngineError`` has halted the engine, every call but this
        one, ``platform_signature``, ``session_header`` and ``close`` raises
        ``pyds.Error`` with ``Status.ENGINE_HALTED`` -- reads of working
        memory, schemas and the debugger's surface included, since the halt
        leaves that state undefined -- and this names the ``EngineFault``
        that did it: the one the ``engine_error`` event carried, readable
        whether or not anything saw the event. An engine a failed
        ``load_dsc`` spent ([RDSC.9.8]) is halted the same way and reads
        ``EngineFault.UNSPECIFIED``: no ``EngineError`` was raised
        ([NCBK.2.11]). ``UNSPECIFIED`` is ``0`` and so false, so test the
        result against ``None``, not for truth.
        """
        fault = self._halted()
        return None if fault is None else EngineFault(fault)

    @property
    def platform_signature(self) -> PlatformSignature:
        """The platform this engine runs on, a ``PlatformSignature``."""
        record = self._platform_signature()
        return PlatformSignature(
            os_family=record["os_family"],
            cpu_arch=record["cpu_arch"],
            libc=record["libc"],
            compiler=record["compiler"],
            libds_version=record["libds_version"],
            backends=tuple(record["backends"]),
        )

    @property
    def session_header(self) -> SessionHeader:
        """The header a recording of this engine opens with, a ``SessionHeader``.

        ``dsc_hash`` and ``dialect_def_sha256`` are None, and
        ``capabilities`` empty, until a program is loaded.
        """
        record = self._session_header()
        return SessionHeader(
            ds_version=record["ds_version"],
            session_id=record["session_id"],
            tier_id=record["tier_id"],
            dsc_hash=record["dsc_hash"],
            capabilities=tuple(map(Capability, record["capabilities"])),
            dialect_def_sha256=record["dialect_def_sha256"],
        )

    def decode_fact_body(self, schema: str, body: Buffer, /) -> dict[str, object]:
        """Read a recorded fact body against the engine's schema ``schema``.

        ``body`` is a ``FactAssert`` or ``FactEmit``'s ``fact`` field, decoded
        by libds (``ds_rfcs_decode_fact_body``), and the values come back as
        ``Fact.slots`` gives them.

        A schema the engine does not hold is a ``KeyError``. One with a
        fact-ref slot is a ``ValueError``: a recorded handle means something
        only to the stream's own reader ([RFCS.6.3]).
        """
        slots = self._decode_fact_body(schema, body)
        if slots is None:
            raise KeyError(schema)
        return slots

    def record(self, path: str | os.PathLike[str], /, *, flush: bool = False) -> Recording:
        """Record the engine's fact stream to ``path``, and return the ``Recording``.

        The stream is canonical RFCS, written by libds's own recorder; the
        file is created, or truncated if it exists. ``flush=True`` flushes it
        after every atom, so a reader can follow the recording while it is
        written. The recording carries the event kinds [RFCS.3.6] gives an
        atom, and no other: a log line, a cache write or delete, and a rule's
        matched facts are not recorded. ``on_event`` goes on hearing every
        event, a recorded one after the recorder has taken it. One recording
        at a time: another while one runs raises ``RuntimeError``.
        """
        if not isinstance(flush, bool):
            raise TypeError(f"flush must be a bool, not {type(flush).__name__}")
        target = Path(path)
        self._record_start(os.fspath(target), flush)
        recording = Recording(self, target)
        self._recording = recording
        return recording

    def replay(
        self, stream: Buffer | Iterable[Buffer] | _Reader, /, *, chunk_size: int = 65536
    ) -> ReplayResult:
        """Replay a recorded fact stream into the engine, checking it as it goes.

        The recorded inputs are delivered and the rules fire again, and every
        rule fire, call, emitted fact, withdrawal and bounds error they
        re-derive must match the recording byte for byte; a difference raises
        ``pyds.TraceError`` with ``Status.FS_DIVERGENCE``. A bound on
        ``pump_wcet_ns`` is not compared. ``stream`` is a bytes-like object, a binary
        file (read ``chunk_size`` bytes at a time), or an iterable of
        bytes-like chunks. It is fed through and never held, so a recording
        larger than memory replays. A bytes-like stream that ends mid-atom is
        refused; a file or iterable may, and ``ReplayResult.tail_bytes`` says
        how much was left.
        """
        if isinstance(chunk_size, bool) or not isinstance(chunk_size, int):
            raise TypeError(f"chunk_size must be an int, not {type(chunk_size).__name__}")
        if chunk_size < 1:
            raise ValueError(f"chunk_size must be at least 1, not {chunk_size}")
        return ReplayResult(**self._replay(stream, chunk_size))

    def memory_usage(self) -> MemoryUsage:
        """Measure what working memory and the network hold, a ``MemoryUsage``.

        A call rather than a property because it walks the network.
        """
        return MemoryUsage(**self._mem())

    # NO `register_schema`. A schema reaches an engine from a compiled
    # artefact and in no other way ([NFCT.1.1]): `load_dsc`, or `from_source`.

    def set_admission(self, capability: Capability, admission: Admission, /) -> None:
        """Admit only one setting of a capability in what is loaded later.

        An engine admits both settings of every capability until told
        otherwise. ``Admission.TRUE_ONLY`` or ``FALSE_ONLY`` admits only an
        artefact whose setting for ``capability`` is that one, and
        ``Admission.EITHER`` admits both again: an integration with nothing
        behind ``call``, say, admits ``Capability.CALL`` false only. Given
        before a load: a later ``load_dsc`` whose setting the policy does not
        admit raises ``ArtefactMismatchError`` with
        ``Status.BND_DIALECT_MISMATCH``, naming the capability.

        A capability or admission that is not an int is a ``TypeError``, and
        one that names no member a ``ValueError``.
        """
        cap = _member(Capability, capability, "capability")
        admit = _member(Admission, admission, "admission")
        self._set_admission(cap.value, admit.value)

    # NO `series_value`. No public function reads a series
    # ([NSBK.6.3]): a series' values reach an integrator through what rules do
    # with them, a `log` or an emitted fact.

    def __repr__(self) -> str:
        """Show the engine's class, and whether it is closed."""
        name = f"{type(self).__module__}.{type(self).__qualname__}"
        return f"<{name} closed>" if self.closed else f"<{name}>"


def _member[E: (Capability, Admission)](enum: type[E], value: object, name: str) -> E:
    """Return ``value`` as a member of the ``IntEnum`` ``enum``.

    TypeError for a value that is not an int (a bool is not one), ValueError
    for one no member has.
    """
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{name} must be a {enum.__name__}, not {type(value).__name__}")
    return enum(value)


for _cls in (
    Source,
    Slot,
    Schema,
    Rule,
    Facts,
    Schemas,
    Rules,
    Clock,
    PlatformSignature,
    MemoryUsage,
    ReplayResult,
    Recording,
    Debug,
    Justifier,
    ReteNode,
    ReteEdge,
    ReteNetwork,
    TraceStep,
    RefractedActivation,
):
    _cls.__module__ = "pyds"
del _cls

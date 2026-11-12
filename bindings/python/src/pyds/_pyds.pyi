# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The types of ``pyds._pyds``, the libds extension behind pyds (PY.12).

``python -m mypy.stubtest pyds._pyds`` holds this file to the built module.
stubtest compares names and signatures, not return types, so each return
type below is the shape the C builds, read from ``src/_pyds/*.c``: a record
is a tuple or a dict there, and its fields' types are what the C puts in it.
"""

import sys
from collections.abc import Buffer, Callable, Iterable
from typing import Any, Final, Literal, Protocol, Self, SupportsIndex, TypedDict, final

from typing_extensions import disjoint_base

from pyds.facts import FactId

_ADMIT_EITHER: int
_ADMIT_TRUE_ONLY: int
_ADMIT_FALSE_ONLY: int

def build_capabilities() -> tuple[int, ...]: ...
def _names() -> dict[str, tuple[str, ...]]: ...

# ---- atoms.c ----------------------------------------------------------------

def next_atom(buf: Buffer, pos: int, partial: bool, /) -> tuple[int, bytes, int] | None: ...
def frame(field: SupportsIndex, body: Buffer, /) -> bytes: ...
def container_of(buf: Buffer, /) -> int: ...
def wire_fields(body: Buffer, /) -> list[tuple[int, int, int | bytes]]: ...

# visit_atom's value: int (int, uint, enum number), float, bool, the enum's
# (number, name), str, bytes, or None for enter and leave.
type _VisitValue = int | float | bool | tuple[int, str | None] | str | bytes | None

def visit_atom(
    field: SupportsIndex, body: Buffer, /
) -> list[tuple[str, str | None, int, int, int, str | None, _VisitValue]]: ...
def atom_message_name(field: SupportsIndex, /) -> str | None: ...

# ---- engine.c: the values a call hands out ---------------------------------

@final
class JsonText(str):
    """A DS Json value, as its canonical JSON text."""

@final
class EncodedFact(tuple[str, int | None, bytes]):
    """A fact passed as a call argument: (schema, asserted_at, data)."""

    @property
    def schema(self) -> str: ...
    @property
    def asserted_at(self) -> int | None: ...
    @property
    def data(self) -> bytes: ...
    # A struct sequence gained `__replace__` (`copy.replace`) in CPython 3.13;
    # the floor is 3.12 (PY.1).
    if sys.version_info >= (3, 13):
        def __replace__(self, **changes: object) -> Self: ...
    __match_args__: Final = ("schema", "asserted_at", "data")
    n_fields: int
    n_sequence_fields: int
    n_unnamed_fields: int

# ---- engine.c: the records _Engine's readers return ------------------------

# (file, line, column)
type _Source = tuple[str, int, int]

# (name, type, schema_ref, nullable, identity, sampled, retained,
# hydration_eligible, tolerance, docstring): schema.c's _slot_record.
type _SlotRecord = tuple[
    str, str, str | None, bool, str | None, bool, bool, bool, float | None, str | None
]

# (name, lifecycle, ttl_ns, slots, source, proto_source): schema.c.
type _SchemaRecord = tuple[str, str, int, tuple[_SlotRecord, ...], _Source | None, str | None]

# (name, cooldown_ns, source, debug_name_template): rule_meta.c.
type _RuleRecord = tuple[str, int | None, _Source | None, str | None]

# (id, schema, slots, asserted_ns, ttl_deadline_ns), the deadline 0 for none.
type _FactRecord = tuple[FactId, str, dict[str, object], int, int]

class _MemRecord(TypedDict):
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

class _ReplayRecord(TypedDict):
    asserts: int
    retracts: int
    clocks: int
    rule_fires: int
    calls: int
    withdrawals: int
    skipped: int
    header_verified: bool
    tail_bytes: int

class _PlatformRecord(TypedDict):
    os_family: str
    cpu_arch: str
    libc: str
    compiler: str
    libds_version: str
    backends: list[str]

class _SessionHeaderRecord(TypedDict):
    ds_version: str
    session_id: str
    tier_id: str
    dsc_hash: bytes | None
    capabilities: tuple[int, ...]
    dialect_def_sha256: bytes | None

class _JustifierRecord(TypedDict):
    timetag: int
    rule_name: str

class _NodeRecord(TypedDict):
    id: str
    kind: str
    label: str
    filter: str
    occupancy: int | None
    is_negative: bool

class _EdgeRecord(TypedDict):
    from_id: str
    to_id: str

class _NetworkRecord(TypedDict):
    nodes: list[_NodeRecord]
    edges: list[_EdgeRecord]

class _TraceRecord(TypedDict):
    node_id: str
    node_kind: str
    result: str
    detail: str

class _RefractedRecord(TypedDict):
    rule_name: str
    reason: str
    detail: str
    fact_ids: list[FactId]

# A call argument's value: a Json value arrives as its JsonText, a fact as its
# EncodedFact. No None: a kwarg with no value prevents the call ([NCBK.6.10]).
type _ArgValue = int | float | str | bool | bytes | JsonText | EncodedFact

class _CallRequest(TypedDict):
    service: str
    correlation: str
    args: dict[str, _ArgValue]
    timetag: int
    rule_name: str

class _LogRecord(TypedDict):
    level: str
    category: str
    message: str

class _MetricRecord(TypedDict):
    name: str
    kind: str
    value: float
    labels: dict[str, str]

class _Reader(Protocol):
    def read(self, size: int, /) -> Buffer: ...

# ---- engine.c: _Engine -----------------------------------------------------

# A C type with its own instance layout: it cannot share a subclass with
# another such base (PEP 800).
@disjoint_base
class _Engine:
    """The extension's half of pyds.Engine; use pyds.Engine."""

    def __init__(self, *, run_id: str | None = None, tier_id: str | None = None) -> None: ...
    @property
    def closed(self) -> bool: ...
    @property
    def run_id(self) -> str | None: ...
    @property
    def tier_id(self) -> str | None: ...
    def clone(self, /) -> Self: ...
    def close(self, /) -> None: ...
    def __enter__(self, /) -> Self: ...
    def __exit__(self, /, *exc_info: object) -> Literal[False]: ...

    # The program
    def load_dsc(self, dsc: Buffer, /) -> None: ...
    def _schema_count(self, /) -> int: ...
    def _schema_at(self, index: SupportsIndex, /) -> _SchemaRecord: ...
    def _schema_find(self, name: str, /) -> _SchemaRecord | None: ...
    def _slot_convert(
        self, schema: str, slot: str, value: int | float, to_stored: bool, /
    ) -> int | float: ...
    def _decode_fact_body(self, schema: str, body: Buffer, /) -> dict[str, object] | None: ...
    def _set_admission(self, capability: SupportsIndex, admission: SupportsIndex, /) -> None: ...
    def _rule_count(self, /) -> int: ...
    def _rule_at(self, index: SupportsIndex, /) -> _RuleRecord: ...
    def _rule_find(self, name: str, /) -> _RuleRecord | None: ...
    def _ds_source_count(self, /) -> int: ...
    def _ds_source_at(self, index: SupportsIndex, /) -> tuple[int, str, str]: ...
    def _line_span_count(self, /) -> int: ...
    def _line_span_at(self, index: SupportsIndex, /) -> tuple[int, int, str | None, int, int]: ...
    def _line_span_find(
        self, node_id: SupportsIndex, /
    ) -> tuple[int, int, str | None, int, int] | None: ...

    # Working memory
    def assert_(self, schema: str, /, **slots: object) -> FactId: ...
    def assert_external(self, data: Buffer | EncodedFact, /) -> None: ...
    def retract(self, fact_id: SupportsIndex, /) -> None: ...
    def pump(self, /) -> None: ...
    def _fact_count(self, /) -> int: ...
    def _fact(self, fact_id: SupportsIndex, /) -> _FactRecord: ...
    def _fact_live(self, fact_id: SupportsIndex, /) -> bool: ...
    def _fact_ids(self, schema: str | None, /) -> list[FactId]: ...
    def _facts(self, schema: str | None, /) -> list[_FactRecord]: ...
    def _halted(self, /) -> int | None: ...
    def _mem(self, /) -> _MemRecord: ...

    # Sizes and bounds
    def _set_cache_cap(
        self, /, *, cap_keys: SupportsIndex = 0, cap_bytes: SupportsIndex = 0
    ) -> None: ...

    # Clocks
    def _clock_mode(self, /) -> str: ...
    def _clock_set_mode(self, mode: str, /) -> None: ...
    def _clock_now(self, /) -> int: ...
    def _clock_next_deadline(self, /) -> int | None: ...
    def _clock_set(self, now_ns: SupportsIndex, /) -> None: ...
    def _clock_advance(self, delta_ns: SupportsIndex, /) -> None: ...
    def _wall_clock_set(self, utc_ns: SupportsIndex, /) -> None: ...

    # Recording and replay
    def _replay(
        self, stream: Buffer | Iterable[Buffer] | _Reader, chunk_size: int = 65536
    ) -> _ReplayRecord: ...
    def _record_start(self, path: str, flush: bool = False) -> None: ...
    def _record_stop(self, /) -> None: ...

    # Callbacks. A stream event's record holds the fields of its kind, each of
    # its own type, so the record is the one boundary typed dict[str, Any]
    # (PY.12): pyds.events._event takes it apart.
    def _set_stream_callback(
        self, callback: Callable[[dict[str, Any]], object] | None, /
    ) -> None: ...
    def set_call_callback(self, callback: Callable[[_CallRequest], object] | None, /) -> None: ...
    def _set_cache_callbacks(
        self,
        /,
        set_cb: Callable[[str, JsonText, int], object] | None = None,
        delete_cb: Callable[[str, str], object] | None = None,
    ) -> None: ...
    def _cache_seed(self, key: str, value_json: str | bytes, ttl_ns: SupportsIndex = 0) -> None: ...
    def _set_log_callback(self, callback: Callable[[_LogRecord], object] | None, /) -> None: ...
    def _set_metric_callback(
        self, callback: Callable[[_MetricRecord], object] | None, /
    ) -> None: ...

    # Readers
    def _platform_signature(self, /) -> _PlatformRecord: ...
    def _session_header(self, /) -> _SessionHeaderRecord: ...
    def _justifiers(self, fact_id: SupportsIndex, /) -> list[_JustifierRecord]: ...
    def _rete_network(
        self, rule_filter: str | None = None, include_occupancy: bool = False
    ) -> _NetworkRecord: ...
    def _rete_match_trace(self, fact_id: SupportsIndex, /) -> list[_TraceRecord]: ...
    def _refracted_activations(
        self, rule_filter: str | None = None, /
    ) -> list[_RefractedRecord]: ...

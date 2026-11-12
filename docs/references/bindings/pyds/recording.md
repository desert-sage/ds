<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Recording and atoms

## Recording

### `record`

**`def record(self, path: str | os.PathLike[str], /, *, flush: bool = False) -> Recording`**

Records the engine's fact stream to `path` with libds's recorder, and returns the `Recording`.

The stream's format is in [Fact stream](inv:internals:std:doc#artefacts/fact-stream), and [RFCS.3.6](inv:specs:std:label#rfcs-3-6) gives the atom each event kind records as. The file is created, or truncated if it exists. `flush=True` flushes it after every atom.

| Raises | Condition |
|---|---|
| `TypeError` | `path` is not a `str` or an `os.PathLike[str]`; `flush` is not a `bool` |
| `ValueError` | `path` holds a NUL or a lone surrogate |
| `OSError` | the file cannot be opened |
| `RuntimeError` | a recording is running |
| `MemoryError` | the recording's buffer cannot be allocated |
| [`Error`](errors.md#error), `Status.INVAL` | where the engine has had a stream event, `record` writes a `StreamHeader` above 64 KiB |
| `Error`, `Status.OOM` | where the engine has had a stream event, `record` writes a `SchemaDef` or `Slot` atom above 64 KiB |
| `Error`, `Status.IO` | where the engine has had a stream event, `record`'s write to the file fails |

```python statement
with engine.record("trace.bin", flush=True) as rec:
    engine.pump()
print(rec.closed)
```

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c, runtime/src/libds/rfcs/codec.c)*

### `Recording`

**`class Recording`**

A recording of an engine's fact stream. `Engine.record` returns one.

It writes until `close`, or the end of a `with` block. [`Engine.close`](engine.md#close) ends it too, reporting no failure.

*(Source: bindings/python/src/pyds/engine.py)*

### `path`

**`path: Path`**

The file the recording writes.

*(Source: bindings/python/src/pyds/engine.py)*

### `closed`

**`closed: bool`**

Whether the recording has stopped.

*(Source: bindings/python/src/pyds/engine.py)*

### `close`

**`def close(self) -> None`**

Stops the recording and closes its file.

A second `close` does nothing. It raises [`Error`](errors.md#error) for the recorder's first failure, and `OSError` if closing the file fails. The recording has stopped either way. The same failure is also the status of the call whose event it lost.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

## Replay

### `replay`

**`def replay(self, stream: Buffer | Iterable[Buffer] | _Reader, /, *, chunk_size: int = 65536) -> ReplayResult`**

Replays a recorded fact stream into the engine, checking it as it goes.

`stream` is a bytes-like object, a binary file read `chunk_size` bytes at a time, or an iterable of bytes-like chunks. Each chunk is released once consumed. What the engine needs is in [Replay settings](inv:integrator:std:doc#engine/lifecycle).

During a replay, `on_event` and a running `Recording` hear no event, and neither the call callback nor `on_cache_set` or `on_cache_delete` is called. `on_event` and a running `Recording` hear events again once the replay ends.

A replay that halts the engine ([halt latch](inv:integrator:std:doc#engine/lifecycle)) leaves it halted: `on_event` and a running `Recording` hear nothing more, and the next atom that calls the engine raises `Error` with `Status.ENGINE_HALTED`.

A replay that reaches the end of its recording with every compare clean returns its `ReplayResult`, for a run that halted too. [`halted`](engine.md#halted) says whether the run halted. `Status.ENGINE_HALTED` from `replay` means the replay did not reproduce the run, or met an engine already halted.

| Raises | Condition |
|---|---|
| [`TraceError`](errors.md#traceerror), `Status.FS_DIVERGENCE` | a re-derived atom differs from the record, breaks a timetag's pairing with an earlier atom, or has no recorded twin; a recorded compare atom is not re-derived; a `CacheSeed` follows an event atom or is refused; an `ExternalAssert` delivery is refused, or asserts a number of facts other than the record lists |
| `TraceError`, `Status.FS_VERSION` | the stream was written by another DS minor series |
| `TraceError`, `Status.FS_RECORDING_INCOMPLETE` | the recording's first event has a `seq` other than `0` |
| `TraceError`, `Status.FS_UNKNOWN_FACT_ID` | a `FactRetract` names an unknown `fact_id` |
| [`ArtefactMismatchError`](errors.md#artefactmismatcherror), `Status.BND_DSC_MISMATCH` or `Status.BND_DIALECT_MISMATCH` | the `StreamHeader` and the loaded artefact disagree on the dialect binding |
| `ArtefactMismatchError`, `Status.BND_INCOMPLETE` | a `StreamHeader` holds one of a 32-byte `dsc_hash` and a 32-byte `dialect_def_sha256` without the other |
| [`InputError`](errors.md#inputerror), `Status.SCHEMA_UNKNOWN` | a `FactAssert` names a schema no `SchemaDef` in the stream announced, or one the engine does not have |
| `InputError`, `Status.PARSE` | a malformed atom; a `FactAssert`'s `String` or `Json` field whose text is not well-formed UTF-8; a fact-reference handle that names no earlier record; an atom whose field number has no registry entry; an atom declares more than 2^20 bytes; a bytes-like `stream` ends mid-atom |
| [`Error`](errors.md#error), `Status.INVAL` | a `FactAssert`'s schema has more than 256 slots |
| `Error`, `Status.OOM` | an allocation fails |
| `Error` for the call's status | [`ds_engine_set_stream_callback`](inv:integrator:std:doc#callbacks/stream), [`ds_engine_schema_find`](inv:integrator:std:doc#facts/schemas), [`ds_engine_assert` or `ds_engine_retract`](inv:integrator:std:doc#facts/asserting), [`ds_engine_pump`](inv:integrator:std:doc#engine/pump), or a [clock call](inv:integrator:std:doc#engine/clock) returns a failure |
| `TypeError` | `stream` is none of the three; a chunk is not bytes-like; `chunk_size` is not an `int`, or is a `bool` |
| `ValueError` | `chunk_size` is below 1 |
| `OverflowError` | `chunk_size` is above `Py_ssize_t` |
| what `stream` raises | its `read` or its iterator raises |

`Status.CONTRACT_BREACH` for a `FactAssert` or a `PumpBoundary` does not end the replay, nor does `Status.ENGINE_HALTED` for a halt that the atom's own assert, retract, delivery or pump raises, nor do `Status.NAN_REJECTED` and `Status.SERIES_NO_BACKING` for a `PumpBoundary`. Atoms applied before a failure stay applied.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c, runtime/src/libds/rfcs/rfcs.h, runtime/src/libds/rfcs/codec.c, runtime/src/libds/recorder.c, Spec: [NDET.8.2], [NCBK.2.9], [RBND.5.2], [RBND.2.1], [RFCS.7.3], [LDET.1.10], [LTIM.2.8.5], [RFCS.19.2], [RFCS.24.2], [RFCS.26.2], [RFCS.5.3], [RFCS.5.4], [RFCS.6.3], [RFCS.6.7], [NCBK.2.11])*

### `ReplayResult`

**`ReplayResult(asserts, retracts, clocks, rule_fires, calls, withdrawals, skipped, header_verified, tail_bytes)`**

A frozen dataclass of what `replay` delivered and checked, counted by atom.

| Field | Holds |
|---|---|
| `asserts` | `FactAssert` atoms delivered, a bound's repeated refusal included; `FactEmit` atoms compared; and each fact an `ExternalAssert` delivery asserted |
| `retracts` | `FactRetract` atoms read, including one whose fact has already left working memory |
| `clocks` | `ClockAdvance` atoms applied |
| `rule_fires` | `RuleFireAnnotation` atoms compared and matching the record |
| `calls` | `CallIssued` atoms compared and matching the record |
| `withdrawals` | `FactWithdraw` atoms compared and matching the record |
| `skipped` | `SchemaDef` and `Slot` atoms; other allocated atoms with no arm; a `BoundsError` left uncompared |
| `header_verified` | whether the stream's header names the artefact this engine loaded |
| `tail_bytes` | the bytes of a partial last atom from a file or iterable; `0` for a bytes-like `stream` |

*(Source: bindings/python/src/pyds/engine.py, runtime/src/libds/rfcs/codec.c)*

### `decode_fact_body`

**`def decode_fact_body(self, schema: str, body: Buffer, /) -> dict[str, object]`**

Reads a `FactAssert` or `FactEmit` atom's `fact` field against the engine's schema named `schema`.

Each value is as `Fact.slots` [holds it](facts.md#slot-values).

| Raises | Condition |
|---|---|
| `TypeError` | `schema` is not a `str`; `body` is not bytes-like |
| `KeyError` | the engine has no schema named `schema` |
| `ValueError` | the schema has a fact-reference slot; `schema` holds a NUL or a lone surrogate |
| [`InputError`](errors.md#inputerror), `Status.PARSE` | a malformed `body`, a `String` field holding U+0000 included; a `String` or `Json` field's text is not well-formed UTF-8; a `Json` field's text does not parse; a non-nullable `Json` slot's field is absent, or its document is `null` at its root |
| [`ExecutionError`](errors.md#executionerror), `Status.JSON_LIMIT` | a `Json` field is over a tree limit |
| `MemoryError`, or `Error` with `Status.OOM` | an allocation fails |
| `Error` for the call's status | [`ds_engine_schema_find`](inv:integrator:std:doc#facts/schemas) returns a failure |

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c, runtime/src/libds/rfcs/codec.c, Spec: [LSTR.1.5], [LGRA.5.8.6], [RFCS.6.3])*

## Atoms

### `pyds.atoms`

**`from pyds import atoms`**

The module of libds's atom reader and framing, for a `.dsc` or a fact stream.

An atom's field number is an `int`, or an object with `__index__`. A number outside `0..2**32-1` raises `OverflowError`. Malformed input raises [`InputError`](errors.md#inputerror) with `Status.PARSE`, naming the byte libds stopped at. The container formats are in [Fact stream](inv:internals:std:doc#artefacts/fact-stream).

```python statement
from pyds import atoms
for atom in atoms.iter_atoms(b"", partial=True):
    print(atom.kind, atom.offset)
```

*(Source: bindings/python/src/pyds/atoms.py, bindings/python/src/_pyds/atoms.c)*

### `AtomKind`

**`class AtomKind(enum.IntEnum)`**

An allocated atom.

A member's value is the atom's field number, its name is the body message in constant spelling, and its `message` property is the body message: `AtomKind.FACT_ASSERT` is `1`, and its `message` is `"FactAssert"`. `field in AtomKind` is whether a number is allocated. The atoms are in [Fact stream](inv:internals:std:doc#artefacts/fact-stream).

*(Source: bindings/python/src/pyds/_atom_registry.py)*

### `Atom`

**`Atom(kind, body, offset, end)`**

A frozen dataclass of one atom of a container, as libds framed it.

`kind` is an `AtomKind`, or the `int` field number of an atom this build has no entry for. `body` is `bytes`. `offset` is where the atom's frame starts, and `end` is where the next atom starts.

`message()` parses `body` as its kind's generated class in `pyds.proto`, and raises `LookupError` for a kind this build has no entry for.

*(Source: bindings/python/src/pyds/atoms.py)*

### `iter_atoms`

**`def iter_atoms(data: Buffer, /, *, partial: bool = False) -> Iterator[Atom]`**

Yields a container's atoms in order, one per step.

It judges no field number: one this build has no registry entry for is yielded as its `int`. A partial trailing atom raises, unless `partial`: then the iteration ends before it. A frame no append could repair raises either way.

*(Source: bindings/python/src/pyds/atoms.py)*

### `frame`

**`def frame(kind: AtomKind | int, body: Buffer, /) -> bytes`**

Returns one framed atom.

A number with no registry entry raises `ValueError`.

*(Source: bindings/python/src/pyds/atoms.py)*

### `container_of`

**`def container_of(data: Buffer, /) -> Container`**

Returns a container's type from its first atom's number, [RFCS.19.4](inv:specs:std:label#rfcs-19-4).

*(Source: bindings/python/src/pyds/atoms.py)*

### `Container`

**`class Container(enum.StrEnum)`**

What `container_of` returns.

Its members and their values are `UNKNOWN` `"unknown"`, `STREAM` `"stream"` and `DSC` `"dsc"`.

*(Source: bindings/python/src/pyds/atoms.py)*

### `wire_fields`

**`def wire_fields(body: Buffer, /) -> list[tuple[int, int, int | bytes]]`**

Returns a body's top-level fields, each as `(field, wire, value)`.

`value` is `bytes` for wire type 2, and otherwise an `int`.

*(Source: bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/atoms.c)*

### `visit_atom`

**`def visit_atom(field: SupportsIndex, body: Buffer, /) -> list[tuple[str, str | None, int, int, int, str | None, _VisitValue]]`**

Returns libds's typed walk of a body, each visited field as `(kind, name, number, index, depth, message, value)`.

`kind` is `"int"`, `"uint"`, `"double"`, `"bool"`, `"enum"`, `"string"`, `"bytes"`, `"enter"` or `"leave"`. `value` is an `int`, `float`, `bool`, `str` or `bytes` as `kind` names it, a `(number, name)` tuple for `"enum"`, and `None` for `"enter"` and `"leave"`.

*(Source: bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/atoms.c)*

### `message_name`

**`def message_name(field: SupportsIndex, /) -> str | None`**

Returns the proto message of the atom `field` names, or `None` for a number with no entry.

*(Source: bindings/python/src/pyds/atoms.py, bindings/python/src/pyds/_pyds.pyi)*

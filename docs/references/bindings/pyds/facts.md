<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Facts and values

## Asserting and retracting

### `assert_`

**`def assert_(self, schema: str, /, **slots: object) -> FactId`**

Asserts a fact through [`ds_engine_assert`](inv:integrator:std:doc#facts/asserting), and returns its id.

`schema` is the schema's own name, as [`ds_engine_schema_find`](inv:integrator:std:doc#facts/schemas) takes it. Each keyword names a slot, in any order, and its value follows [Slot values](#slot-values). An omitted slot declared `T?` is null.

| Raises | Condition |
|---|---|
| `KeyError` | the engine has no schema named `schema`; a fact-reference target is not live |
| `TypeError` | a slot not declared `T?` is omitted; a keyword names no slot; a value's type is not one its slot takes |
| `ValueError` | `schema`, a `String` value, or a `Json` string or object key holds a NUL |
| `OverflowError` | an integer is outside `int64` |

```python statement
fid = engine.assert_("Reading", id="a", level=1.5, n=1, label="x", ok=True, ts=0)
engine.retract(fid)
```

*(Source: bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/engine.c)*

### `assert_external`

**`def assert_external(self, data: Buffer | EncodedFact, /) -> None`**

Asserts a `FactExternal` through [`ds_engine_assert_external`](inv:integrator:std:doc#facts/asserting).

`data` is a bytes-like object, or an `EncodedFact`, whose `data` is taken. It returns no fact.

*(Source: bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/engine.c)*

### `retract`

**`def retract(self, fact_id: SupportsIndex, /) -> None`**

Retracts a live fact through [`ds_engine_retract`](inv:integrator:std:doc#facts/asserting).

An id with no live fact raises `KeyError`, and a `bool` or a value that is not an integer raises `TypeError`.

*(Source: bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/engine.c)*

### Slot values

How each [`SlotType`](program.md#slottype) crosses [`ds_slot_value_t`](inv:integrator:std:doc#facts/values).

| `SlotType` | `assert_` takes | `Fact.slots` holds |
|---|---|---|
| `INT`, `TIME`, `DATE`, `DURATION` | an `int`, or an object with `__index__`; no `bool` | `int` |
| `FLOAT` | a `float`; no `int` | `float` |
| `STRING` | a `str`, or `bytes` or `bytearray` holding its UTF-8, passed unchanged | `str` |
| `BOOL` | a `bool` | `bool` |
| `JSON` | a tree of `None`, `bool`, `int`, `float`, `str`, `list`, `tuple` and `dict` with `str` keys | `JsonText` |
| `BYTES` | `bytes` or `bytearray` | `bytes` |
| `SCHEMA` | the target's `FactId`, or an object with `__index__`; no `bool` | the target's `FactId`, live or not |

`None` passes a null for a slot of any type, and `ds_engine_assert` judges it. A slot that holds null reads as `None`.

A `Json` tree nested deeper than `DS_JSON_MAX_DEPTH` is refused with `DS_ERR_JSON_LIMIT`.

```{warning}
A `str` in a `Json` slot is a Json string, and is not parsed. `JsonText` is a `str`, so a `JsonText` read from a `Json` slot and asserted into one stores a Json string.
```

*(Source: bindings/python/src/_pyds/engine.c)*

## Working memory

### `Facts`

**`class Facts(Mapping[FactId, Fact])`**

Working memory by fact id, read through [`ds_engine_fact_count`, `ds_engine_for_each_fact` and the `ds_fact_get_*` calls](inv:integrator:std:doc#facts/reading). `Engine.facts` returns one.

It reads the engine at each use. `facts[fid]` returns a `Fact`, and raises `KeyError` for an id with no live fact. `fid in facts` is whether the fact is live. A key is an `int`, or an object with `__index__`; a `bool` or another type is no fact's key.

Iteration is in id order, over the ids live when it starts. A fact retracted during the walk raises `KeyError` when its value is read.

Inside a callback, `facts[fid]` and `in` answer, and a fact being retracted is still live in its own stream callback. `len`, iteration and `of` follow [Re-entry](inv:integrator:std:doc#conventions/handles).

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `of`

**`def of(self, schema: str, /) -> list[Fact]`**

Returns the live facts of one schema, in id order.

`schema` is the schema's own name, as [`ds_engine_schema_find`](inv:integrator:std:doc#facts/schemas) takes it. A name the engine has no schema by raises `ValueError`, and a `schema` that is not a `str` raises `TypeError`.

```python statement
for fact in engine.facts.of("Reading"):
    print(fact.id, fact.slots["level"])
```

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `Fact`

**`Fact(id, schema, slots, asserted_ns, ttl_deadline_ns)`**

A frozen dataclass holding a snapshot of one fact, read by the [`ds_fact_get_*`](inv:integrator:std:doc#facts/reading) calls.

It holds nothing of the engine's. `schema` is the schema's own name, as [`ds_schema_get_name`](inv:integrator:std:doc#facts/schemas) reads it. `slots` is a read-only mapping from slot name to value. `ttl_deadline_ns` is `None` for a fact with no deadline. Two `Fact`s are equal when every field is, and hash alike when equal.

*(Source: bindings/python/src/pyds/facts.py)*

### `FactId`

**`class FactId(int)`**

A fact's id, as [`ds_fact_get_id`](inv:integrator:std:doc#facts/reading) reads it.

Ids increase and are never reused. `str()` gives the number, and `repr()` gives `FactId(n)`.

*(Source: bindings/python/src/pyds/facts.py)*

## Value types

### `EncodedFact`

**`class EncodedFact(tuple[str, int | None, bytes])`**

A fact passed as a call argument: [`ds_encoded_fact_t`](inv:integrator:std:doc#facts/values), as a struct sequence.

`asserted_at` is `None` when `asserted_at_set` is false. `data` is `bytes`, and `assert_external` takes it.

*(Source: bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/engine.c)*

### `JsonText`

**`class JsonText(str)`**

A `Json` value, as its canonical JSON text.

The text is not parsed. `isinstance(v, JsonText)` tells a `Json` value from a `String`. `repr()` gives `JsonText('...')`.

*(Source: bindings/python/src/pyds/_pyds.pyi, bindings/python/src/_pyds/engine.c)*

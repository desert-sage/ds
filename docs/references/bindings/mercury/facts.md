<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Facts and values

## Asserting and retracting

### `assert_fact`

**`:- pred assert_fact(string::in, list(storable)::in, assert_step::out, session::in, session::out) is det.`**

Asserts a fact of the named schema, one value per slot in declaration order: the capability of [`ds_engine_assert`](inv:integrator:std:doc#facts/asserting).

The fact's deadline is its schema's TTL. The first row that applies is the refusal.

| `error` with [`status`](errors.md#status) | Condition |
|---|---|
| `engine_halted` | the session has halted |
| `schema_unknown` | no schema a host can see has this [own name](inv:integrator:std:doc#facts/schemas) |
| `inval` | the list is not one value per slot |
| `slot_type_mismatch` | a value's constructor is not one its slot takes; a `fact_ref` names a live fact of another schema, or no live fact; or a slot not declared nullable holds `null`, or, for a `Json` slot, `json(j_null)` |
| `nan_rejected` | a `Float` value is NaN |
| `json_limit` | a `json` value passes a [`DS_JSON_MAX_*` limit](inv:integrator:std:doc#facts/json) |
| `json_nonfinite` | a `json` value holds an infinite or NaN float |
| `encoding` | a `text` value, or a string or key in a `json` value, is not well-formed UTF-8 |
| `time_range` | a `Date` value is outside its range |
| `inval` | a [`TimeZoneOffset` row](inv:integrator:std:doc#facts/asserting) is refused |
| `time_range` | the fact's deadline, or the deadline this assert's first sample would give a held cache seed, is outside the `Time` range |
| `contract_breach` | a `String` value passes its slot's `capacity`, a series refuses a sample at its `capacity`, or the `initial` block passes a cache bound |

A `json(j_null)` in a nullable `Json` slot is stored as `null`.

Every row but `contract_breach` leaves `assert_step_reports` free of stream events. A `contract_breach` reports the input's [`fact_assert` and a `bounds_error`](reports.md#event_kind).

If the call halts the engine, the outcome is `error` with `engine_halted`, whatever else it did.

```mercury declaration
:- pred assert_reading(assert_outcome::out, session::in, session::out) is det.
assert_reading(Outcome, !S) :-
    assert_fact("Reading", [text("a"), float(1.5), int(1i64), text("x"), bool(yes), int(0i64)], Step, !S),
    Outcome = Step ^ assert_step_outcome.
```

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, runtime/mercury/src/ds.fact.m, runtime/mercury/src/ds.wm.m, Spec: [NFCT.2.11], [NFCT.2.3], [LNUL.3.4], [NCBK.2.9], [LTIM.10.9], [LSTR.11.3], [LSER.13.14], [LGRA.5.8.10])*

### `assert_step`

**`:- type assert_step ---> assert_step(assert_step_outcome :: assert_outcome, assert_step_reports :: list(report), assert_step_duties :: list(duty)).`**

What [`assert_fact`](#assert_fact) did, reported and left the host to do.

`assert_step_reports` holds [`report`](reports.md#report)s, in the order the call emitted them. `assert_step_duties` is the [`duty`](reports.md#duty) for each cache expiry the assert's own reads met, in the order it produced them.

*(Source: bindings/mercury/src/mercury_ds.session.m)*

### `assert_outcome`

**`:- type assert_outcome ---> asserted(fact_id) ; unchanged(fact_id) ; replaced(fact_id, fact_id) ; error(ds_error).`**

What an assert did to working memory, as [Reassertion](inv:integrator:std:doc#facts/asserting) states.

| Member | Meaning |
|---|---|
| `asserted(Id)` | a new fact entered |
| `unchanged(Id)` | the same fact was live, and working memory is unchanged; `assert_step_reports` holds its `fact_assert` |
| `replaced(Old, New)` | `New` entered and replaced `Old` |
| `error(E)` | a [`ds_error`](errors.md#ds_error): a refusal, or a halt, as [`assert_fact`](#assert_fact) states |

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, Spec: [RFCS.6.7])*

### `retract_fact`

**`:- pred retract_fact(fact_id::in, step::out, session::in, session::out) is det.`**

Retracts a live fact: the capability of [`ds_engine_retract`](inv:integrator:std:doc#facts/asserting).

| `step_outcome` | Condition |
|---|---|
| `error`, `engine_halted` | the session had halted, or this call halted the engine |
| `error`, `not_found` | no live fact has this id |

*(Source: bindings/mercury/src/mercury_ds.session.m, Spec: [NCBK.2.9])*

### `assert_external`

**`:- pred assert_external(bitmap::in, step::out, session::in, session::out) is det.`**

Asserts a fact published by another tier, from a `FactExternal`'s bytes: the capability of [`ds_engine_assert_external`](inv:integrator:std:doc#facts/asserting).

The runtime's `encode_fact_external` writes the bytes from a publish's `fact_external`. Each fact it asserts takes this engine's own event id, and its lifetime from this program's schema. A reference equal to a live fact is that fact.

Refused with nothing asserted:

| `error` with | Condition |
|---|---|
| `engine_halted` | the session has halted |
| `parse` | the bytes are not a `FactExternal`, nest deeper than 16, hold a string that is not well-formed UTF-8 or holds U+0000, or hold `Json` text that [`json_from_text`](#json_from_text) refuses with `parse` |
| `schema_unknown` | the engine holds no schema of this own name that a record may name |
| `schema_hash_mismatch` | a schema of the same name has another shape |
| `slot_type_mismatch` | a value is not one its slot takes |
| `nan_rejected` | a `Float` value is NaN |
| `json_limit` | a `Json` value passes a limit |
| `fact_ref_conflict` | a reference meets a live fact with its key and other values |
| `time_range` | a `Date` value is outside its range, a fact's TTL deadline would fall outside the `Time` range, or the call's sample, the engine's first, would give a held cache seed a deadline outside it |
| `inval` | a [`TimeZoneOffset`](inv:integrator:std:doc#facts/asserting) fact it holds is malformed |
| `contract_breach` | a `String` value passes its slot's `capacity`, which reports no `bounds_error`, or, on the engine's first step, the `initial` block passes a cache bound |

Only a halt an assert raises stops the delivery after these checks. The outcome is `error` with `engine_halted`, and a fact already asserted is not taken back. The state after the halt is as [Halt latch](inv:integrator:std:doc#engine/lifecycle) states.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.fact_receive.m, runtime/mercury/src/ds.wire.m, runtime/mercury/src/ds.json_text.m, Spec: [NCBK.10.4], [RFCS.23.7], [NLFC.9.5], [LSTR.1.5], [LSTR.11.3], [LTIM.10.9], [RFCS.6.7], [LERR.1.4.7], [LGRA.24.3])*

## Values

### `storable`

**`:- type storable =< ds_value ---> int(int64) ; float(float) ; text(string) ; bool(bool) ; bytes(bitmap) ; json(json_term) ; fact_ref(fact_id) ; null.`**

A value a slot holds: the subtype of the runtime's `ds_value` with the constructors a slot takes. A value read back is one too.

| Slot's declared type | Constructor |
|---|---|
| `Int`, `Time`, `Date`, `Duration` | `int`, the value as its integer |
| `Float` | `float` |
| `String` | `text` |
| `Bool` | `bool` |
| `Bytes` | `bytes` |
| `Json` | `json` |
| a schema's name | `fact_ref` |
| any, declared nullable | `null` |

*(Source: bindings/mercury/src/mercury_ds.value.m, runtime/mercury/src/ds.fact.m)*

### `to_value`

**`:- func to_value(storable) = ds_value.`**

The runtime's value a `storable` is.

*(Source: bindings/mercury/src/mercury_ds.value.m)*

### `json_from_text`

**`:- func json_from_text(string) = maybe_error(json_term, ds_error).`**

A `Json` value from its text, read with the grammar and limits of [`ds_json_parse`](inv:integrator:std:doc#facts/json).

The first row that applies is the refusal.

| `error` with | Condition |
|---|---|
| `json_limit` | the text passes the text limit |
| `encoding` | the text is not well-formed UTF-8 |
| `json_limit` | the value passes the depth, node or string-byte limit |
| `parse` | the text is not one JSON document: its syntax, a repeated key, an integer outside `int64`, a float that rounds to an infinity, a `\u0000` escape, a surrogate escape that is half of no pair, or anything but whitespace after it |

```mercury declaration
:- func json_canonical(string) = maybe_error(string, ds_error).
json_canonical(Text) = Result :-
    Parsed = json_from_text(Text),
    ( Parsed = ok(J), Result = json_to_text(J)
    ; Parsed = error(E), Result = error(E) ).
```

*(Source: bindings/mercury/src/mercury_ds.value.m, Spec: [LSTR.8.5], [LGRA.5.8.10])*

### `json_to_text`

**`:- func json_to_text(json_term) = maybe_error(string, ds_error).`**

A `Json` value's text, byte for byte what [`ds_json_serialize`](inv:integrator:std:doc#facts/json) writes.

A value holding an infinite or NaN float is refused with `json_nonfinite`.

*(Source: bindings/mercury/src/mercury_ds.value.m)*

## Working memory

### `fact_view`

**`:- type fact_view ---> fact_view(fact_view_id :: fact_id, fact_view_schema :: string, fact_view_slots :: list(storable), fact_view_asserted :: instant, fact_view_deadline :: maybe(instant)).`**

A fact as a host reads it, through the capability of the [`ds_fact_get_*`](inv:integrator:std:doc#facts/reading) calls: a snapshot taken at the read.

| Field | Holds |
|---|---|
| `fact_view_id` | the fact's id, as [`ds_fact_get_id`](inv:integrator:std:doc#facts/reading) reads it; ids increase and are never reused |
| `fact_view_schema` | the schema's own name, as [`ds_schema_get_name`](inv:integrator:std:doc#facts/schemas) reads it |
| `fact_view_slots` | the slot values, in declaration order |
| `fact_view_asserted` | when the fact entered working memory |
| `fact_view_deadline` | when it expires, or `no` for never |

*(Source: bindings/mercury/src/mercury_ds.value.m, runtime/mercury/src/ds.id.m, runtime/mercury/src/ds.wm.m)*

### `fact_count`

**`:- func fact_count(session) = read(int).`**

How many live facts a host can see: the capability of [`ds_engine_fact_count`](inv:integrator:std:doc#facts/reading).

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m)*

### `facts`

**`:- func facts(session) = read(list(fact_view)).`**

Every live fact a host can see: the capability of [`ds_engine_for_each_fact`](inv:integrator:std:doc#facts/reading).

The list runs schema by schema, in schema-id order, and each schema's facts in insertion order.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m, runtime/mercury/src/ds.wm.m)*

### `search_fact`

**`:- pred search_fact(session::in, fact_id::in, read(fact_view)::out) is semidet.`**

The live fact with this id: the capability of [`ds_engine_fact_find`](inv:integrator:std:doc#facts/reading).

It fails if a host can see no live fact with this id, and answers `halted` after the halt, whatever the id.

*(Source: bindings/mercury/src/mercury_ds.session.m)*

### `lookup_fact`

**`:- func lookup_fact(session, fact_id) = read(fact_view).`**

[`search_fact`](#search_fact), throwing an exception where that fails.

*(Source: bindings/mercury/src/mercury_ds.session.m)*

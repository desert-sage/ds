<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The program

## Schemas

### `Schemas`

**`class Schemas(Mapping[str, Schema])`**

The schemas an engine knows, by own name, read through [`ds_engine_schema_count`, `ds_engine_schema_find` and `ds_engine_schema_at`](inv:integrator:std:doc#facts/schemas). `Engine.schemas` returns one.

It reads the engine at each use, and iterates in the engine's order. A name with no schema, or a key that is not a `str`, raises `KeyError`.

*(Source: bindings/python/src/pyds/engine.py)*

### `Schema`

**`Schema(name, lifecycle, ttl_ns, slots, source, proto_source)`**

A frozen dataclass holding a snapshot of one schema, read by the [`ds_schema_get_*`](inv:integrator:std:doc#facts/schemas) calls.

| Field | Holds |
|---|---|
| `lifecycle` | a `Lifecycle` |
| `slots` | a `tuple` of `Slot`, in declaration order |
| `source` | a `Source`, or `None` when `ds_schema_get_source` gives no file |
| `proto_source` | a `str`, or `None` when `ds_schema_get_proto_source` gives no text |

`name` and `ttl_ns` hold what their calls read.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/schema.c)*

### `Slot`

**`Slot(name, type, schema_ref, nullable, identity, sampled, retained, hydration_eligible, tolerance, docstring)`**

A frozen dataclass of [`ds_slot_desc_t`](inv:integrator:std:doc#facts/schemas).

| Field | Holds |
|---|---|
| `type` | a `SlotType` |
| `schema_ref` | the referenced schema's own name, or `None` for a slot that is not a fact reference |
| `identity` | an `IdentityRole`, or `None` for `DS_IDENTITY_UNSPECIFIED` |
| `tolerance` | a `float`, or `None` when `has_tolerance` is false |
| `docstring` | a `str`, or `None` |

`name`, `nullable`, `sampled`, `retained` and `hydration_eligible` hold their `ds_slot_desc_t` members.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/schema.c)*

### `SlotType`

**`class SlotType(StrEnum)`**

A slot's declared type: [`ds_slot_type_t`](inv:integrator:std:doc#facts/schemas).

Its members and their values are `INT` `"Int"`, `FLOAT` `"Float"`, `STRING` `"String"`, `BOOL` `"Bool"`, `JSON` `"Json"`, `BYTES` `"Bytes"`, `TIME` `"Time"`, `DATE` `"Date"`, `DURATION` `"Duration"` and `SCHEMA` `"Schema"`.

*(Source: bindings/python/src/pyds/enums.py, bindings/python/src/_pyds/schema.c)*

### `IdentityRole`

**`class IdentityRole(StrEnum)`**

A slot's identity role: [`ds_identity_role_t`](inv:integrator:std:doc#facts/schemas).

Its members and their values are `KEY` `"key"`, `MUTABLE` `"mutable"` and `ENGINE` `"engine"`.

*(Source: bindings/python/src/pyds/enums.py, bindings/python/src/_pyds/schema.c)*

### `Lifecycle`

**`class Lifecycle(StrEnum)`**

A schema's lifecycle: [`ds_schema_lifecycle_t`](inv:integrator:std:doc#facts/schemas).

Its members and their values are `LOGICAL` `"logical"`, `TTL` `"ttl"` and `INTERNAL` `"internal"`.

*(Source: bindings/python/src/pyds/enums.py, bindings/python/src/_pyds/schema.c)*

## Rules

### `Rules`

**`class Rules(Mapping[str, Rule])`**

The loaded program's rules, by name, read through [`ds_engine_rule_meta_count`, `ds_engine_rule_meta_at` and `ds_engine_rule_meta_find`](inv:integrator:std:doc#introspection/metadata). `Engine.rules` returns one.

It reads the engine at each use, and iterates in the order the program declares them. A name with no rule, or a key that is not a `str`, raises `KeyError`.

*(Source: bindings/python/src/pyds/engine.py)*

### `Rule`

**`Rule(name, cooldown_ns, source, debug_name_template)`**

A frozen dataclass of [`ds_rule_meta_view_t`](inv:integrator:std:doc#introspection/metadata).

`cooldown_ns` is `None` when `has_cool` is false, `source` a `Source` or `None` when `has_srcr` is false, and `debug_name_template` `None` when `has_dnam` is false.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/rule_meta.c)*

### `Source`

**`Source(file, line, column)`**

A frozen dataclass of a declaration's position in the program's source, as `Schema.source` and `Rule.source` hold it.

*(Source: bindings/python/src/pyds/engine.py)*

## Program source

### `Sources`

**`class Sources(Mapping[int, ProgramSource])`**

The loaded program's source files, by module id, read through [`ds_engine_ds_source_count` and `ds_engine_ds_source_at`](inv:integrator:std:doc#introspection/metadata). `Engine.sources` returns one.

It reads the engine at each use, and iterates in the artefact's order. It is empty before a load. A key is an `int`, or an object with `__index__`. An id with no source, a `bool` or another type raises `KeyError`.

*(Source: bindings/python/src/pyds/engine.py)*

### `ProgramSource`

**`ProgramSource(module_id, file, text)`**

A frozen dataclass of [`ds_ds_source_view_t`](inv:integrator:std:doc#introspection/metadata).

`text` is a `str`.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

### `LineSpans`

**`class LineSpans(Mapping[int, LineSpan])`**

The source position of each attributed Rete node, by node id, read through [`ds_engine_line_span_count`, `ds_engine_line_span_at` and `ds_engine_line_span_find`](inv:integrator:std:doc#introspection/metadata). `Engine.line_spans` returns one.

It reads the engine at each use, and iterates in the artefact's order. It is empty before a load. A key is an `int`, or an object with `__index__`. A node with no span, an id outside `uint32`, a `bool` or another type raises `KeyError`.

*(Source: bindings/python/src/pyds/engine.py)*

### `LineSpan`

**`LineSpan(node_id, module_id, file, line, column)`**

A frozen dataclass of [`ds_line_span_view_t`](inv:integrator:std:doc#introspection/metadata).

`file` is `None` when the artefact carries no source for the module. `line` and `column` hold `ds_line` and `ds_col`.

*(Source: bindings/python/src/pyds/engine.py, bindings/python/src/_pyds/engine.c)*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Schemas

## Types

### `ds_schema_lifecycle_t`

**`typedef enum { DS_SCHEMA_LIFECYCLE_LOGICAL = 0, DS_SCHEMA_LIFECYCLE_TTL = 1, DS_SCHEMA_LIFECYCLE_INTERNAL = 2 } ds_schema_lifecycle_t;`**

How a fact of a schema leaves working memory.

| Member | Meaning |
|---|---|
| `DS_SCHEMA_LIFECYCLE_LOGICAL` | the fact stays until it is retracted: by [`ds_engine_retract`](asserting.md#ds_engine_retract), by a rule's retract action, or by truth maintenance when a [logical justifier](../introspection/network.md#ds_engine_get_justifiers) ends. `ttl_ns` is `0` |
| `DS_SCHEMA_LIFECYCLE_TTL` | the fact carries a deadline, and the [pump](../engine/pump.md#ds_engine_pump)'s sweep retracts it once the deadline passes. `ttl_ns` is above `0` |
| `DS_SCHEMA_LIFECYCLE_INTERNAL` | a schema the engine owns and asserts itself: the built-in fault schemas `ComputationError` and `TypeError` |

A schema the artefact declares `explicit`, `logical` or `activation` reads as `DS_SCHEMA_LIFECYCLE_LOGICAL`. An `internal` schema is told from a program's own by this value, and not by its name.

*(libds.h: ds_schema_lifecycle_t, Spec: [NFCT.4.1], [NFCT.4.5], [NDBG.2.2])*

### `ds_slot_type_t`

**`typedef enum { … } ds_slot_type_t;`**

A slot's schema-declared type.

| Member | Meaning |
|---|---|
| `DS_SLOT_TYPE_INT` | an integer |
| `DS_SLOT_TYPE_FLOAT` | a float |
| `DS_SLOT_TYPE_STRING` | a string |
| `DS_SLOT_TYPE_BOOL` | a boolean |
| `DS_SLOT_TYPE_JSON` | a [`ds_json_t`](json.md) tree |
| `DS_SLOT_TYPE_SCHEMA` | a reference to a fact; `schema_ref` is non-NULL |
| `DS_SLOT_TYPE_BYTES` | binary |
| `DS_SLOT_TYPE_TIME` | an instant's nanoseconds since the epoch, UTC, with no zone |
| `DS_SLOT_TYPE_DATE` | days since the epoch |
| `DS_SLOT_TYPE_DURATION` | nanoseconds |

The value kind each type takes is in [Slot value kinds](asserting.md#slot-value-kinds).

*(libds.h: ds_slot_type_t)*

### `ds_identity_role_t`

**`typedef enum { DS_IDENTITY_UNSPECIFIED = 0, DS_IDENTITY_KEY = 1, DS_IDENTITY_MUTABLE = 2, DS_IDENTITY_ENGINE = 3 } ds_identity_role_t;`**

A slot's identity role.

| Member | Meaning |
|---|---|
| `DS_IDENTITY_UNSPECIFIED` | a slot of a schema that is not `logical` |
| `DS_IDENTITY_KEY` | the slot is in the schema's identity key |
| `DS_IDENTITY_MUTABLE` | the slot is payload |
| `DS_IDENTITY_ENGINE` | the slot is `ts`, outside the identity key and the no-op comparison |

What the key does at an assert is in [Reassertion](asserting.md#reassertion).

*(libds.h: ds_identity_role_t, ds_slot_desc_t, Spec: [NFCT.1.4.1])*

### `ds_slot_desc_t`

**`typedef struct ds_slot_desc { const char *name; ds_slot_type_t type; const ds_schema_t *schema_ref; bool sampled; bool retained; bool has_tolerance; double tolerance; const char *docstring; bool hydration_eligible; ds_identity_role_t identity_role; bool nullable; } ds_slot_desc_t;`**

One slot of a loaded schema.

| Member | Holds |
|---|---|
| `name` | the slot's name, the engine's own string, valid for the engine's life |
| `type` | the declared type |
| `schema_ref` | a borrow of the referenced schema; non-NULL exactly when `type` is `DS_SLOT_TYPE_SCHEMA` |
| `sampled`, `retained` | per-slot markers the author declared |
| `has_tolerance`, `tolerance` | whether a tolerance was declared, and its value as a `double`; `has_tolerance` tells `tolerance 0` from none |
| `docstring` | an optional docstring, engine-owned like `name`; may be NULL |
| `hydration_eligible` | true when a Hydration atom in the artefact names the slot; false otherwise |
| `identity_role` | the slot's [identity role](#ds_identity_role_t) |
| `nullable` | the slot was declared `T?` |

A slot's index among its schema's descriptors is its position in an [assert](asserting.md#ds_engine_assert). The layout is in [Data model](inv:internals:std:doc#overview/data-model).

*(libds.h: ds_slot_desc_t, Spec: [NFCT.1.4.1], [IDAT.5.3], [IDAT.5.4])*

## Registry

### Schema registry

An engine's schemas are those a [load](../engine/loading.md#ds_engine_load_dsc) registered, with the engine's built-in `internal` schemas among them.

A [`ds_schema_t`](../conventions/handles.md#ds_schema_t) pointer from any of these calls is a borrow, valid for the engine's lifetime.

*(libds.h: Schema registry, ds_engine_schema_at, Spec: [NFCT.1.1], [NDBG.2.2], [IDAT.5.1])*

### `ds_engine_schema_count`

**`ds_result_t ds_engine_schema_count(ds_engine_t *engine, size_t *out);`**

Reads the number of schemas registered on this engine.

Errors: `DS_ERR_INVAL` for a NULL `engine` or `out`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry); `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_schema_count, Spec: [NDBG.2.2], Source: runtime/src/libds/schema.c)*

### `ds_engine_schema_find`

**`ds_result_t ds_engine_schema_find(ds_engine_t *engine, const char *type_name, const ds_schema_t **out);`**

Looks a schema up by its [own name](inv:author:std:doc#lang/imports).

`type_name` is the own name, `plant.sensors.Reading` for a schema of that library, and never an alias.

The status is `DS_OK` on a hit and on a miss, and `*out` is NULL on a miss. Errors: `DS_ERR_INVAL` for a NULL `engine`, `type_name` or `out`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry); `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_schema_find, Spec: [IDAT.5.5], [NFCT.1.4.2], Source: runtime/src/libds/schema.c)*

### `ds_engine_schema_at`

**`ds_result_t ds_engine_schema_at(ds_engine_t *engine, size_t index, const ds_schema_t **out);`**

Reads the schema at `index`, from 0 to the count less one.

Errors: `DS_ERR_NOT_FOUND` for an index out of range; `DS_ERR_INVAL` for a NULL `engine` or `out`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry); `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_schema_at, Source: runtime/src/libds/schema.c)*

## Accessors

### Schema accessors

The `ds_schema_get_*` calls read a `ds_schema_t` handle.

Each returns `DS_OK` with its out-pointers set. Strings are engine-owned, and valid for the engine's lifetime. Each returns `DS_ERR_INVAL` for a NULL `schema` or a required out-pointer. After a halt, each answers as [Handle reads after a halt](reading.md#handle-reads-after-a-halt) states.

*(libds.h: Schema introspection, Source: runtime/src/libds/schema.c)*

### `ds_schema_get_name`

**`ds_result_t ds_schema_get_name(const ds_schema_t *schema, const char **out);`**

Reads the schema's [own name](inv:author:std:doc#lang/imports).

*(libds.h: ds_schema_get_name, Spec: [NDBG.2.2], [NFCT.1.4.2])*

### `ds_schema_get_lifecycle`

**`ds_result_t ds_schema_get_lifecycle(const ds_schema_t *schema, ds_schema_lifecycle_t *out);`**

Reads the schema's [lifecycle](#ds_schema_lifecycle_t).

*(libds.h: ds_schema_get_lifecycle, Spec: [NDBG.2.2])*

### `ds_schema_get_ttl_ns`

**`ds_result_t ds_schema_get_ttl_ns(const ds_schema_t *schema, uint64_t *out);`**

Reads the schema's TTL, in nanoseconds.

*(libds.h: ds_schema_get_ttl_ns, Spec: [NDBG.2.2])*

### `ds_schema_get_slot_count`

**`ds_result_t ds_schema_get_slot_count(const ds_schema_t *schema, uint32_t *out);`**

Reads the number of slots the schema declares.

*(libds.h: ds_schema_get_slot_count, Spec: [NDBG.2.2])*

### `ds_schema_get_slot`

**`ds_result_t ds_schema_get_slot(const ds_schema_t *schema, uint32_t index, ds_slot_desc_t *out);`**

Copies the descriptor of slot `index` into `*out`.

It also returns `DS_ERR_NOT_FOUND` for an index out of range.

*(libds.h: ds_schema_get_slot, Spec: [NFCT.1.4.2], Source: runtime/src/libds/schema.c)*

### `ds_schema_get_source`

**`ds_result_t ds_schema_get_source(const ds_schema_t *schema, const char **out_file, uint32_t *out_line, uint32_t *out_col);`**

Reads the schema's source location, from the artefact's `SchemaSource` atom.

All three out-pointers may be NULL. `*out_file` is NULL when the artefact has no `SchemaSource` for the schema.

*(libds.h: ds_schema_get_source)*

### `ds_schema_get_proto_source`

**`ds_result_t ds_schema_get_proto_source(const ds_schema_t *schema, const char **out_text, size_t *out_len);`**

Reads the schema's generated `.proto` definition, from the artefact's `SchemaDef` atom.

`*out_text` is NULL when the artefact has no `SchemaDef` for the schema. `*out_len`, if `out_len` is non-NULL, is the byte length excluding the NUL terminator.

*(libds.h: ds_schema_get_proto_source)*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Values

## Kinds

### `ds_kind_t`

**`typedef enum { … } ds_kind_t;`**

The value kinds a slot and a call argument share, in one number space.

| Member | Number | Union member |
|---|---|---|
| `DS_KIND_INT` | 0 | `v.i` |
| `DS_KIND_FLOAT` | 1 | `v.f` |
| `DS_KIND_STRING` | 2 | `v.s` |
| `DS_KIND_BOOL` | 3 | `v.b` |
| `DS_KIND_JSON` | 4 | `v.json` |
| `DS_KIND_BYTES` | 6 | `v.bytes` |
| `DS_KIND_NULL` | 7 | none |

A common kind has the same number in `ds_kind_t`, `ds_slot_kind_t` and `ds_arg_kind_t`, so converting between the three is the identity, and a common union member has one name in all three value types. Number 5 is `DS_SLOT_FACT_REF` and number 8 is `DS_ARG_ENCODED_FACT`, each in its own enumeration only.

*(libds.h: Slot values, Spec: [NFCT.2.7])*

### `ds_slot_kind_t`

**`typedef enum { … } ds_slot_kind_t;`**

The kind of a slot value.

Its members are `DS_SLOT_INT`, `DS_SLOT_FLOAT`, `DS_SLOT_STRING`, `DS_SLOT_BOOL`, `DS_SLOT_JSON`, `DS_SLOT_BYTES` and `DS_SLOT_NULL`, which are the common kinds, and `DS_SLOT_FACT_REF`. It is what a value's storage tag reports, and is distinct from the schema-declared [`ds_slot_type_t`](schemas.md#ds_slot_type_t). `DS_SLOT_NULL` is valid only in a slot its schema [declared nullable](schemas.md#ds_slot_desc_t).

*(libds.h: Slot values, Spec: [IDAT.4.6.2], [NFCT.2.7])*

### `ds_arg_kind_t`

**`typedef enum { … } ds_arg_kind_t;`**

The kind of a call argument.

Its members are `DS_ARG_INT`, `DS_ARG_FLOAT`, `DS_ARG_STRING`, `DS_ARG_BOOL`, `DS_ARG_JSON`, `DS_ARG_BYTES` and `DS_ARG_NULL`, which are the common kinds, and [`DS_ARG_ENCODED_FACT`](../callbacks/call.md#fact-arguments). No call callback receives `DS_ARG_NULL`: a kwarg with no value prevents the call.

*(libds.h: Slot values, Spec: [NFCT.2.7], [NCBK.6.10], [LNUL.11.1])*

## Value types

### `ds_bytes_view_t`

**`typedef struct ds_bytes_view { const uint8_t *data; size_t len; } ds_bytes_view_t;`**

A non-owning pointer and length.

Its lifetime is that of the value holding it.

*(libds.h: ds_bytes_view_t)*

### `ds_value_t`

**`typedef struct ds_value { ds_kind_t kind; union { int64_t i; double f; const char *s; bool b; ds_json_t *json; ds_bytes_view_t bytes; } v; } ds_value_t;`**

A value of a common kind.

`v.s` is engine-interned and `v.bytes` a view of binary, each valid for the engine's lifetime. `v.json` is a parsed [`ds_json_t`](../conventions/handles.md#ds_json_t) tree.

*(libds.h: ds_value_t)*

### `ds_slot_value_t`

**`typedef struct ds_slot_value { ds_slot_kind_t kind; union { int64_t i; double f; const char *s; bool b; ds_json_t *json; ds_fact_t *ref; ds_bytes_view_t bytes; } v; } ds_slot_value_t;`**

A slot value.

`v.s` and `v.bytes` point into libds's intern table, and their lifetime depends on where the value came from:

| Value | Valid |
|---|---|
| read with [`ds_fact_get_slot`](reading.md#ds_fact_get_slot) | until that fact is retracted |
| libds's own pinned strings: schema, slot and rule names | for the engine's lifetime |

`v.json` is a parsed [`ds_json_t`](../conventions/handles.md#ds_json_t) tree, and read with `ds_fact_get_slot` it follows that entry. `v.ref` is non-owning. A value passed to an assert has the lifetimes in [Value copies](asserting.md#value-copies).

*(libds.h: ds_slot_value_t, Spec: [NFCT.6.2])*

### `ds_encoded_fact_t`

**`typedef struct ds_encoded_fact { ds_bytes_view_t bytes; const char *schema; int64_t asserted_at; bool asserted_at_set; } ds_encoded_fact_t;`**

A [fact passed as a call argument](../callbacks/call.md#fact-arguments).

| Member | Holds |
|---|---|
| `bytes` | the fact's [`FactExternal`](../callbacks/stream.md#factexternal-bridging) message |
| `schema` | the fact's schema name |
| `asserted_at` | the instant the fact entered working memory, in UTC nanoseconds since the Unix epoch; `0` when unset |
| `asserted_at_set` | false when the wall clock had no value at assertion |

Every pointer is valid for the duration of the callback that receives it.

*(libds.h: ds_encoded_fact_t, Spec: [NCBK.6.10])*

### `ds_arg_value_t`

**`typedef struct ds_arg_value { ds_arg_kind_t kind; union { int64_t i; double f; const char *s; bool b; ds_json_t *json; ds_bytes_view_t bytes; ds_encoded_fact_t fact; } v; } ds_arg_value_t;`**

A call argument's value.

`v.s`, `v.bytes` and `v.fact` are borrowed for the callback. `v.json` is a parsed [`ds_json_t`](../conventions/handles.md#ds_json_t) tree.

*(libds.h: ds_arg_value_t, Spec: [NCBK.6.10])*

### `ds_arg_t`

**`typedef struct ds_arg { const char *name; ds_arg_value_t value; } ds_arg_t;`**

One call argument: the kwarg's name and its typed value.

Everything is engine-owned, and borrowed for the duration of the callback that receives it. How a call's arguments arrive is on [`ds_call_request_t`](../callbacks/call.md#ds_call_request_t).

*(libds.h: ds_arg_t, Spec: [NCBK.6.10])*

## Null hash

### `DS_NULL_HASH64`

**`#define DS_NULL_HASH64 UINT64_C(0x4E554C4C4E554C4C)`**

The pinned 64-bit hash of the `null` value.

It is the same on every platform, and its bytes spell ASCII `NULLNULL`. It distributes hash buckets only: identity and dedup equality are checked on the values.

*(libds.h: DS_NULL_HASH64, Spec: [LNUL.8.8])*

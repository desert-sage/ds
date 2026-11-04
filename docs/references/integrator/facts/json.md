<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Json

## Kinds

### `ds_json_kind_t`

**`typedef enum { … } ds_json_kind_t;`**

The kind of a node of a [`ds_json_t`](../conventions/handles.md#ds_json_t) tree.

| Member | Node |
|---|---|
| `DS_JSON_NULL` | `null` |
| `DS_JSON_BOOL` | `true` or `false` |
| `DS_JSON_INT` | a 64-bit signed integer |
| `DS_JSON_FLOAT` | a finite `double`; a zero is `+0.0` |
| `DS_JSON_STRING` | well-formed UTF-8 holding no U+0000 |
| `DS_JSON_ARRAY` | a sequence of nodes |
| `DS_JSON_OBJECT` | members, with one value per key; a key has the form of a `DS_JSON_STRING` |

*(libds.h: ds_json_kind_t, Spec: [NFCT.2.9], [LGRA.5.8.7], [LGRA.5.8.8], [LGRA.5.8.9], [LGRA.5.8.10], [LSTR.1.1], [LSTR.8.5])*

## Ownership

### Tree ownership

A tree returned through a `ds_json_t **` out-parameter on this page is integrator-owned. It is disposed of exactly once: with [`ds_json_free`](#ds_json_free), or by transfer into a container under [Child ownership](#child-ownership).

Passing a tree as a [`DS_SLOT_JSON`](values.md#ds_slot_value_t) value under [Value copies](asserting.md#value-copies), or to [`ds_engine_cache_seed`](../callbacks/cache.md#ds_engine_cache_seed), is not a disposal. A tree that [`ds_cache_set_cb_t`](../callbacks/cache.md#ds_cache_set_cb_t), [`action_cache_set`](../callbacks/stream.md#action_cache_set), a [call argument](values.md#ds_arg_t) or [`ds_fact_get_slot`](reading.md#ds_fact_get_slot) delivers is a borrow, as [`ds_json_t`](../conventions/handles.md#ds_json_t) states.

The layout of a `Json` slot is in [Data model](inv:internals:std:doc#overview/data-model), and a `Json` field of a `FactExternal` in [Fact stream](inv:internals:std:doc#artefacts/fact-stream).

*(libds.h: ds_json_parse, ds_json_clone, Builders, Spec: [IDAT.3.3.3], [IDAT.3.3.8])*

## Limits

### `DS_JSON_MAX_DEPTH`

**`#define DS_JSON_MAX_DEPTH 16`**

The most levels a tree holds.

A scalar, or an empty array or object, is one level, and each enclosing array or object adds one: `[[1]]` is three.

*(libds.h: DS_JSON_MAX_DEPTH, Spec: [LGRA.5.8.6])*

### `DS_JSON_MAX_NODES`

**`#define DS_JSON_MAX_NODES 256`**

The most nodes a tree holds.

It counts every scalar, array and object in the tree, the root included.

*(libds.h: DS_JSON_MAX_NODES, Spec: [LGRA.5.8.6])*

### `DS_JSON_MAX_STRING_BYTES`

**`#define DS_JSON_MAX_STRING_BYTES 16384`**

The most string bytes a tree holds.

It counts the UTF-8 bytes of every string value and every object key in the tree, summed.

*(libds.h: DS_JSON_MAX_STRING_BYTES, Spec: [LGRA.5.8.6])*

### `DS_JSON_MAX_TEXT_BYTES`

**`#define DS_JSON_MAX_TEXT_BYTES 24576`**

The longest text [`ds_json_parse`](#ds_json_parse) takes.

*(libds.h: DS_JSON_MAX_TEXT_BYTES, Spec: [LGRA.5.8.6])*

### `DS_JSON_MAX_FX_TEXT_BYTES`

**`#define DS_JSON_MAX_FX_TEXT_BYTES 106496`**

The longest text of a `Json` field in a `FactExternal` that [`ds_engine_assert_external`](asserting.md#ds_engine_assert_external) receives.

It is 6 × `DS_JSON_MAX_STRING_BYTES` + 32 × `DS_JSON_MAX_NODES`, the most text [`ds_json_serialize`](#ds_json_serialize) writes for a tree within the other limits. The text is checked before any of it is read, and the depth, node and string-byte limits hold for its value.

*(libds.h: DS_JSON_MAX_FX_TEXT_BYTES, Spec: [LGRA.5.8.6])*

## Parsing and serializing

### `ds_json_parse`

**`ds_result_t ds_json_parse(const char *text, size_t len, ds_json_t **out);`**

Parses a JSON document into a tree.

`text` holds `len` bytes and need not be NUL-terminated. On success, `*out` is the root.

A number literal with a `.` or an exponent is a `DS_JSON_FLOAT`: the `double` nearest its value, ties to even, at any number of digits. One below the smallest subnormal reads as `+0.0`. Any other number literal is a `DS_JSON_INT`. A `\u` escape names one UTF-16 code unit, and a high-surrogate escape followed at once by a low-surrogate escape is the one codepoint the pair encodes.

Before any value is read, it returns, in this order:

1. `DS_ERR_INVAL`: `out` is NULL, or `text` is NULL with `len` above 0.
2. `DS_ERR_JSON_LIMIT`: `len` is over [`DS_JSON_MAX_TEXT_BYTES`](#ds_json_max_text_bytes). No byte is read.
3. `DS_ERR_ENCODING`: the text is not well-formed UTF-8 anywhere in it.

While reading the document, it returns:

- `DS_ERR_JSON_LIMIT` at the first value that crosses [`DS_JSON_MAX_DEPTH`](#ds_json_max_depth), [`DS_JSON_MAX_NODES`](#ds_json_max_nodes) or [`DS_JSON_MAX_STRING_BYTES`](#ds_json_max_string_bytes);
- `DS_ERR_OOM` on allocation failure;
- `DS_ERR_PARSE` for malformed text, which is any of:
  - text that is not one JSON document, empty text included;
  - an object naming a key twice, compared as UTF-8 bytes once escapes are resolved: `"a"` and `"\u0061"` are one key;
  - an integer literal outside the 64-bit signed range;
  - a float literal that rounds to an infinity;
  - U+0000 in a string or key, raw or as `\u0000`;
  - a surrogate escape that is half of no such pair.

Past a NULL `out`, `*out` is NULL on every error.

*(libds.h: ds_json_parse, Spec: [LGRA.5.8.6], [LGRA.5.8.7], [LGRA.5.8.8], [LGRA.5.8.9], [LGRA.5.8.10], [LDET.3.2.8], [LSTR.7.2.3], [LSTR.8.5], [IDAT.3.3.7], Source: runtime/src/libds/json.c)*

### `ds_json_free`

**`ds_result_t ds_json_free(ds_json_t *tree);`**

Releases a tree: every child node, string and key it holds.

A NULL `tree` is a no-op. It returns `DS_OK`.

*(libds.h: ds_json_free, Source: runtime/src/libds/json.c)*

### `ds_json_clone`

**`ds_result_t ds_json_clone(const ds_json_t *src, ds_json_t **out);`**

Deep-copies a tree.

`*out` is the root of a new tree that shares nothing with `src`, whichever node of a tree `src` is. A NULL `src` sets `*out` to NULL and returns `DS_OK`.

Errors: `DS_ERR_INVAL` for a NULL `out`; `DS_ERR_OOM`, with any partial tree freed and `*out` NULL.

*(libds.h: ds_json_clone, Source: runtime/src/libds/json.c)*

### `ds_json_serialize`

**`ds_result_t ds_json_serialize(const ds_json_t *tree, char **out, size_t *out_len);`**

Writes a tree as its one canonical JSON text.

`*out` is a NUL-terminated, caller-owned buffer, released with [`ds_free`](../conventions/handles.md#ds_free). `*out_len`, when `out_len` is non-NULL, is its length without the NUL. Trees of equal content write identical bytes, in any key order.

The text is:

- no whitespace between tokens;
- an object's members in ascending order of their keys, compared as UTF-8 bytes;
- in a string or key: `"` and `\` as `\"` and `\\`; U+0008, U+000C, U+000A, U+000D and U+0009 as `\b`, `\f`, `\n`, `\r` and `\t`; any other character below U+0020 as `\u00` and two lowercase hexadecimal digits; every other character as its own UTF-8 bytes;
- an integer in decimal, with a `-` for a negative one;
- a float in the canonical form of [LDET.3.2.7](inv:specs:std:label#ldet-3-2-7);
- `true`, `false` and `null` as themselves.

Errors: `DS_ERR_INVAL` for a NULL `tree` or `out`; `DS_ERR_OOM`, with `*out` NULL.

```{note}
[`DS_JSON_MAX_TEXT_BYTES`](#ds_json_max_text_bytes) does not bound this call's output, and `ds_json_parse` refuses any text longer than it, this call's output included.
```

*(libds.h: ds_json_serialize, Spec: [LGRA.5.8.6], [LGRA.5.8.7a], [IALC.4.3], Source: runtime/src/libds/json.c)*

## Path lookup

### `ds_json_get_path`

**`ds_result_t ds_json_get_path(const ds_json_t *root, const char *path, const ds_json_t **out);`**

Looks up a node by dotted path.

A path is one or more steps. A key step is one or more bytes, none of them `.` or `[`, and every key step but a path's first follows a `.`. An index step is `[`, one or more decimal digits, and `]`, counting from zero. `body.temperature` reads key `body`, then key `temperature`, and `body.forecast[0].max` reads key `body`, key `forecast`, index 0 and key `max`.

The whole path is judged before the tree is read, so a malformed path is refused on every tree. The empty path, an empty key, a leading `.`, an index with a sign or white space, and `a[0]b` are malformed.

On a hit, `*out` is a borrow under [Read results](#read-results). On a miss, the status is `DS_OK` and `*out` is NULL. A miss is a key the object does not hold, an index past the array's end, however large the number, or a step on a node of another kind. The walk ends at a miss.

A member whose key is empty, or holds `.` or `[`, has no path. [`ds_json_object_get`](#ds_json_object_get) reads it.

Errors: `DS_ERR_INVAL` for a NULL `root`, `path` or `out`, and for a malformed path.

*(libds.h: ds_json_get_path, Spec: [IDAT.3.3.2], [IDAT.3.3.6], [IDAT.3.3.10], Source: runtime/src/libds/json_path.ebnf)*

## Reading

### Read results

A read on a node returns its results through out-parameters. A `const ds_json_t *` or `const char *` it yields is a borrow into the source tree, valid for that tree's lifetime and never freed by the caller.

Unless its entry states otherwise, a read returns `DS_ERR_INVAL` for a NULL `node` or out-parameter, with a [detail](../conventions/results.md#detail-string) naming the argument, and for a node that is not exactly the kind it reads, with a detail naming the actual and requested kinds. `DS_JSON_INT` and `DS_JSON_FLOAT` are not coerced.

A read writes its out-parameters on success, and on a miss where its entry gives `*out` NULL. After any other error status, do not read an out-parameter.

*(libds.h: ds_json_get_kind, Spec: [IDAT.3.3.2], [IDAT.3.3.5], [IDAT.3.3.6], Source: runtime/src/libds/json.c)*

### `ds_json_get_kind`

**`ds_result_t ds_json_get_kind(const ds_json_t *node, ds_json_kind_t *out);`**

Reads a node's [kind](#ds_json_kind_t).

It takes a node of any kind.

*(libds.h: ds_json_get_kind)*

### `ds_json_get_bool`

**`ds_result_t ds_json_get_bool(const ds_json_t *node, bool *out);`**

Reads a `DS_JSON_BOOL` node's value.

*(libds.h: ds_json_get_bool)*

### `ds_json_get_int`

**`ds_result_t ds_json_get_int(const ds_json_t *node, int64_t *out);`**

Reads a `DS_JSON_INT` node's value.

*(libds.h: ds_json_get_int)*

### `ds_json_get_float`

**`ds_result_t ds_json_get_float(const ds_json_t *node, double *out);`**

Reads a `DS_JSON_FLOAT` node's value.

*(libds.h: ds_json_get_float)*

### `ds_json_get_string`

**`ds_result_t ds_json_get_string(const ds_json_t *node, const char **out_s, size_t *out_len);`**

Reads a `DS_JSON_STRING` node's text.

`*out_s` is NUL-terminated and holds no other NUL. `out_len` may be NULL; otherwise `*out_len` is the length in bytes, equal to `strlen(*out_s)`.

*(libds.h: ds_json_get_string, Spec: [IDAT.3.3.7])*

### `ds_json_array_len`

**`ds_result_t ds_json_array_len(const ds_json_t *node, size_t *out);`**

Reads the number of elements of a `DS_JSON_ARRAY` node.

*(libds.h: ds_json_array_len, Source: runtime/src/libds/json.c)*

### `ds_json_array_at`

**`ds_result_t ds_json_array_at(const ds_json_t *node, size_t index, const ds_json_t **out);`**

Reads the element of a `DS_JSON_ARRAY` node at `index`.

It also returns `DS_ERR_NOT_FOUND` when `index` is at or past the length, with `*out` NULL.

*(libds.h: ds_json_array_at, Spec: [IDAT.3.3.6], Source: runtime/src/libds/json.c)*

### `ds_json_object_len`

**`ds_result_t ds_json_object_len(const ds_json_t *node, size_t *out);`**

Reads the number of members of a `DS_JSON_OBJECT` node.

*(libds.h: ds_json_object_len, Source: runtime/src/libds/json.c)*

### `ds_json_object_get`

**`ds_result_t ds_json_object_get(const ds_json_t *node, const char *key, const ds_json_t **out);`**

Reads the value of a `DS_JSON_OBJECT` node's member named by the NUL-terminated `key`.

It also returns `DS_ERR_INVAL` for a NULL `key`, and `DS_ERR_NOT_FOUND` when the key is absent, with `*out` NULL.

*(libds.h: ds_json_object_get, Spec: [IDAT.3.3.6], Source: runtime/src/libds/json.c)*

### `ds_json_object_at`

**`ds_result_t ds_json_object_at(const ds_json_t *node, size_t index, const char **out_key, size_t *out_key_len, const ds_json_t **out_value);`**

Reads the member of a `DS_JSON_OBJECT` node at position `index`, from 0 to one below its length.

Members are in the order they entered the object: text order for a parsed object, and the order of first insertion for a built one. [`ds_json_object_set`](#ds_json_object_set) on a key already present keeps that key's position, and [`ds_json_clone`](#ds_json_clone) keeps every position. [`ds_json_serialize`](#ds_json_serialize) sorts members by key instead.

Any out-parameter may be NULL. `*out_key_len` is the key's length in bytes. It returns `DS_ERR_NOT_FOUND` when `index` is at or past the length.

*(libds.h: ds_json_object_at, Spec: [IDAT.3.3.11], Source: runtime/src/libds/json.c)*

## Building

### Builder results

Each `ds_json_new_*` call returns a new node in `*out`, under [Tree ownership](#tree-ownership).

Each returns `DS_ERR_INVAL` for a NULL `out` and `DS_ERR_OOM` on allocation failure. Past a NULL `out`, `*out` is NULL on every error.

*(libds.h: Builders, Spec: [IDAT.3.3.3], Source: runtime/src/libds/json.c)*

### `ds_json_new_null`

**`ds_result_t ds_json_new_null(ds_json_t **out);`**

Makes a `DS_JSON_NULL` node.

*(libds.h: ds_json_new_null)*

### `ds_json_new_bool`

**`ds_result_t ds_json_new_bool(bool v, ds_json_t **out);`**

Makes a `DS_JSON_BOOL` node holding `v`.

*(libds.h: ds_json_new_bool)*

### `ds_json_new_int`

**`ds_result_t ds_json_new_int(int64_t v, ds_json_t **out);`**

Makes a `DS_JSON_INT` node holding `v`.

*(libds.h: ds_json_new_int)*

### `ds_json_new_float`

**`ds_result_t ds_json_new_float(double v, ds_json_t **out);`**

Makes a `DS_JSON_FLOAT` node holding `v`.

`-0.0` is held as `+0.0`. It also returns `DS_ERR_JSON_NONFINITE` for `+Inf`, `-Inf` and NaN.

*(libds.h: ds_json_new_float, Spec: [LGRA.5.8.8], [LGRA.5.8.10], [IDAT.3.3.9])*

### `ds_json_new_string`

**`ds_result_t ds_json_new_string(const char *s, size_t len, ds_json_t **out);`**

Makes a `DS_JSON_STRING` node holding a copy of the `len` bytes at `s`.

The node's text is NUL-terminated. `s` need not be. A NULL `s` with `len` 0 makes the empty string.

It also returns, in this order after a NULL `out`:

1. `DS_ERR_INVAL`: `s` is NULL with `len` above 0.
2. `DS_ERR_JSON_LIMIT`: `len` is over [`DS_JSON_MAX_STRING_BYTES`](#ds_json_max_string_bytes).
3. `DS_ERR_INVAL`: a NUL is among the `len` bytes.
4. `DS_ERR_ENCODING`: the bytes are not well-formed UTF-8.

*(libds.h: ds_json_new_string, Spec: [LSTR.1.1], [LSTR.8.5], [IDAT.3.3.7], Source: runtime/src/libds/json.c)*

### `ds_json_new_array`

**`ds_result_t ds_json_new_array(ds_json_t **out);`**

Makes an empty `DS_JSON_ARRAY` node.

*(libds.h: ds_json_new_array)*

### `ds_json_new_object`

**`ds_result_t ds_json_new_object(ds_json_t **out);`**

Makes an empty `DS_JSON_OBJECT` node.

*(libds.h: ds_json_new_object)*

## Mutators

### Child ownership

[`ds_json_array_append`](#ds_json_array_append) and [`ds_json_object_set`](#ds_json_object_set) take ownership of `child` on `DS_OK`: freeing the container frees it. On an error, `child` stays the caller's and the container is unchanged.

Each returns:

- `DS_ERR_INVAL` for a NULL container or `child`, a container of the wrong kind, a `child` that belongs to a container, and a `child` that is the container or holds it;
- `DS_ERR_JSON_LIMIT` when the whole tree, measured from the container's root, would be over [`DS_JSON_MAX_DEPTH`](#ds_json_max_depth), [`DS_JSON_MAX_NODES`](#ds_json_max_nodes) or [`DS_JSON_MAX_STRING_BYTES`](#ds_json_max_string_bytes);
- `DS_ERR_OOM` on allocation failure.

```{warning}
Freeing `child` after a `DS_OK` is a double free when the container is freed.
```

*(libds.h: Mutators, Spec: [IDAT.3.3.4], [IDAT.10.1], [LGRA.5.8.6], Source: runtime/src/libds/json.c)*

### `ds_json_array_append`

**`ds_result_t ds_json_array_append(ds_json_t *array, ds_json_t *child);`**

Appends `child` to a `DS_JSON_ARRAY` node.

*(libds.h: ds_json_array_append)*

### `ds_json_object_set`

**`ds_result_t ds_json_object_set(ds_json_t *object, const char *key, size_t key_len, ds_json_t *child);`**

Sets the member of a `DS_JSON_OBJECT` node named by the `key_len` bytes at `key`.

The object keeps a copy of the key. When the key is present, `child` replaces its value, which is freed. A NULL `key` with `key_len` 0 is the empty key.

It also returns `DS_ERR_INVAL` for a NULL `key` with `key_len` above 0 and for a NUL among the `key_len` bytes, and `DS_ERR_ENCODING` for a key that is not well-formed UTF-8.

```{warning}
A borrow taken from a replaced value dangles once this call returns `DS_OK`.
```

*(libds.h: ds_json_object_set, Spec: [LGRA.5.8.7], [LSTR.1.1], [LSTR.8.5], [IDAT.3.3.4], [IDAT.3.3.7], Source: runtime/src/libds/json.c)*

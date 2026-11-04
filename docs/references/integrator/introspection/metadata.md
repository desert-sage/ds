<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Program metadata

## Views

### Metadata views

The calls on this page read what a load took from the artefact, and change nothing. The atoms are in [The .dsc format](inv:internals:std:doc#artefacts/dsc-format), and schema metadata is in [Schema accessors](../facts/schemas.md#schema-accessors).

A view's strings and arrays are engine-owned and valid for the engine's lifetime.

Each call returns `DS_ERR_INVAL` for a NULL `engine`, name or out-pointer; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry); and `DS_ERR_ENGINE_HALTED` under the [halt latch](../engine/lifecycle.md#halt-latch). Each `_at` call also returns `DS_ERR_NOT_FOUND` for an index at or past the count.

*(Spec: [NDBG.1.3], [NDBG.7.1], Source: runtime/src/libds/engine.c)*

## Rules

### `ds_rule_meta_view_t`

**`typedef struct ds_rule_meta_view { const char *rule_name; bool has_cool; uint64_t cool_window_ns; bool has_srcr; const char *src_file; uint32_t src_line; uint32_t src_col; bool has_dnam; const char *debug_name_template; } ds_rule_meta_view_t;`**

The metadata of one rule.

| Member | Holds |
|---|---|
| `rule_name` | the rule's name |
| `has_cool` | whether the rule has a cooldown window |
| `cool_window_ns` | the cooldown window, in nanoseconds, when `has_cool` |
| `has_srcr` | whether the artefact gives the rule's source location |
| `src_file`, `src_line`, `src_col` | the source location, when `has_srcr` |
| `has_dnam` | whether the artefact gives a debug-name template |
| `debug_name_template` | the template of [RDSC.6.8](inv:specs:std:label#rdsc-6-8), when `has_dnam` |

*(libds.h: ds_rule_meta_view_t, Spec: [NDBG.2.3])*

### `ds_engine_rule_meta_count`

**`ds_result_t ds_engine_rule_meta_count(ds_engine_t *engine, size_t *out);`**

Reads the number of rule views.

*(libds.h: ds_engine_rule_meta_count, Spec: [NDBG.2.3])*

### `ds_engine_rule_meta_at`

**`ds_result_t ds_engine_rule_meta_at(ds_engine_t *engine, size_t index, ds_rule_meta_view_t *out);`**

Reads the rule view at `index`.

*(libds.h: ds_engine_rule_meta_at, Spec: [NDBG.2.3], [NDBG.7.1])*

### `ds_engine_rule_meta_find`

**`ds_result_t ds_engine_rule_meta_find(ds_engine_t *engine, const char *rule_name, ds_rule_meta_view_t *out, bool *out_found);`**

Looks up a rule view by name.

`*out_found` says whether it hit, and a miss returns `DS_OK`.

*(libds.h: ds_engine_rule_meta_find, Spec: [NDBG.2.4])*

## Services

### `ds_service_kwarg_view_t`

**`typedef struct ds_service_kwarg_view { const char *name; const char *ds_type; bool required; bool is_literal; bool has_default; const char *default_text; } ds_service_kwarg_view_t;`**

One kwarg of a service.

| Member | Holds |
|---|---|
| `name` | the kwarg's name |
| `ds_type` | the declared type as the artefact spells it: a builtin type, a unit symbol, a dimension, a schema by its [own name](inv:author:std:doc#lang/imports), `Schema` or an opaque type |
| `required` | whether the kwarg is `required` |
| `is_literal` | whether the kwarg is `literal` |
| `has_default` | whether the kwarg has a default |
| `default_text` | the default's canonical text; `""` when `has_default` is false |

*(libds.h: ds_service_kwarg_view_t, Spec: [NDBG.2.4], [RDSC.6a.2.7])*

### `ds_service_view_t`

**`typedef struct ds_service_view { const char *name; const char *response; bool no_response; uint32_t kwarg_count; const ds_service_kwarg_view_t *kwargs; } ds_service_view_t;`**

One service the loaded program declares, from its `ServiceDef` atom.

| Member | Holds |
|---|---|
| `name` | the service's name, `domain.method` |
| `response` | the response schema's name; `""` for a service that declares `no response` |
| `no_response` | set exactly when the service declares `no response` |
| `kwarg_count` | the number of entries in `kwargs` |
| `kwargs` | the kwargs, in the artefact's order, which is by name |

*(libds.h: ds_service_view_t, Spec: [NDBG.2.4])*

### `ds_engine_service_count`

**`ds_result_t ds_engine_service_count(ds_engine_t *engine, size_t *out);`**

Reads the number of services.

*(libds.h: ds_engine_service_count, Spec: [NDBG.2.4])*

### `ds_engine_service_at`

**`ds_result_t ds_engine_service_at(ds_engine_t *engine, size_t index, ds_service_view_t *out);`**

Reads the service at `index`, in the artefact's order, which is source order.

*(libds.h: ds_engine_service_at, Spec: [NDBG.2.4], [RDSC.8.4])*

### `ds_engine_service_find`

**`ds_result_t ds_engine_service_find(ds_engine_t *engine, const char *name, ds_service_view_t *out, bool *out_found);`**

Looks up a service by name.

`*out_found` says whether it hit, and a miss returns `DS_OK`.

*(libds.h: ds_engine_service_find, Spec: [NDBG.2.4])*

## Source

### `ds_ds_source_view_t`

**`typedef struct ds_ds_source_view { uint32_t module_id; const char *file; const char *text; size_t text_len; } ds_ds_source_view_t;`**

The preserved DS source text of one module.

| Member | Holds |
|---|---|
| `module_id` | the module's identity |
| `file` | the module's display path, which may repeat across modules |
| `text`, `text_len` | the source text and its length |

*(libds.h: ds_ds_source_view_t, Spec: [NDBG.3.1], [RDSC.14.2.5])*

### `ds_engine_ds_source_count`

**`ds_result_t ds_engine_ds_source_count(ds_engine_t *engine, size_t *out);`**

Reads the number of preserved modules.

*(libds.h: ds_engine_ds_source_count, Spec: [NDBG.3.1])*

### `ds_engine_ds_source_at`

**`ds_result_t ds_engine_ds_source_at(ds_engine_t *engine, size_t index, ds_ds_source_view_t *out);`**

Reads the preserved module at `index`.

*(libds.h: ds_engine_ds_source_at, Spec: [NDBG.3.1], [NDBG.7.1])*

## Source spans

### `ds_line_span_view_t`

**`typedef struct ds_line_span_view { uint32_t node_id; uint32_t ds_line; uint32_t ds_col; const char *ds_file; uint32_t module_id; } ds_line_span_view_t;`**

The DS source position of one Rete node.

| Member | Holds |
|---|---|
| `node_id` | the bundle-global index of the alpha, beta or terminal node |
| `ds_line`, `ds_col` | the 1-based source line and column |
| `ds_file` | the display path, equal to the `file` of the module's [`ds_ds_source_view_t`](#ds_ds_source_view_t) |
| `module_id` | the `module_id` of that view |

*(libds.h: ds_line_span_view_t, Spec: [NDBG.3.1], [RDSC.14.3.3])*

### `ds_engine_line_span_count`

**`ds_result_t ds_engine_line_span_count(ds_engine_t *engine, size_t *out);`**

Reads the number of spans.

*(libds.h: ds_engine_line_span_count, Spec: [NDBG.3.1])*

### `ds_engine_line_span_at`

**`ds_result_t ds_engine_line_span_at(ds_engine_t *engine, size_t index, ds_line_span_view_t *out);`**

Reads the span at `index`.

*(libds.h: ds_engine_line_span_at, Spec: [NDBG.3.1], [NDBG.7.1])*

### `ds_engine_line_span_find`

**`ds_result_t ds_engine_line_span_find(ds_engine_t *engine, uint32_t node_id, ds_line_span_view_t *out);`**

Resolves the span of a Rete node by its `node_id`.

It returns `DS_ERR_NOT_FOUND` when no `LineSpan` atom mapped the node. An alpha node has no `LineSpan` atom, and neither does a node the compiler makes for itself.

*(libds.h: ds_engine_line_span_find, Spec: [NDBG.3.1], [RDSC.14.3.6])*

### Diagnostic source locations

A runtime diagnostic's `node_id` resolves to a source position with [`ds_engine_line_span_find`](#ds_engine_line_span_find). The span's `module_id` names the [`ds_ds_source_view_t`](#ds_ds_source_view_t) with the same `module_id`, read through [`ds_engine_ds_source_at`](#ds_engine_ds_source_at).

*(Spec: [NDBG.3.2], [NERR.16.2], [RDSC.14.3.1])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The program

## Schemas

### `schema_names`

**`:- func schema_names(session) = read(list(string)).`**

The schemas a host can assert into, by own name, in schema-id order: the capability of [`ds_engine_schema_count` and `ds_engine_schema_at`](inv:integrator:std:doc#facts/schemas).

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.engine.m)*

### `search_schema`

**`:- pred search_schema(session::in, string::in, read(schema)::out) is semidet.`**

The schema of this own name: the capability of [`ds_engine_schema_find`](inv:integrator:std:doc#facts/schemas).

It fails if a host can see no schema of this own name, and answers `halted` after the halt, whatever the name.

*(Source: bindings/mercury/src/mercury_ds.session.m)*

### `lookup_schema`

**`:- func lookup_schema(session, string) = read(schema).`**

[`search_schema`](#search_schema), throwing an exception where that fails.

*(Source: bindings/mercury/src/mercury_ds.session.m)*

### `slot_names`

**`:- func slot_names(session, schema) = read(list(string)).`**

The names of a schema's slots, in declaration order, which is the order [`assert_fact`](facts.md#assert_fact) takes their values in.

*(Source: bindings/mercury/src/mercury_ds.session.m)*

### `proto_text`

**`:- func proto_text(schema) = maybe(string).`**

The `.proto` text the compiler generated from a schema's declaration, or `no` where the artefact carries none: the capability of [`ds_schema_get_proto_source`](inv:integrator:std:doc#facts/schemas).

It takes no session, and answers after the halt.

*(Source: bindings/mercury/src/mercury_ds.introspect.m, Spec: [RDSC.5.8])*

### `search_schema_source`

**`:- pred search_schema_source(session::in, string::in, read(source_loc)::out) is semidet.`**

Where the schema of this name is declared: the capability of [`ds_schema_get_source`](inv:integrator:std:doc#facts/schemas).

It fails for a builtin schema, a name no schema has, and every schema of an artefact compiled without source positions. It answers `halted` after the halt, whatever the name.

*(Source: bindings/mercury/src/mercury_ds.introspect.m, Spec: [RDSC.5.7])*

### `lookup_schema_source`

**`:- func lookup_schema_source(session, string) = read(source_loc).`**

[`search_schema_source`](#search_schema_source), throwing an exception where that fails.

*(Source: bindings/mercury/src/mercury_ds.introspect.m)*

### `source_loc`

**`:- type source_loc ---> source_loc(source_loc_file :: maybe(string), source_loc_line :: int, source_loc_column :: int).`**

A position in a module's DS source.

`source_loc_file` is the module's display path, or `no` when the artefact carries no source for the module. `source_loc_line` and `source_loc_column` count from 1.

*(Source: bindings/mercury/src/mercury_ds.introspect.m)*

## Services

### `service_info`

**`:- type service_info ---> service_info(service_info_name :: string, service_info_response :: maybe(string), service_info_kwargs :: list(service_kwarg)).`**

A service the program declares: the capability of [`ds_service_view_t`](inv:integrator:std:doc#introspection/metadata).

| Field | Holds |
|---|---|
| `service_info_name` | its name, `domain.method` |
| `service_info_response` | the schema it answers with, or `no` for a service declared `no response` |
| `service_info_kwargs` | the kwargs it declares, in name order: each one's type name, whether a call must supply it and as a literal, and its default |

*(Source: bindings/mercury/src/mercury_ds.introspect.m, Spec: [LADP.8.4.2], [LCRS.17.1])*

### `services`

**`:- func services(session) = read(list(service_info)).`**

The services the program declares, in artefact order: the capability of [`ds_engine_service_count` and `ds_engine_service_at`](inv:integrator:std:doc#introspection/metadata).

A `ServiceDef` with no name is left out.

*(Source: bindings/mercury/src/mercury_ds.introspect.m, runtime/mercury/src/ds.dsc.m, Spec: [NDBG.2.4])*

## Rules

### `rule_info`

**`:- type rule_info ---> rule_info(rule_info_name :: string, rule_info_cooldown :: maybe(duration), rule_info_display :: maybe(string), rule_info_source :: maybe(source_loc)).`**

A rule's metadata: the capability of [`ds_rule_meta_view_t`](inv:integrator:std:doc#introspection/metadata).

| Field | Holds |
|---|---|
| `rule_info_cooldown` | the cooldown window, or `no` for a rule with none |
| `rule_info_display` | the template a firing's display name is built from, or `no` when the artefact gives none |
| `rule_info_source` | where the rule is declared, or `no` when the artefact does not say |

*(Source: bindings/mercury/src/mercury_ds.introspect.m)*

### `rules`

**`:- func rules(session) = read(list(rule_info)).`**

Every rule, in the order the agenda ranks them: the capability of [`ds_engine_rule_meta_count` and `ds_engine_rule_meta_at`](inv:integrator:std:doc#introspection/metadata).

*(Source: bindings/mercury/src/mercury_ds.introspect.m, runtime/mercury/src/ds.dsc_rules.m, Spec: [RDSC.8.4])*

### `search_rule`

**`:- pred search_rule(session::in, string::in, read(rule_info)::out) is semidet.`**

The rule of this name: the capability of [`ds_engine_rule_meta_find`](inv:integrator:std:doc#introspection/metadata).

It fails if there is none, and answers `halted` after the halt, whatever the name.

```mercury declaration
:- pred declares_rule(session::in, string::in) is semidet.
declares_rule(S, Name) :-
    search_rule(S, Name, ok(_)).
```

*(Source: bindings/mercury/src/mercury_ds.introspect.m)*

### `lookup_rule`

**`:- func lookup_rule(session, string) = read(rule_info).`**

[`search_rule`](#search_rule), throwing an exception where that fails.

*(Source: bindings/mercury/src/mercury_ds.introspect.m)*

## Source

### `sources`

**`:- func sources(session) = read(list(ds_source)).`**

Each module's DS source text, in artefact order: the capability of [`ds_engine_ds_source_count` and `ds_engine_ds_source_at`](inv:integrator:std:doc#introspection/metadata).

*(Source: bindings/mercury/src/mercury_ds.introspect.m, Spec: [RDSC.14.2])*

### `line_spans`

**`:- func line_spans(session) = read(list(line_span)).`**

The source position of each attributed network node, in artefact order: the capability of [`ds_engine_line_span_count` and `ds_engine_line_span_at`](inv:integrator:std:doc#introspection/metadata).

*(Source: bindings/mercury/src/mercury_ds.introspect.m, Spec: [RDSC.14.3.6])*

### `search_line_span`

**`:- pred search_line_span(session::in, uint32::in, read(line_span)::out) is semidet.`**

The source position of the node with this id, the first in artefact order: the capability of [`ds_engine_line_span_find`](inv:integrator:std:doc#introspection/metadata).

It fails if no span names the node, and answers `halted` after the halt, whatever the id.

*(Source: bindings/mercury/src/mercury_ds.introspect.m, runtime/mercury/src/ds.dsc.m)*

### `lookup_line_span`

**`:- func lookup_line_span(session, uint32) = read(line_span).`**

[`search_line_span`](#search_line_span), throwing an exception where that fails.

*(Source: bindings/mercury/src/mercury_ds.introspect.m)*

### `search_source_file`

**`:- pred search_source_file(session::in, uint32::in, read(string)::out) is semidet.`**

The display path of the module with this `module_id`.

It fails if the artefact carries no source for the module, and answers `halted` after the halt, whatever the id.

*(Source: bindings/mercury/src/mercury_ds.introspect.m)*

### `lookup_source_file`

**`:- func lookup_source_file(session, uint32) = read(string).`**

[`search_source_file`](#search_source_file), throwing an exception where that fails.

*(Source: bindings/mercury/src/mercury_ds.introspect.m)*

## The artefact

### `artefact_header`

**`:- func artefact_header(session) = read(dsc_header).`**

The artefact's header: its version, hashes and bindings.

*(Source: bindings/mercury/src/mercury_ds.introspect.m)*

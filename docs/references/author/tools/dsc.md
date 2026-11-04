<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `dsc`

## Invocation

### Command line

```text
dsc_invocation = "dsc" , ( subcommand | version | help ) ;
subcommand     = compile | compile_project | dump_schemas | dump_ast | check ;
version        = "--version" ;
help           = "--help" | "-h" ;
```

`dsc` is the DS compiler, and dispatches on a leading subcommand.

*(Spec: [RCLI.1.1], Source: compiler/dsc_cli.ebnf)*

### Options

| Option | Value | Taken by |
|---|---|---|
| `-o`, `--output` | a path, or `-` | `compile`, `dump-schemas`, `dump-ast` |
| `-L`, `--search-path` | a directory | `compile`, `compile-project`, `dump-schemas`, `check` |
| `-d`, `--dialect-file` | a [dialect file](../capabilities/dialect-files.md#dialect-yaml) | `compile`, `compile-project`, `dump-schemas`, `check` |
| `--filename` | a name | `compile`, `dump-ast`, `check` |
| `--dsrt` | a path | `compile` |
| `--diagnostics` | `text` or `json` | `compile`, `dump-ast`, `check` |
| `--no-header` | none | `compile-project` |
| `--dump-ast` | none | `check` |
| `--json` | none | `dump-schemas` |

`-L` and `-d` accumulate, and their values apply in the order given. Given more than once, any other option that takes a value takes the last. `-L` directories are the [search path](../lang/imports.md#search-path).

*(Spec: [RCLI.1.3], Source: compiler/dsc_cli.ebnf)*

## Subcommands

### compile

**`compile = "compile" , compile_input , compile_option* ;`**

`compile` compiles one program, resolving its imports against the search path, to one `.dsc` at the path `-o` names.

`-o` is required. A library as the input is refused with `DS_VALIDATE_NOT_A_PROGRAM`, and no artefact is produced. The artefact holds the schema and rule atoms and the Rete network, as in [The .dsc format](inv:internals:std:doc#artefacts/dsc-format), and [Loading an artefact](inv:integrator:std:doc#engine/loading) loads it.

```text
dsc compile rules.ds -o rules.dsc -L lib
```

*(Spec: [RCLI.1.2], [RCLI.1.3], [RCLI.2.1], [LDIA.2.10.8], Source: compiler/dsc_cli.ebnf)*

### compile-project

**`compile_project = "compile-project" , sketch_dir , project_option* ;`**

`compile-project` compiles every `.ds` file under a sketch directory's `rules/`, at any depth, each to a `.dsc` beside it under the same basename.

Each module compiles as `compile` compiles it. Unless `--no-header` is given, each artefact is also written beside it as `<basename>_dsc.h`.

A directory with no `rules/`, or a `rules/` with no `.ds` file, exits `2`. A module that cannot be read or does not compile does not stop the others, and the exit code is `1` if any failed. An internal compiler error ends the invocation with `3`, and the artefacts already written stay.

*(Spec: [RCLI.1.2], [RCLI.1.4], Source: compiler/dsc_cli.ebnf)*

### dump-schemas

**`dump_schemas = "dump-schemas" , input_path , dump_option* ;`**

`dump-schemas` writes one proto3 file for the schemas the input declares, and no `.dsc`.

The file declares `syntax = "proto3"` and `package ds.dsc.user.v1`, then one message per declared `schema`, named for its `NAME`, with fields numbered from `1` in declaration order. A schema reached by `import` is not in it. It goes to standard output, or to the file `-o` names; `-o -` is standard output. With [`--json`](#dump-schemas-json), it writes a JSON document in its place.

*(Spec: [RCLI.1.2], [RCLI.1.5], Source: compiler/dsc_cli.ebnf)*

### dump-schemas json

**`json_form = "--json" ;`**

With `--json`, `dump-schemas` writes one JSON document, valid against `compiler/dsc_schemas.schema.json`, in place of the proto3 file, to standard output or to the file `-o` names.

The document's `schemas` lists the schemas the input declares, in declaration order, each with its `name` and its `slots` in declaration order. A slot carries `name`, `type` (its declared type without the `?`), `nullable` and `unit`. An input `dump-schemas` refuses writes no document.

`unit` is `null` unless the slot is unit-typed: its type is a unit symbol, or a dimension or scalar-group name.

| Member of `unit` | Holds |
|---|---|
| `dimension` | the dimension or scalar group |
| `base` | that group's base unit |
| `storage` | its storage type, `int32`, `int64` or `float64` |
| `declared` | the canonical symbol of the unit the slot names; `null` for a slot typed by its dimension or scalar group |
| `label` | the declared unit's `label`; `null` when it declares none or the slot names no unit |
| `conversion` | the conversion the compiler bakes; `null` when `declared` is |

A base or tier-1 unit's `conversion` is `{"kind": "affine", "a": …, "b": …}`, with base = `a` × declared + `b`, each constant written as the `Float`'s canonical text, which parses as an IEEE-754 double to the baked constant bit for bit. A base unit's are `1.0` and `0.0`. A tier-2 unit's is `{"kind": "tier2"}`, with no constants.

*(Spec: [RCLI.1.14], [RCLI.1.5], Source: compiler/dsc_cli.ebnf, compiler/dsc_schemas.schema.json)*

### dump-ast

**`dump_ast = "dump-ast" , compile_input , dump_ast_option* ;`**

`dump-ast` lexes, lays out and parses the input, and writes its syntax tree as one JSON document, and no `.dsc`.

It resolves no name and validates nothing, so a program that does not compile still dumps when it parses. The document is the `Module` node of `tools/ds_ast/ds.asdl` and everything under it, to standard output or to the file `-o` names.

- A node is an object: `_type` is its constructor's name, and its other members are its fields and attributes.
- A sequence is an array, and an absent optional is `null`.
- `lineno` is a 1-based line and `col_offset` a 0-based column in code points. `end_lineno` and `end_col_offset` may be `null`.

An input that does not parse writes no tree, exits `1`, and reports its diagnostic as `compile` does.

*(Spec: [RCLI.1.2], [RCLI.1.10], Source: compiler/dsc_cli.ebnf)*

### check

**`check = "check" , compile_input , check_option* ;`**

`check` gives `compile`'s verdict on one program and writes no artefact.

It does everything `compile` does short of writing the artefact, resolving imports and dialects as `compile` does. Its exit code, and what it writes to standard error, are `compile`'s for the same input under the same `--diagnostics`. It takes no `-o`, and an invocation naming one is a usage error.

With `--dump-ast`, it writes one JSON document to standard output, valid against `compiler/dsc_check.schema.json`, and nothing to standard error. The exit code does not move.

| Member | Holds |
|---|---|
| `tree` | the document [`dump-ast`](#dump-ast) writes for the input, whenever the input parses, a program a later phase refuses included; `null` when it does not parse |
| `diagnostics` | what `compile` writes to standard error: under `--diagnostics text` a string, empty when it writes nothing; under `--diagnostics json` the [JSON document](diagnostics.md#json-document), or `null` when it writes none |

```text
dsc check rules.ds -L lib --dump-ast
```

*(Spec: [RCLI.1.12], [RCLI.1.9], Source: compiler/dsc_cli.ebnf, compiler/dsc_check.schema.json)*

### `--version`

**`dsc --version`**

The version invocation takes no other argument.

*(Source: compiler/dsc_cli.ebnf)*

### `--help`

**`dsc --help`**, **`dsc -h`**

At the head of an invocation, `--help` or `-h` writes the usage to standard output and exits `0`, and the compiler reads no input.

The usage's wording is not a contract.

*(Spec: [RCLI.1.13], Source: compiler/dsc_cli.ebnf, compiler/mercury/src/dsc.cli.m)*

## Input and output

### Standard streams

**`compile_input = input_path | stdio ;`**

For `compile`, `dump-ast` and `check`, an input of `-` is the source read from standard input. `-o -` writes to standard output.

A `-` is never a filename.

*(Spec: [RCLI.1.9], [RCLI.1.10], [RCLI.1.12], Source: compiler/dsc_cli.ebnf)*

### Input name

**`--filename <name>`**

`--filename` names the input in every diagnostic, and as the source path the `DsSource` atom records.

Without it, the name is the input path as given, or `<stdin>` for standard input. A diagnostic in another file the compile reads names that file: a library module as its `DsSource` names it, and a [companion `.dstest`](dstest.md#companion) as its module is named, with `.ds` replaced by `.dstest`.

*(Spec: [RCLI.1.9])*

### `--dsrt`

**`--dsrt <path>`**

`--dsrt` is refused with `DS_VALIDATE_REALTIME_DEFERRED`, and no file it names is read.

*(Spec: [RCLI.1.9], [LCAP.2.1.5])*

### Bundled library

The compiler finds its library at `../share/ds/stdlib`, resolved against the directory that holds its own executable, and searches it after every `-L` directory. No option, environment variable or configuration names that directory or removes it from the search path.

The directory is the one that holds the executable file itself, with every symbolic link on the way to it resolved: a compiler invoked through a link finds the library beside the link's target, not beside the link. A chain of links that ends nowhere, or does not end, finds no library.

An invocation that resolves a name and does not find the library exits `2`, naming the directory it looked in, whatever `-L` names. `dump-ast` is unaffected.

*(Spec: [RCLI.1.11])*

## Exit codes

### dsc exit codes

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | [compile error](../errors/dispositions.md#compile-error): the program was refused, and one or more diagnostics rendered to stderr |
| `2` | usage error: the invocation did not parse against the grammar, named an option this compiler does not implement, named a path that could not be read or written, or found no bundled library |
| `3` | internal compiler error: the compiler failed while carrying out an accepted invocation, by a fault in it or its memory exhausted |

On `3`, the compiler writes its cause to stderr, renders no diagnostic, and writes none of the artefact it could not finish, to standard output or to the path `-o` names.

*(Spec: [RCLI.3.1])*

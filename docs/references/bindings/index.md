<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The DS Bindings Reference

## Desert Sage

DS is the short form of Desert Sage.

*(Spec: [LSCO.1.13])*

## What this book covers

This book covers the API of the Python (`pyds`), JavaScript (`@ds-lang/ds`) and Mercury bindings. An entry names the `libds.h` entry it wraps, links to it, and states only what the binding adds or changes. C has one entry, linked to the integrator book. It also covers the API of the Python packages `ds_lexer` and `ds_ast`, which wrap no `libds.h` entry.

## Covered elsewhere

The DS language as written, and the tools an author runs, are [The DS Author's Reference](inv:author:std:doc#index). The libds C API, which is also the C binding, is [The DS Integrator's Reference](inv:integrator:std:doc#index). The engine's mechanism, the artefact and wire formats, the atom registry and complexity are [The DS Internals Reference](inv:internals:std:doc#index). The normative definition of DS is [The DS Specifications](inv:specs:std:doc#README).

## Installing

The `pyds`, `@ds-lang/ds`, `ds_lexer` and `ds_ast` entries below state how each installs. A C program links libds as [Header and linking](inv:integrator:std:doc#conventions/linking) states.

## Reading an entry

An entry is a signature or syntax, a one-sentence definition, its behaviour, at most one fragment, and a citation. A citation names a clause, written `[LEXP.7.13.1]`, which links to it, `libds.h` and its symbol, a shipped source file, or a release asset.

## `pyds`

**`import pyds`**

The Python binding to libds.

The distribution is `ds-lang`, and the package it installs is `pyds`.

Its wheel is `ds_lang-<version>-cp312-abi3-<platform>.whl`, for CPython 3.12 or later: one per platform, for Linux on x86_64, aarch64 and riscv64, and for NetBSD on x86_64. It requires `protobuf`. The Linux wheels also install from PyPI as `ds-lang`. The NetBSD wheel is a release asset only.

The wheel carries the compiler at `pyds/bin/dsc`, with the standard library beside it at `pyds/share/ds/stdlib/`, and installs a command `dsc` that runs it. Which compiler `pyds` runs is [Which `dsc` runs](pyds/compile.md#which-dsc-runs).

It installs into a virtual environment, after which the command is `.venv/bin/dsc`. A Python marked externally managed (PEP 668) refuses `pip install` outside an environment.

```text
python3 -m venv .venv
.venv/bin/pip install ds_lang-<version>-cp312-abi3-<platform>.whl
```

```{note}
On CPython older than 3.12, pip refuses the wheel as `is not a supported wheel on this platform`, and the message names no version.
```

*(Source: bindings/python/pyproject.toml, bindings/python/meson.build, bindings/python/src/pyds/_dsc_command.py, Spec: [LIMP.3.3.1], [RCLI.1.11], Release: ds_lang-<version>-cp312-abi3-<platform>.whl)*

## `@ds-lang/ds`

**`import * as ds from "@ds-lang/ds"`**

[The JavaScript binding to libds](js/targets.md), through Node-API or wasm.

It is an ES module package. It installs with `npm install @ds-lang/ds`, and needs Node 20 or later. The package npm and a release's `ds-lang-ds-<version>.tgz` carry is the wasm build, with `ds_dsc` and the standard library, and no native target.

*(Source: bindings/js/package.json, bindings/js/lib/index.js)*

## `mercury_ds`

**`:- import_module mercury_ds.session.`**

[The Mercury binding to the Mercury DS runtime](mercury/session.md), `runtime/mercury`.

*(Source: bindings/mercury/src/mercury_ds.m)*

## `ds_lexer`

**`import ds_lexer`**

[The Pygments lexer for DS source](ds_lexer/ds_lexer.md).

The distribution is `ds-lang-lexer`, and the module it installs is `ds_lexer`. A release ships it as `ds_lang_lexer-<version>-py3-none-any.whl`, which also installs from PyPI as `ds-lang-lexer`. It needs Python 3.11 or later and `Pygments` 2.10 or later.

*(Source: tools/ds_lexer/pyproject.toml, Release: ds_lang_lexer-<version>-py3-none-any.whl)*

## `ds_ast`

**`import ds_ast`**

[DS programs as syntax trees](ds_ast/ds_ast.md), shaped like Python's `ast`.

The distribution is `ds-lang-ast`, and the package it installs is `ds_ast`. A release ships it as `ds_lang_ast-<version>-py3-none-any.whl`, which also installs from PyPI as `ds-lang-ast`. It needs Python 3.11 or later and no other package. It parses and compiles by running a `dsc`, which it does not bundle: [Which `dsc` runs](ds_ast/ds_ast.md#which-dsc-runs).

*(Source: tools/ds_ast/pyproject.toml, Release: ds_lang_ast-<version>-py3-none-any.whl)*

## C

**`#include <libds.h>`**

The C API of libds, with [one entry](c/c.md) in this book.

*(libds.h)*

## Contents

```{tableofcontents}
```

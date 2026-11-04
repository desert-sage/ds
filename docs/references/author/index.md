<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The DS Author's Reference

## Desert Sage

[DS](terms.md#ds) is the short form of Desert Sage.

*(Spec: [LSCO.1.13])*

## What this book covers

This book covers the DS language as written: lexical structure, declarations, rules, expressions, values, units, time, series, actions, builtins, aggregations, capabilities and compile-time diagnostics. It also covers the tools an author runs: `dsc`, `ds`, `ds test`, the language server and the debug adapter.

## Covered elsewhere

The libds C API, which is also the C binding, is [The DS Integrator's Reference](inv:integrator:std:doc#index). The Python, JavaScript and Mercury bindings are [The DS Bindings Reference](inv:bindings:std:doc#index). The engine's mechanism, the artefact and wire formats, the atom registry and complexity are [The DS Internals Reference](inv:internals:std:doc#index). The normative definition of DS is [The DS Specifications](inv:specs:std:doc#README).

## Installing

Installing begins at [Installing](tools/install.md).

## Reading an entry

An entry is a signature or syntax, a one-sentence definition, its behaviour, at most one fragment, and a citation. A citation names a clause, written `[LEXP.7.13.1]`, which links to it, a shipped source file, or a release asset. A fragment under "Refused with `DS_VALIDATE_…`" is one `dsc` refuses with that code.

## Contents

```{tableofcontents}
```

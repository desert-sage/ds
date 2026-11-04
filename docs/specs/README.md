<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The DS Specifications

DS is the short form of Desert Sage ([LSCO.1.13]).

The normative specifications for the DS language and its reference runtime,
gathered into one book so that cross-references between the specs resolve. The
book has six parts:

- **Language Specification** (`L*` prefixes) — what DS *is*: surface syntax,
  semantics, fact identity, determinism, the unit system, and everything any
  conforming implementation must satisfy.
- **Reference Runtime Specification** (`R*` prefixes) — how a runtime that
  consumes DS rules is built: architecture, lowering, the `dsc` command line,
  the compiled `.dsc` format, the event-trace file format, dialect binding,
  testing implementation, and the conformance test catalogue.
- **Implementation** (`I*` prefixes) — how `libds`, the C runtime, is built.
- **Integration Specification** (`N*` prefixes) — the integrator-facing
  contract: callbacks, lifecycle, the async pump, error handling, metrics, and
  DSC loading.
- **Wire Format (protobuf)** — the field layouts in `proto/*.proto`.
- **Authoring Style** — the Spec-authoring style.

Each item carries a stable ID (`[PFX.N.M]`) so behaviours are citable across the
corpus without ambiguity. The authoring rules — the fixed normative vocabulary,
the ID scheme and the clause format — are the [Spec-authoring style](SPEC_STYLE.md),
the last part of this book. A clause cites them as `[STYL.N]`.

## Reading this book

**What binds.** Every clause binds this edition unless it is marked deferred.
Whether a test has checked a clause yet does not change that: a clause no test
ratifies is still the contract an implementation is built to.

**Deferred.** A clause followed by *Deferred: not binding in this edition.*
states an obligation this edition does not carry. The mark covers the clause and
every clause beneath it. A page whose clauses are all deferred or retired opens
with **Not in this edition.** Deferred clauses stay in place, so their ids and
the references to them resolve.

**Ratified.** A clause whose footer reads *ratified* is checked by at least one
conformance test that runs on every pull request and passes, with the same
results, on every product of its class: the compiler; libds and the Mercury
runtime; libds's C API; the language bindings; or dsdb. The mark is computed each
time the book is built and is recorded nowhere else. A clause without it binds
just the same; it has not yet been measured on every product. The rule is
[STYL.5.3.11 in the Spec-authoring style](SPEC_STYLE.md).

**Not in the book.** Ahead-of-time compiled code (`RAOT`, `IAOT`) is not shipped
in this edition, and its pages are left out. Its ids still resolve in the source
tree.

```{note}
The documentation is five books: this one, and under `references/` The DS
Author's Reference, The DS Integrator's Reference, The DS Bindings Reference
and The DS Internals Reference.
```
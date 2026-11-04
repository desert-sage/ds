<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The DS integration specification

The contract between libds and the host that embeds it. What DS guarantees is in [the language specification](../language/README.md), and how libds is built is in [the implementation specification](../impl/README.md). The source is `specs/integration/`, one JSON file per clause, and these pages are generated from it.

The public surface is one header, `runtime/include/libds.h`. Every callback registered on an engine returns `ds_result_t`. libds ships no threading primitives, and the integrator decides when the pump runs.

- [Getting started: a minimal libds integration](GETTING_STARTED.md) (`NGST`)
- [Engine lifecycle and the pump](LIFECYCLE.md) (`NLFC`)
- [Facts: assert, retract, observe](FACTS.md) (`NFCT`)
- [Integrator callback registry](CALLBACKS.md) (`NCBK`)
- [Errors and result handling](ERRORS.md) (`NERR`)
- [Storage: wiring backends through the typed callbacks](STORAGE.md) (`NSTG`)
- [Series backends](SERIES_BACKENDS.md) (`NSBK`)
- [Adapters: the in-process bridge pattern](ADAPTERS.md) (`NADP`)
- [Realtime mode and the runtime contract](REALTIME.md) (`NRTM`)
- [Determinism and replay](DETERMINISM.md) (`NDET`)
- [Introspection and the debug adapter](INTROSPECTION.md) (`NDBG`)
- [Metrics surface](METRICS.md) (`NMET`)
- [Testing integrator code with libds](TESTING.md) (`NTST`)
- [Defining dialects](DIALECTS.md) (`NDLC`)

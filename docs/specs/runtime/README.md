<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The DS reference runtime specification

How a runtime that consumes DS rules is built. What DS guarantees is in [the language specification](../language/README.md). The source is `specs/runtime/`, one JSON file per clause, and these pages are generated from it.

The reference runtime reaches anything outside its process only through callbacks the integrator registers.

- [ARCHITECTURE.md](ARCHITECTURE.md): the engine's subsystems, threading, the clock model, determinism invariants and the compilation model.
- [LOWERING.md](LOWERING.md): how DS source lowers to the native Rete network.
- [COMPILER_CLI.md](COMPILER_CLI.md): the `dsc` command line.
- [DSC_FORMAT.md](DSC_FORMAT.md): the compiled `.dsc` artefact.
- [FACT_STREAM.md](FACT_STREAM.md): the event-trace file format.
- [DIALECT_BINDING.md](DIALECT_BINDING.md): dialect binding.
- [TESTING_IMPLEMENTATION.md](TESTING_IMPLEMENTATION.md): testing implementation.
- [CONFORMANCE_TESTS.md](CONFORMANCE_TESTS.md): the conformance test catalogue.

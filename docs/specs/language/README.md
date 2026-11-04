<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The DS language specification

What DS is, and what any conforming implementation must satisfy. The source is `specs/language/`, one JSON file per clause, and these pages are generated from it.

- [SCOPE.md](SCOPE.md): DS is a rule language for reactive orchestration over a bounded fact base.
- [DETERMINISM.md](DETERMINISM.md): given the same compiled rule set and the same event trace, every conforming DS runtime produces the same observable output, every time, on every platform.
- [TESTING.md](TESTING.md): the primitives every DS runtime must provide, the affordances rule authors must have, and the conformance surface.
- [DEBUGGING.md](DEBUGGING.md): what a rule author can see and do when diagnosing their rules.

The reference runtime is specified in [the runtime specification](../runtime/README.md).

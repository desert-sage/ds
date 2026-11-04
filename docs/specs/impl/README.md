<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The libds implementation specification

How libds, the C runtime, is built. What every conforming runtime must provide is in [the runtime specification](../runtime/README.md), and the compiler's command line is in [The dsc command line](../runtime/COMPILER_CLI.md). The source is `specs/impl/`, one JSON file per clause, and these pages are generated from it.

- [libds architecture](ARCHITECTURE.md) (`IARC`)
- [libds data model](DATA_MODEL.md) (`IDAT`)
- [libds allocator routing](ALLOCATOR.md) (`IALC`)
- [libds error model](ERRORS.md) (`IERR`)
- [Dispatcher contract — verbs, callbacks, stream events](DISPATCHER.md) (`IDSP`)
- [Test conventions and coverage](TESTING.md) (`ITST`)
- [libds spec-testing strategy](SPEC_TESTING.md) (`ISTS`)
- [DS C Rete — architecture](IRET.md) (`IRET`)
- [libds series backings](SERIES_BACKINGS.md) (`ISBK`)

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# runtime/src/libds

libds, the C runtime of DS. It is one of DS's two official runtimes; the other is the Mercury runtime, `runtime/mercury`. The conformance corpus holds both to the same vectors.

libds is written against the specification under `specs/`, rendered in `docs/specs/`. Its public header is `runtime/include/libds.h`. Its unit and spec-conformance suites are under `runtime/tests/libds/`.

## Build

`libds.build`, at the repository root, is the build graph. `Makefile` here is generated from it, for a build with make and a compiler alone. It is not edited by hand. What it needs is [Building `libds.a` from source](../../../docs/references/integrator/conventions/linking.md#building-libdsa-from-source).

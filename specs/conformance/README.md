<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# DS conformance suite

The `.ds` fixture corpus that binds every DS runtime. This page only points
elsewhere; it restates nothing.

- **Fixture format** — `[RCTS.1]` (`specs/runtime/CONFORMANCE_TESTS/`): ids,
  fields, and the closed set of `expect.kind` names.
- **Running it** — the `conformance` gate, in a pull request's CI. Never by
  hand.
- **The `compiler` category** is judged by the `compiler` lane
  (`compiler/mercury/test/test_conformance.m`), not by this harness.
- **A fixture that no longer applies** is deleted.

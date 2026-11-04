<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# runtime/tests/libds/ — libds test suite

Behavioural tests for libds, the DS reference runtime.

## Contract

- Each test cites the spec ID(s) it exercises (RTDI / RDSC / RLOW
  / RTIM / etc).
- Tests live next to their subject area by filename convention
  (`test_<subject>_<case>.c`).
- The suites are steps in `libds.build` (its "THE TEST SUITES"
  sections: `impl`, `spec`, `alloc_conformance`); build-unit builds and
  runs them.

## Coverage

These exercise the *documented* contract end to end — the
language- and runtime-spec lines are the source of truth, the C
sources under [`../../src/libds/`](../../src/libds/) are the
implementation, and the tests in this directory are the
behavioural binding between the two.

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `regex`

## The setting

### `regex` false

**`regex: false`**

A construct setting that forbids the whole [regular-expression surface](../expr/regex.md), `~`, `!~` and regex literals, in a program and its libraries.

A program has it through its dialect or a `use` block line. `default` has `regex: true`.

A regex literal anywhere in the program or its libraries, whether or not it is reached at run time, is refused with `DS_VALIDATE_CAPABILITY_DISABLED`.

*(Spec: [LCAP.2.8], [LFCA.13.1], [LNRE.1.1], [LNRE.2.1], [LNRE.3.1], [LNRE.5])*

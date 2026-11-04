<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Decibels

## The dB family

### Grouped scalars

Units in one dB scalar group are interconvertible by a constant offset.

`= x + c` means `base = declared + c`. In `units.audio`, `dBm`, `dBW`, `dBf` and `dBk` interconvert, as do `dBu` and `dBV`. The [catalogue](library.md#unit-catalogue) gives each unit's group.

```ds declaration
unit scalar ratio_db storage float64
unit dbr: ratio_db label "dBr"
unit dbq: ratio_db = x + 30 label "dBq"
```

*(Spec: [LUNI.6.1], [LUNI.16.2])*

### Standalone scalars

A dimensionless quantity with no derived units and no interconversion is a `unit scalar` group with a single member.

Two standalone scalars are different groups, and combining their values is a [cross-dimension](checking.md#cross-dimension) operation.

*(Spec: [LUNI.6.2], [LUNI.8.2])*

### Linear conversion

A dB value and a linear value are related by an explicit `let` or a declared [`unit formula`](declarations.md#unit-formula), outside the affine conversions.

*(Spec: [LUNI.6.3])*

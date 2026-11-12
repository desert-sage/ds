<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Calendar

## The calendar module

### calendar

`calendar` is a standard library module that carries builtin functions and declares nothing in source.

A program reaches its members [only through an import](../lang/imports.md#math-distance-and-calendar). A rule builds a temporal value from integer fields with this module.

*(Spec: [LTIM.14], [LIMP.3.3.4])*

### calendar.time

**`calendar.time(year, month, day)`**, **`calendar.time(year, month, day, hour, minute, second)`**, **`calendar.time(year, month, day, hour, minute, second, nanosecond)`**

`calendar.time` builds a `Time` in UTC from its fields, in the proleptic Gregorian calendar.

Every argument is an `Int`. The three-argument form is midnight UTC of that day, the six-argument form that wall-clock time in UTC, and the seven-argument form the same instant plus `nanosecond` nanoseconds. The result has offset 0, and [`local`](types.md#local) gives it a zone's offset. Any other arity is refused with `DS_VALIDATE_BAD_ARITY`.

```ds expression head
import calendar
calendar.time(2026, 1, 1, 12, 0, r.n)
```

*(Spec: [LTIM.14.1], Source: compiler/mercury/src/dsc.typecheck.m)*

### calendar.date

**`calendar.date(year, month, day)`**

`calendar.date` builds a `Date` from its fields, in the proleptic Gregorian calendar.

Every argument is an `Int`.

```ds expression head
import calendar
calendar.date(2026, 1, r.n)
```

*(Spec: [LTIM.14.1])*

### Field refusals

A field outside its range raises a [`ComputationError`](../errors/fault-facts.md#computationerror-fact) of kind `DOMAIN` and abandons the activation.

The ranges: `month` `1..12`, `day` a day of that month in that year, `hour` `0..23`, `minute` and `second` `0..59`, `nanosecond` `0..999 999 999`.

Fields in range whose value is outside [`Time`](types.md#time)'s or [`Date`](types.md#date)'s range raise `NOT_REPRESENTABLE`, and never wrap.

*(Spec: [LTIM.14.2])*

### Constant calls

A `calendar` call whose arguments all fold is the value it names, in every position: `const LAUNCH = calendar.time(2026, 1, 1)` declares a `Time` constant, and the same call in a `where` is that constant.

Such a call whose fold would raise a [field refusal](#field-refusals) is refused with `DS_VALIDATE_CONST_NOT_FOLDABLE` wherever it stands, whether or not the rest of the expression would absorb its result. A call with an argument that does not fold is evaluated when the rule runs, and raises there.

```ds declaration head error=DS_VALIDATE_CONST_NOT_FOLDABLE
import calendar
const LAUNCH = calendar.time(2026, 13, 1)
```

*(Spec: [LTIM.14.3])*

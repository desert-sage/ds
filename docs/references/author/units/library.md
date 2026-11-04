<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Standard unit library

## Module rules

### Conversion factors

No unit is declared in more than one module with a different conversion factor.

`grain` in `units.avoirdupois` and `units.troy` resolves to one numeric value. Importing it from both is [refused](../lang/imports.md#conflicts).

*(Spec: [LUNI.16.1])*

### Imperial and customary

`units.imperial` is UK imperial and `units.customary` is US customary.

Gallon, pint, fluid ounce, hundredweight and ton differ in value between them. `units.imperial` has no length units: `units.customary` provides inch, foot, yard and mile for both.

*(Spec: [LUNI.16.1], [LUNI.16.2], [LUNI.16.3])*

### Duplicate names

[Import order never chooses between two units](../lang/imports.md#conflicts). A name two modules declare is reached in each by qualified access: `avoirdupois.grain`, `troy.grain`.

*(Spec: [LUNI.16.1])*

### Import statements

Each library takes its own `import` statement. No module re-exports another's declarations.

*(Spec: [LUNI.16.1], [LUNI.16.3])*

## Modules

### Unit modules

| Module | Contents |
|---|---|
| `units.si` | SI base, prefixed forms and derived units |
| `units.metric` | litre, tonne, bar, eV and others |
| `units.customary` | US: inch, foot, mile, lb, psi, liquid and dry measure |
| `units.imperial` | UK: stone, long ton, UK gallon |
| `units.avoirdupois` | grain, oz, lb, short and long ton |
| `units.troy` | troy oz, troy lb, pennyweight |
| `units.electrical` | gauss, maxwell |
| `units.chemistry` | molar, pH, ppm, ppb |
| `units.audio` | dB family, dBm and watt, MIDI and Hz, sone, phon |
| `units.nautical` | nautical mile, knot, fathom |
| `units.time` | week, fortnight, year variants |
| `units.physics` | torque, rpm, viscosity, CGS legacy |
| `units.astro` | ly, pc, jansky, solar mass |
| `units.computer` | data, data_rate, baud, energy_per_bit, request_rate, transaction_rate, query_rate |

The [catalogue](#unit-catalogue) lists every unit.

*(Spec: [LUNI.15.2], [LUNI.16.2])*

## Non-affine units and formulas

### units.audio formulas

| Name | Between | Form |
|---|---|---|
| `dBm_watt`, `implicit` | `dBm`, `watt` | `10 ** (x / 10) / 1000`; `10 * log10(1000 * x)` |
| `midi_hz` | `midi_note`, `Hz` | `440 * 2 ** ((x - 69) / 12)`; `69 + 12 * log2(x / 440)` |

`phon` is a tier-2 unit of `loudness`, over the base `sone`, with `to_base` `2 ** ((x - 40) / 10)` and `from_base` `10 * log2(x) + 40`.

*(Spec: [LUNI.16.2])*

### units.chemistry pH

`pH` is a tier-2 unit of `acidity`, over the base `molar_h`, with `to_base` `10 ** -x` and `from_base` `-log10(x)`.

*(Spec: [LUNI.16.2])*

### units.computer formula

`energy_per_flop` and `compute_efficiency` are joined by an inverting formula pair.

*(Spec: [LUNI.16.2])*

### units.computer rates

`request_rate`, `transaction_rate` and `query_rate` are three dimensions, each distinct from the others and from those of `Hz` and `Bq`.

Their bases are `requests_per_second`, `transactions_per_second` and `queries_per_second`. Values of two of them meet as [different dimensions](checking.md#cross-dimension).

```ds expression head error=DS_VALIDATE_DIM_MISMATCH
from units.computer import transactions_per_second, queries_per_second
r.level::transactions_per_second + 5_queries_per_second
```

*(Spec: [LUNI.16.2], Source: stdlib/units/computer.ds)*

## Catalogue

### Unit catalogue

In `Conversion`, `x` is the value in the row's unit, and the result is in the dimension's base. `base` marks a unit declared with no `=`.

```{include} ../_generated/units.md
```

*(Spec: [LUNI.4.3], Source: stdlib/units)*

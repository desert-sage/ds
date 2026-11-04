<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Unit literals

## Syntax

### UNIT_LIT

```text
UNIT_LIT     ::= DEC_PREFIX '_'? UNIT_SUFFIX
DEC_PREFIX   ::= DEC_LIT ('.' DEC_LIT)? EXPONENT?
EXPONENT     ::= ('e' | 'E') ('+' | '-')? DEC_LIT
UNIT_SUFFIX  ::= UNIT_START UNIT_CONT*
UNIT_START   ::= LOWER | UPPER | '°' | '′' | '″' | 'Ω' | 'µ' | 'Å'
UNIT_CONT    ::= LOWER | UPPER | DIGIT | '_' | '°' | '′' | '″' | 'Ω' | 'µ' | 'Å' | 'ₙ'
```

A unit literal is a decimal numeric literal, an optional `_` and a unit symbol.

`UNIT_SUFFIX` is its own case-sensitive lexical class, not `NAME`. The lexer takes the longest suffix: `45°` is degree and `45°C` is celsius. No whitespace stands between the number and the `_`: `23 _m` is a parse error.

```ds expression
r.level::meter + 5_m
r.ts + 30s
```

*(Spec: [LLEX.12], [LLEX.12.3], [LLEX.12.6], [LUNI.3.2], [LUNI.3.2.1])*

### Separator

The `_` is optional for every unit, and `30_s` and `30s` are one literal.

Within the numeric prefix, `_` before a digit is a group separator: `23_000_m` is 23000 of `m`. A `_` before the first character of a suffix is the separator, so `5_meter_squared` is 5 of `meter_squared`.

The canonical spelling has the separator before a unit symbol and none before a plane-angle glyph. What the toolchain renders uses it, and nothing refuses the other spelling.

*(Spec: [LUNI.3.1], [LUNI.3.1.1], [LUNI.3.1.6], [LLEX.12.1], [LUNI.3.2])*

### Non-ASCII suffix characters

`UNIT_SUFFIX` admits seven characters beyond ASCII letters, digits and `_`.

| Character | Code point | For |
|---|---|---|
| `°` | U+00B0 | degree, `°C`, `°F`, `°R` |
| `′` | U+2032 | arcminute |
| `″` | U+2033 | arcsecond |
| `Ω` | U+03A9 | ohm |
| `µ` | U+00B5 | `µs`, `µA`, `µm` |
| `Å` | U+00C5 | ångström |
| `ₙ` | U+2099 | `gₙ`; continuation only |

The lexer normalises look-alikes before lookup: U+03BC to `µ`, U+2126 to `Ω`, U+02B9 to `′`, U+02BA to `″`. ASCII `'` and `"` are not aliases for `′` and `″`.

*(Spec: [LLEX.12.2], [LLEX.12.2.1], [LUNI.3.2])*

### Numeric prefix

A unit literal's prefix is decimal, and a scientific prefix may take the `_`: `1e6_s`, `1.0e3_ms`.

A numeric followed directly by a suffix is a unit literal unless the suffix is `e` or `E` followed by digits, or a bare `i` or `j`. `1e6` is a float, `1eV` is electronvolts, and `5in` is inches. `0xFF_FF` is an integer. See [numeric literals](../lang/lexical.md#numeric-literals).

`5i` and `5_i` are refused with `DS_VALIDATE_COMPLEX_NOT_IN_V1`.

*(Spec: [LUNI.3.1.5], [LUNI.3.1.8], [LLEX.12.1.1], Source: compiler/mercury/src/dsc.driver.m)*

### Adjacency

A numeric literal directly adjacent to a letter token is a unit literal, never a multiplication.

A suffix that is no declared or imported unit symbol is refused with `DS_VALIDATE_UNKNOWN_UNIT`.

```ds expression error=DS_VALIDATE_UNKNOWN_UNIT
r.level + 30x
```

*(Spec: [LUNI.3.1.4], [LUNI.3.1.7], Source: compiler/mercury/src/dsc.typecheck.m)*

### Percent

**`50_percent`**, **`50_pct`**

A percentage is written with the `percent` unit or its alias `pct`, and `50_percent` is `0.5`.

`%` is the modulo operator and no unit symbol. It is `percent`'s label only. `50%` is a syntax error, and the lexer refuses `50_%`.

*(Spec: [LUNI.3.1.3])*

### Whole base units

A literal in a dimension stored as `int64` or `int32` converts exactly to its base unit and lowers as an `Int`.

A literal that is not a whole number of the base unit is refused with `DS_VALIDATE_UNIT_LITERAL_NOT_WHOLE`, and is neither truncated nor rounded. `1.5_us` is `1500` nanoseconds. `0.5_ns` and `1.5_bit` are refused. A negated literal is checked after negation.

```ds expression error=DS_VALIDATE_UNIT_LITERAL_NOT_WHOLE
r.ts + 0.5_ns
```

*(Spec: [LUNI.3.1.9])*

### Negative literals

**`-23_c`**

`-23_c` parses as `-(23_c)`, and a unary minus on a unit literal negates the literal's number.

`-10_celsius` converts −10 through the unit's formula, giving 263.15 K. A unary minus on any other operand, a slot, a binding or a larger expression, negates the stored base-unit value. The two readings differ for a formula that adds a constant.

A unary minus on a `time`-dimensioned literal, such as `-15_min`, is refused with `DS_VALIDATE_BAD_OPERAND_TYPE`. A position whose own clause refuses a negative duration refuses it as that clause says.

```ds expression error=DS_VALIDATE_BAD_OPERAND_TYPE
r.ts + -15_min
```

*(Spec: [LLEX.12.4], [LUNI.3.3])*

### Canonical names and aliases

The standard library's canonical unit names are ASCII words, and its Unicode symbols are aliases.

`Hz` is the one canonical symbol: hertz has no canonical `hertz`. A literal takes either form. A slot [takes the canonical name](checking.md#aliases-in-slots).

| Canonical name | Alias | Literal |
|---|---|---|
| `celsius` | `°C` | `23_°C`, `23_celsius` |
| `ohm` | `Ω` | `100_Ω`, `100_ohm` |
| `microsecond` | `µs` | `500_µs`, `500_microsecond` |
| `degree` | `°` | `45°`, `45_deg` |
| `arcsecond` | `″` | `45″`, `45_arcsec` |

*(Spec: [LUNI.3.2.1])*

## The time dimension

### time

`time` is a `unit dimension` based on the nanosecond, with `int64` storage and units from microsecond through day as multiples of it.

*(Spec: [LUNI.10.2])*

### Duration literals

A duration is a `time`-dimensioned `UNIT_LIT`.

| Duration | Bare form | With separator |
|---|---|---|
| 100 milliseconds | `100ms` | `100_ms` |
| 5 seconds | `5s` | `5_s` |
| 1 minute | `1min` | `1_min` |
| 2 hours | `2h` | `2_h` |
| 1 day | `1d` | `1_d` |

A bare `m` is meters, never minutes.

*(Spec: [LLEX.12.8])*

### Duration positions

Every construct that takes a duration, such as a schema's `ttl`, a rule's `cooldown` and a pattern's `within`, accepts a `time`-dimensioned [`time_expr`](../lang/lexical.md#time_expr).

A suffix of another dimension is refused with `DS_VALIDATE_BAD_UNIT_DIMENSION`.

*(Spec: [LLEX.12.8], [LUNI.10.4])*

## Name resolution

### Unit lookup

A unit symbol resolves by one lookup of its full symbol, or an alias of it, in the file's unit scope: `units.core`, the units the file imports, and the units it declares.

A symbol found nowhere is refused with `DS_VALIDATE_UNKNOWN_UNIT`. A symbol bound twice is [refused](../lang/imports.md#conflicts). `5_MHz` resolves because `units.si` declares `MHz` as an alias of `megahertz`. A unit no imported module declares is the author's to declare.

*(Spec: [LLEX.12.5], [LUNI.4.4], [LUNI.15.1])*

### units.core

`units.core` is always in scope, and declares the seven base axes and their anchor units, with no import.

| Dimension | Storage | Anchor | Alias |
|---|---|---|---|
| `time` | `int64` | `nanosecond` | `ns` |
| `length` | `float64` | `meter` | `m` |
| `mass` | `float64` | `kilogram` | `kg` |
| `temperature` | `float64` | `kelvin` | `K` |
| `current` | `float64` | `ampere` | `A` |
| `amount` | `float64` | `mole` | `mol` |
| `luminous_intensity` | `float64` | `candela` | `cd` |

`time` also has `microsecond`/`us`, `millisecond`/`ms`, `second`/`s`, `minute`/`min`, `hour`/`h` and `day`/`d`. A base axis is non-redefinable: redeclaring one is refused with `DS_VALIDATE_UNIT_IMPORT_COLLISION`. Scaled forms on the other six axes, affine units and derived units are in `units.si`.

*(Spec: [LUNI.4.1.2], Source: compiler/mercury/src/dsc.resolve.m, compiler/mercury/src/dsc.imports.m)*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Unit declarations

## Declaration forms

### unit declaration

```text
unit_decl ::= unit_dimension | unit_scalar | unit_symbol | unit_formula
```

Every unit-system declaration begins with `unit`, and the second token selects its form.

`dimension`, `scalar` and `formula` select their form when no `:` follows. Any other second token, or one of those words followed by `:`, begins a `unit_symbol`.

*(Spec: [LUNI.4])*

### unit dimension

```text
unit_dimension ::= 'unit' 'dimension' NAME 'storage' NAME 'base' TYPE_SYM NEWLINE
```

`unit dimension` declares a physical dimension, its runtime storage type and its base unit.

A dimension is an integer exponent vector over the axis set, the seven axes of [`units.core`](literals.md#unitscore) and any declared independent axis. `watt` is `(length=2, mass=1, time=−3)`. A dimension that the existing axes do not span introduces a new independent axis, such as `data` (`base bit`, `int64`).

```ds declaration
unit dimension width storage float64 base pica
unit pica: width label "pc"
unit point: width = x / 12 alias pt
```

*(Spec: [LUNI.4.1], [LUNI.4.1.3], [LUNI.4.1.4])*

### Storage types

| Storage | Width | Use |
|---|---|---|
| `int32` | 4 B inline | small counted quantities |
| `int64` | 8 B inline | time in nanoseconds, counted quantities |
| `float64` | 8 B inline | IEEE 754 binary64, physical quantities |

*(Spec: [LUNI.4.1.1])*

### unit scalar

```text
unit_scalar ::= 'unit' 'scalar' NAME 'storage' NAME unit_label? NEWLINE
```

`unit scalar` declares a dimensionless scalar group, with a dimension's mechanics: its units are interchangeable and affine conversions apply.

`angle` and `solid_angle` are scalar groups. Angle values are stored in radians: `45_deg` and `0.7854_radian` are one value converted. A standalone dimensionless unit is a scalar group with a single member.

*(Spec: [LUNI.4.2], [LUNI.4.2.1])*

### Declaration identity

Each `unit dimension`, `unit scalar` and unit symbol declaration is its own, whatever its name, storage and units.

Values of two dimensions declared separately meet as [different dimensions](checking.md#cross-dimension). A file that imports a declaration holds that declaration: `units.customary`'s `psi` and `units.si`'s `pascal` share `pressure`.

Two libraries' `mark`s in one dimension are two units. A value of one meeting a value of the other converts as units of a dimension do, and `x::mark` naming the other is refused as an [undefined conversion](../values/conversions.md#refused-conversions). A slot or constant holds the unit its declaring file resolved.

*(Spec: [LUNI.4.1.5])*

## Unit symbols

### unit symbol

```text
unit_symbol  ::= 'unit' TYPE_SYM ':' NAME unit_inline
              |  'unit' TYPE_SYM ':' NAME ':' unit_label? NEWLINE
                 INDENT
                     'to_base'   ':' expression NEWLINE
                     'from_base' ':' expression NEWLINE
                 DEDENT

unit_inline  ::= ('=' expression)? unit_label? unit_aliases? NEWLINE
unit_label   ::= 'label' STRING_LIT
unit_aliases ::= 'alias' TYPE_SYM (',' TYPE_SYM)*
```

`unit <symbol>: <dimension>` declares a unit within a dimension or scalar group.

A `unit_inline` with no `=` declares the base unit: the one `unit dimension` names as `base`, or the first unit declared in a `unit scalar` group. A `unit_inline` with no `=` that declares any other unit is refused with `DS_VALIDATE_UNIT_BODY_MISSING`. A unit equal to the base writes `= x`. Values are stored in base units. `label` and `alias` are keywords only when a string literal follows `label` or a symbol follows `alias`. A unit of an undeclared dimension is refused with `DS_VALIDATE_UNIT_UNKNOWN_DIMENSION`.

```ds declaration error=DS_VALIDATE_UNIT_BODY_MISSING
unit dimension width storage float64 base pica
unit pica: width
unit point: width
```

*(Spec: [LUNI.4.3], Source: compiler/mercury/src/dsc.validate.m)*

### Tier 1

**`= <affine_expr>`**

A tier-1 conversion is an expression in `x`, the value in the declared unit, that reduces to `a*x + b`.

It uses `x`, constants, `+`, `-`, `*`, `/` as Rational division, `**`, parentheses and `math`'s `pi`. A body that is not affine is refused with `DS_VALIDATE_UNIT_BODY_NOT_AFFINE`. The inverse is derived. `a` and `b` are extracted as exact Rationals and stored as `float64`.

*(Spec: [LUNI.4.3], Source: compiler/mercury/src/dsc.validate.m)*

### Tier 2

**`to_base: <expr>`**, **`from_base: <expr>`**

A tier-2 conversion is a non-affine conversion within one dimension, with both directions required.

The body adds `sqrt`, `abs`, `ln`, `log10`, `log2`, `exp` and `**` with any exponent to the tier-1 vocabulary, each correctly rounded, and evaluates as written, one rounded operation at a time. Anything else is refused with `DS_VALIDATE_UNIT_TIER2_BAD_BODY`. `pi`, `sqrt`, `ln`, `log10`, `log2` and `exp` are `math` members, reached through the file's import of `math`.

```ds declaration
unit dimension scale storage float64 base lin
unit lin: scale
unit sq: scale:
    to_base: x ** 2.0
    from_base: x ** 0.5
```

*(Spec: [LUNI.4.3])*

### Label

**`label "<text>"`**

A `label` is the display string `:u` renders, and creates no way to write the unit.

Only the canonical name and `alias` entries are writable. A label is the unit's SI symbol where SI has one, such as `gₙ` for `g_force`.

*(Spec: [LUNI.5.2.1], [LUNI.5.2.2])*

### Alias

**`alias <symbol>, <symbol>`**

An alias is a short form valid in unit literals only: `23_mph` and `23_miles_per_hour` are both valid.

A slot [takes the canonical name](checking.md#aliases-in-slots).

*(Spec: [LUNI.5.2])*

### Compound names

`_per_` separates the numerator and denominator units in an author's compound unit name: `meters_per_second`, `watts_per_m2`.

*(Spec: [LUNI.5.1])*

## Cross-dimension formulas

### unit formula

```text
unit_formula     ::= 'unit' 'formula' NAME formula_modifier* ':' NEWLINE
                     INDENT
                         formula_line+
                     DEDENT

formula_modifier ::= 'inverting' | 'implicit'
formula_line     ::= NAME '(' NAME ':' TYPE_SYM ')' ':' TYPE_SYM '=' expression NEWLINE
```

`unit formula` declares a pair of named cross-dimension conversions, one in each direction, called at the call site.

A body with any other count is refused with `DS_VALIDATE_UNIT_FORMULA_PAIR_ARITY`. A parameter or return type that is not a unit symbol or alias, declared or imported, is refused with `DS_VALIDATE_UNIT_UNKNOWN_SYMBOL`; a dimension is no unit symbol. The expression may use the transcendental functions and `**` with any exponent, each correctly rounded, and evaluates as written.

```ds declaration
unit formula m_kg:
    to_kg(x: meter): kilogram = x * 2.0
    to_m(x: kilogram): meter = x / 2.0
```

*(Spec: [LUNI.4.5])*

### Formula modifiers

`implicit` and `inverting` may be written in either order, each at most once.

- `implicit`: the compiler applies the formula at an assignment boundary when exactly one implicit formula exists for the dimension pair. More than one is refused with `DS_VALIDATE_FORMULA_AMBIGUOUS`.
- `inverting`: the function is monotone decreasing, and the compiler flips the operator at a variable-to-variable comparison.

*(Spec: [LUNI.4.5], Source: compiler/mercury/src/dsc.validate.m)*

### Assignment boundaries

An `implicit` formula applies at these positions and no others; anywhere else, a dimension difference is a dimension error unless the formula is called.

1. A typed `let`, when the annotated dimension differs from the right-hand side's.
2. A cross-dimension `where` comparison between two pattern-bound variables.
3. A slot kwarg of `emit` or `publish`.
4. A service `call` kwarg.

At a comparison, the formula from the left operand's dimension to the right's applies to the left operand alone. For an `inverting` pair, `<` and `>` exchange, as do `<=` and `>=`, and `==` and `!=` are unchanged.

*(Spec: [LUNI.4.5.1], [LUNI.4.5.2])*

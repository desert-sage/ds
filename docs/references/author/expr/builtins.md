<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Builtin functions

## The registry

The names an author calls as a function without declaring one. A row named `math.<name>`, `distance.<name>` or `calendar.<name>` is a member of that module, called through [its import](../lang/imports.md#math-distance-and-calendar) by its qualified name or by the bare `<name>` a selective import binds. Every other row is global, and its name is a [reserved word](../lang/lexical.md#reserved-words).

| Column | Holds |
|---|---|
| Arities | the argument counts accepted. A call with any other count is a compile error |
| Tier | the call's purity tier, `pure` or `sync-impure` |
| Signature | each form's parameters and result, `?` marking a nullable result and `;` separating the forms |
| Summary | what the call answers |
| Defined by | the defining clause, which is right where it and the row differ |

A `Float` parameter takes an `Int`, converted. `cursor` is a series cursor, and `T` the type of the slot it reads. `<unit>` is a value with a unit, and the result `<unit>` is a value of the same unit; a builtin over a value with a unit is at [Builtins over a dimensioned value](../units/checking.md#builtins-over-a-dimensioned-value).

A parameter is a value: a `T?` argument is refused, and a null that reaches one at run time raises a `TypeError`. `has` and `math.fma` differ: `has` tests a `Json` path for resolution, and `math.fma` takes its operands as `x * y + z` does.

```{include} ../_generated/builtins.md
```

*(Spec: [LEXP.17.1], [LEXP.17.2], [LUNI.8.9])*

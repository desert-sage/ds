<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Let

## Declaration

### `let`

**`let_decl ::= 'let' let_binding (INDENT let_binding+ DEDENT)?`**

**`let_binding ::= NAME (':' TYPE_SYM NULLABLE?)? '=' expression NEWLINE`**

Binds a name to an expression, in the right-hand side of a rule, after `->` and before the actions.

The right-hand side is an [expression](../expr/operators.md), and a binding takes no parameters. Its type is inferred from that expression. A `:` annotation is at [let annotation](../units/checking.md#let-annotation).

```ds action
let doubled = r.level * 2.0
log info "doubled {doubled}"
```

*(Spec: [LGRA.6.1], [LGRA.6.7.1], [LGRA.6.7.2], [LLET.3.1], [LLET.3.2], [LLET.3.3], [LLET.3.4], [LLET.3.6], [LLET.6.2], [LLET.6.4], [LLET.12.1])*

### Hanging indent

`let` written once takes its remaining bindings indented under it, one per line. A group and the equivalent per-line run compile to the same artefact, and the two forms mix freely in one rule body.

```ds action
let doubled = r.level * 2.0
    tripled = r.level * 3.0
log info "{doubled} {tripled}"
```

*(Spec: [LGRA.6.1], [LGRA.6.7.4], [LLET.10.6])*

### Tuple form

**`let_binding ::= '(' NAME (',' NAME)* ')' '=' expression NEWLINE`**

Parses, and is refused: a capture binds in [`where`](../expr/regex.md#position-rule), per-line and in a group alike.

*(Spec: [LGRA.6.1], [LGRA.6.7.4])*

## Scope

### Visibility

A `let` is visible in later `let` right-hand sides, action arguments, `emit` and `publish` slot values and string interpolation, in its own rule.

*(Spec: [LLET.10.4])*

### References

A `let` reads earlier `let`s, pattern bindings of the rule, constants and companion slots. A reference to a later `let` is refused with `DS_VALIDATE_UNKNOWN_BINDING`.

*(Spec: [LLET.10.1], [LLET.10.6], [LLET.12.3])*

### Name collisions

| A `let` name collides with | Code |
|---|---|
| a pattern binding | `DS_VALIDATE_LET_SHADOWS_BINDING` |
| a constant | `DS_VALIDATE_LET_SHADOWS_CONSTANT` |
| another `let` in the rule | `DS_VALIDATE_DUPLICATE_LET` |

```ds action error=DS_VALIDATE_LET_SHADOWS_BINDING
let r = 1
log info "never"
```

*(Spec: [LLET.10.2], [LLET.12.4])*

### Slot access

A `let` binds an expression, not a fact: a slot access on a `let` name is refused with `DS_VALIDATE_LET_NO_SLOT`.

*(Spec: [LLET.10.5])*

## Evaluation

### Evaluation order

1. Patterns match, with their `where` clauses, and produce an activation.
2. The right-hand side begins. A sync-impure `let` binds, in source order, and a pure `let` is [inlined](#purity) at its uses.
3. The actions fire, in source order.

Binding a `let` has no side effects, adds no fact and re-matches nothing.

*(Spec: [LLET.9.1], [LLET.9.2], [LLET.9.3], [LLET.9.4], [LLET.9.5])*

### Purity

A `let` whose expression is `now()`, `monotonic_ns()` or `cached(key)` is sync-impure: it is bound once per activation at the start of the right-hand side, and every use reads that value.

Any other `let` is pure: it is inlined at compile time at every use site and not memoised. It costs what the expression written inline costs, and it re-evaluates each time the engine re-evaluates a use site.

*(Spec: [LGRA.9.8.4], [LLET.3.5], [LLET.10.3], [LLET.12.5])*

### Absent values and faults

A `let`'s expression takes the disposition it takes in any other position:

- an unresolved `Json` path or a failed fallible conversion binds `null`, which [propagates](../values/null.md#propagation) to its use sites, and the cycle continues;
- a wrong-typed leaf or a computation with no answer abandons the activation.

*(Spec: [LLET.9.6])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Patterns

## Pattern forms

### Pattern body

**`pattern_body ::= type_ref binding? within_clause? where_clause?`**

Matches facts of the schema `type_ref` names, bare or [library-qualified](../lang/program.md#schema-references).

The `NAME` that heads the body is the type reference. A following `NAME` is the binding, a `.` continues the head, and `NEWLINE`, `within` or `where` ends the clause with no binding.

*(Spec: [LGRA.8.1], [LGRA.8.2], [LGRA.8.3.1])*

### Pattern limit

A rule has at most 255 patterns, negated patterns included, or it is refused with `DS_VALIDATE_RULE_TOO_MANY_PATTERNS`. The limit also binds a rule the compiler builds, such as an `after` body's.

*(Spec: [LGRA.8.7])*

### `within`

**`within_clause ::= 'within' time_expr`**

Stands at pattern level, after the binding, and never inside a `where`. Its meaning is at [`within`](../time/types.md#within).

*(Spec: [LGRA.8.1], [LGRA.8.3.3])*

### Sequences

A pattern followed by `then` steps is a [sequence](temporal.md).

*(Spec: [LGRA.8.1], [LGRA.8.5.1])*

## `where`

**`where_clause ::= 'where' expression | 'where' capture_binding ('and' expression)?`**

A full [expression](../expr/operators.md) on a pattern. The second form is the [regex binding form](../expr/regex.md#binding-form).

A `where` binds to the pattern it follows. A `where` standing outside any pattern is refused with `DS_PARSE_GENERIC`, and no `let` is visible to a `where`. It may read constants, that pattern's bindings and an earlier pattern's, so the pattern it follows needs no binding of its own.

Temporal tests in a `where` read a slot or alias, such as [`dwell`](../facts/logical.md#dwell), not `within`.

A predicate spans lines inside parentheses, where any indentation is legal.

```ds rule
rule paired:
    Reading a
    Reading where a.id == "x"
->
    log info "paired"
```

*(Spec: [LGRA.8.1], [LGRA.8.3.4], [LGRA.8.3.5], [LGRA.8.6], [LLET.8.1], [LLET.12.2])*

## Bindings

### Binding

**`binding ::= NAME`**

Optional. One written and never referenced is refused with `DS_VALIDATE_UNREFERENCED_BINDING`. A reference counts in the pattern's own `where`, a later pattern's `where`, a `let` right-hand side or an action.

```ds rule error=DS_VALIDATE_UNREFERENCED_BINDING
rule unused:
    Reading r
->
    log info "never"
```

*(Spec: [LGRA.8.6])*

## Negation

### `no`

**`pattern ::= 'no' negated_pattern NEWLINE`**

**`negated_pattern ::= pattern_body | '(' pattern_body ')'`**

Negates the existence of a fact that matches the body. The parenthesised form groups the whole body under the negation. `no` stands only at pattern position, and is distinct from the expression operator `not`.

A negated pattern's binding is in scope in its own `where` alone. A reference in a later pattern's `where`, a `let` right-hand side or an action is refused with `DS_VALIDATE_NEGATED_BINDING_OUT_OF_SCOPE`.

```ds rule error=DS_VALIDATE_NEGATED_BINDING_OUT_OF_SCOPE
rule read_negated:
    no Reading r where r.ok
->
    log info "{r.id}"
```

*(Spec: [LGRA.8.1], [LGRA.8.3.2], [LGRA.8.4.1], [LGRA.8.6])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Program structure

## File structure

**`file ::= use_decl? (import_decl | top_level_decl)*`**

A source file is an optional [`use` directive](../capabilities/dialects.md), then imports, then top-level declarations in any order. Comments and blank lines are stripped before parsing.

| `top_level_decl` | Declares |
|---|---|
| `const_decl` | a [constant](#constant-declarations) |
| `schema_decl` | a schema |
| `rule_decl` | a rule |
| `series_decl` | a series |
| `service_decl` | a service |
| `unit_decl` | a unit |
| `opaque_decl` | an opaque type |
| `test_decl` | [a test](../tools/dstest.md#test) |
| `initial_block` | an initial block |

`use` is the first non-comment, non-blank statement: one preceded by any other statement is refused with `DS_VALIDATE_USE_NOT_FIRST`. Whether a file has a `use` makes it a [program](../terms.md#program) or a [library](../terms.md#library). Import placement is at [Placement](imports.md#placement).

*(Spec: [LGRA.3.1], [LGRA.3.2], [LGRA.3.3])*

## Constant declarations

**`const_decl ::= 'const' NAME (':' TYPE_SYM NULLABLE?)? '=' expression NEWLINE`**

Declares a named compile-time constant in the [value namespace](#value-namespace).

The right-hand side folds to a compile-time constant: literals, earlier constants, imported constants and the foldable operators over them. No runtime construct or interpolation is admitted.

A `:` annotation is a scalar builtin (`String`, `Int`, `Float`, `Bool`, `Json`) or a canonical unit symbol, checked against the folded value. With no annotation, the type is inferred from the folded value. A `?` on the annotation is accepted and has no effect.

| Refused | Code |
|---|---|
| an alias, a bare dimension name or another annotation that is no such type | `DS_VALIDATE_CONST_BAD_ANNOTATION` |
| an annotation that does not match the folded value | `DS_VALIDATE_CONST_ANNOTATION_MISMATCH` |
| a read of a constant declared at or below this declaration | `DS_VALIDATE_UNKNOWN_CONST` |
| a second declaration of the name in one file | `DS_VALIDATE_DUPLICATE_CONSTANT` |
| a local `const` whose name a selective import binds to a library's constant, or two selective imports binding one name to constants of different libraries | `DS_VALIDATE_IMPORT_NAME_COLLISION` |

One constant reached by two import paths is one constant. A qualified import binds no bare name, so `plant.sensors.LIMIT` beside a local `LIMIT` does not collide. A constant takes no [reserved word](lexical.md#reserved-words).

```ds declaration
const LIMIT: Float = 3.5
const HALF = LIMIT / 2.0
```

*(Spec: [LGRA.4.1], [LGRA.4.2], [LGRA.4.3], [LGRA.4.4], [LGRA.4.5], [LGRA.4.6])*

## Name classification

The grammar assigns a `NAME` its role by the production that reduces it. In a pattern, the `NAME` that heads the body, after any `no`, `latest` or `then`, is a type reference, and the trailing `NAME` is a binding. Every input has at most one parse.

*(Spec: [LGRA.22.1], [LGRA.22.2], [LGRA.22.3], [LGRA.12.2.1], [LGRA.12.3.1], [LLEX.10.8.4])*

### Type namespace

Holds the builtin types, unit symbols, dimension and scalar-group names, schemas, and the kind `Schema`. It is used at every type position.

The namespace is flat. Two entries of one NFC name are refused: two schemas with `DS_VALIDATE_DUPLICATE_SCHEMA`, a schema and a unit with `DS_VALIDATE_DUPLICATE_TYPE_NAME`.

*(Spec: [LGRA.22.7], [LGRA.22.8], [LGRA.2.5.3])*

### Value namespace

Holds pattern bindings, [`let`](../rules/let.md#let) bindings and constants. It is used at expression positions, and an expression `NAME` resolves in the order binding, constant, [builtin function](../expr/builtins.md).

The two namespaces are disjoint: a constant named `Level` does not shadow a type named `Level`.

| Unresolved `NAME` | Code |
|---|---|
| called, a library's member included | `DS_VALIDATE_UNKNOWN_FUNCTION` |
| a library's member, not called | `DS_VALIDATE_UNKNOWN_QUALIFIED_CONST` |
| names an entry of the type namespace | `DS_VALIDATE_UNKNOWN_CONST` |
| any other | `DS_VALIDATE_UNKNOWN_BINDING` |

*(Spec: [LGRA.22.7], [LGRA.4.4], [LGRA.12.3.1])*

### Schema references

At a pattern head, `latest`, `emit` or `publish`, a schema is named by a bare `NAME` in local scope, or by `p.NAME`, where `p` is the path or `as` alias of an imported library. Every `.` in a schema reference separates the path from the schema.

A bare `NAME` that is no schema in local scope, or a qualified reference to a schema the library does not export, is refused with `DS_VALIDATE_UNKNOWN_SCHEMA`.

```ds rule error=DS_VALIDATE_UNKNOWN_SCHEMA
rule unknown_schema:
    Missing
->
    log info "never"
```

*(Spec: [LGRA.22.4], [LGRA.22.4.1], [LGRA.12.4.1])*

### Dotted names

The compiler resolves `a.b.c` in expression position by its first segment, in this order:

1. If `a` is a pattern binding, a regex capture or a `let` binding in scope, the chain is access on its value.
2. Otherwise, if a prefix of the chain is the path or `as` alias of an imported library, the longest such prefix is the library. The segment after it is a member: a constant, or a builtin of a library that carries builtins. Any later segment is a member of that member's value.
3. Otherwise the name is unresolved, and refused as at [Value namespace](#value-namespace).

A type position and a `call` position are not resolved this way.

A pattern binding, regex capture, `let` binding or constant is refused with `DS_VALIDATE_BINDING_SHADOWS_LIBRARY` when its NFC name equals the first segment of an imported library's path or alias, or a member a selective import names from a [library that carries builtins](imports.md#math-distance-and-calendar).

*(Spec: [LGRA.22.9], [LGRA.22.6], [LGRA.12.4.1], [LGRA.4.6])*

## Disambiguation

### Head of a pattern or an action

A pattern head that is no type reference is the keyword `no`, or a compile error. An action head is an action keyword, or a compile error.

*(Spec: [LGRA.12.3.1])*

### Rule separator

`->` is the separator between a rule's left-hand and right-hand sides, at column 0. Elsewhere it is a compile error.

*(Spec: [LGRA.12.5.1], [LGRA.6.2])*

### First-line bare string

A bare string as the first statement of a rule or schema body is its docstring. A bare string alone later in a rule body is a compile error.

*(Spec: [LGRA.12.8.1])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Regular expressions

## Match operators

### Match

**`s ~ /pattern/flags`**

Evaluates the pattern against the codepoint sequence of `s`. In its plain form it is a Boolean test: a `where` holding it passes on a match, and on no match fails and rejects the activation silently.

*(Spec: [LREG.1.1], [LREG.1.2])*

### Negated match

**`s !~ /pattern/flags`**

The activation continues exactly when the pattern does not match `s`. It produces no bindings. A `null` `s` follows [Propagation](../values/null.md#propagation).

*(Spec: [LREG.1.1], [LREG.1.3])*

### Operand type

The left operand is a `String`. A statically known operand of any other type is refused with `DS_VALIDATE_REGEX_NON_STRING_OPERAND`. A wrong-typed `Json` leaf raises a `TypeError`.

```ds rule error=DS_VALIDATE_REGEX_NON_STRING_OPERAND
rule not_text:
    Reading r where r.n ~ /1/
->
    log info "never"
```

*(Spec: [LREG.4.5])*

### Binding strength

Both operators bind tighter than the logical operators and looser than the postfix operators: `s1 ~ /a/ and s2 ~ /b/` is two tests.

*(Spec: [LREG.1.4])*

## Position rule

A match expression is legal in `where` only. The pattern's capturing groups decide the form:

| Pattern | `where` form |
|---|---|
| one or more capturing groups, with `~` | the [binding form](#binding-form) |
| no capturing group, with `~` | plain: `where s ~ /pattern/` |
| `!~` | plain, with no capturing group |

| Refused | Code |
|---|---|
| a `~` on a `let`'s right-hand side | `DS_VALIDATE_REGEX_CAPTURE_IN_LET` |
| a `!~` on a `let`'s right-hand side | `DS_VALIDATE_REGEX_LET_NEGATED` |
| a capturing group in a plain `where`, with `~` or `!~` | `DS_VALIDATE_REGEX_WHERE_HAS_CAPTURES` |

```ds action error=DS_VALIDATE_REGEX_CAPTURE_IN_LET
let m = r.label ~ /^err/
log info "never"
```

*(Spec: [LREG.2.1], [LREG.2.3], [LREG.2.4], [LREG.2.5], [LREG.4.6], [LREG.7.2], Source: compiler/mercury/src/dsc.validate.m)*

## Captures

| Form | Captures | Binding |
|---|---|---|
| `(?<name>...)` | yes | named: `name` equals the binding-form name at that position |
| `(...)` | yes | positional: the binding-form name at that position is the author's |
| `(?:...)` | no | none: absent from the binding form |

A `(?<name>...)` whose `name` differs from the binding-form name at its position is refused with `DS_VALIDATE_REGEX_NAME_MISMATCH`.

*(Spec: [LREG.3.1], [LREG.3.2], [LREG.3.3])*

## Binding form

**`where_clause ::= 'where' capture_binding ('and' expression)?`**

**`capture_binding ::= '(' NAME (',' NAME)* ')' '=' expression`**

A parenthesised, positional list of names on a `where` clause, bound from a capture-bearing `~`. An ordinary predicate may follow it on the clause and read the captures.

The count of names equals the count of capturing groups, or the clause is refused with `DS_VALIDATE_REGEX_BINDING_LENGTH_MISMATCH`. A right-hand side that is no capture-bearing match is refused with `DS_VALIDATE_REGEX_CAPTURE_NOT_MATCH`.

A captured value is a `String`, whatever the pattern's shape. [The `::` cast](../values/conversions.md#the-cast) converts it.

```ds rule
rule captured:
    Reading r where (tag) = r.label ~ /^(?<tag>\w+):/
->
    log info "tag {tag}"
```

*(Spec: [LREG.4.1], [LREG.4.2], [LREG.4.4], [LREG.10.6], [LGRA.8.1])*

### Capture scope

A capture follows a pattern binding's scope: its own pattern's `where`, a later pattern's `where`, a `let` right-hand side and an action. A capture never referenced is refused as a never-referenced pattern binding is.

A capture in a later pattern's `where` is a legal join test. An engine computes a capture once or many times, with no observable difference.

*(Spec: [LREG.4.6], [LREG.4.7])*

### Capture as a join key

Under [`linear_scan: false`](../capabilities/linear-scan.md#linear_scan-false), a capture of an earlier pattern that completes a pattern's anchor in place of its `key` slot is refused with `DS_VALIDATE_NOLINSCAN_CAPTURE_JOIN_KEY`. Any other use of a capture is unaffected.

*(Spec: [LREG.4.8])*

## Pattern syntax

**`/<pattern>/<flags>`**

The pattern is RE2 source. It is a literal: a right-hand side of `~` or `!~` that is no literal is a parse error.

`\w`, `\d` and `\s` match ASCII: `\w` is `[A-Za-z0-9_]`.

*(Spec: [LREG.5.1], [LREG.5.5], [LREG.8.5], [LREG.10.10], [LSTR.7.1.2], [LGRA.9.3.1])*

### Flags

| Flag | Meaning |
|---|---|
| `i` | case-insensitive matching |
| `m` | `^` and `$` match line boundaries, not string boundaries |
| `s` | `.` matches newlines |

Flags are an unordered set: `/foo/im` and `/foo/mi` are one pattern. A repeated flag or any other flag, `x` and `u` among them, is refused with `DS_VALIDATE_REGEX_UNKNOWN_FLAG`.

*(Spec: [LREG.5.2], [LREG.5.3], [LREG.5.4])*

## Lexing

`/` is the division operator, except as the first non-whitespace token after `~` or `!~`, where it opens a regex literal. The literal runs to the first unescaped `/`, and flag characters may follow.

Escapes follow RE2. A literal `/` is written `\/`. A newline in a literal is a lexer error, and `\n` matches one.

*(Spec: [LREG.6.1], [LREG.6.2], [LREG.6.3], [LREG.6.4], [LREG.6.5])*

## Compile-time validation

The compiler parses every regex literal. A syntax error is refused with `DS_VALIDATE_REGEX_SYNTAX_ERROR`, at the literal's source location, naming the offending construct.

A backreference, lookaround, possessive quantifier or atomic group is refused with `DS_VALIDATE_REGEX_UNSUPPORTED_FEATURE`, naming the feature.

```ds rule error=DS_VALIDATE_REGEX_UNSUPPORTED_FEATURE
rule lookahead:
    Reading r where r.label ~ /a(?=b)/
->
    log info "never"
```

*(Spec: [LREG.7.1], [LREG.8.4])*

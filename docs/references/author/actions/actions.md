<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Actions

## The action list

### Action

```text
action ::= call_action
        |  action_head action_arg* NEWLINE action_block?

call_action ::= 'call' service_ref action_arg* call_as? NEWLINE action_block?
call_as     ::= 'as' expression

action_head ::= 'log' log_level STRING_LIT
             |  'emit' type_ref
             |  'publish' type_ref
             |  'cache'
             |  'cache_delete'
             |  'withdraw' NAME

log_level      ::= 'debug' | 'info' | 'warning' | 'error' | 'critical'

service_ref    ::= service_name
service_name   ::= NAME ('.' NAME)*
```

An action is one effect of a rule's firing, and a rule's actions run in source order.

The verbs are [`emit` and `publish`](emit-publish.md#emit-and-publish-verbs), [`cache` and `cache_delete`](cache.md#write), `log`, `withdraw` and [`call`](../calls/call.md#call). The action list and its `after` clauses are [Timed actions](after.md#after). The mechanism is [Agenda and actions](inv:internals:std:doc#engine/agenda-and-actions).

*(Spec: [LGRA.10.1], [LGRA.10.1.3])*

### `log`

**`log <level> "<message>"`**

`log` writes one line at a level.

The level is case-insensitive. An unknown level is refused with `DS_VALIDATE_BAD_LOG_LEVEL`. The message is one [string](../expr/operators.md#log-argument).

```ds action
log warning "{r.id} is low"
```

*(Spec: [LGRA.10.1], [LGRA.10.1.1], Source: compiler/mercury/src/dsc.validate.m)*

### `withdraw`

**`withdraw <binding>`**

`withdraw` removes the fact a positive pattern of the rule bound to `<binding>`.

The schemas it reaches are [Withdrawal scope](../facts/lifecycles.md#withdrawal-scope). After it in the same actions, a reference to the binding is refused with `DS_VALIDATE_WITHDRAWN_BINDING_USED`: a slot read in the action or in a body nested in it, or a second `withdraw`. An action before it refers to the binding freely.

```ds rule error=DS_VALIDATE_WITHDRAWN_BINDING_USED
schema Task:
    id: String

rule finish:
    Task t
->
    withdraw t
    log info "{t.id}"
```

*(Spec: [LGRA.10.1], [LGRA.10.1.3])*

### `withdraw` in a nested body

A `withdraw` in a call continuation, an error or timeout body, or an `after` body runs when that body runs, and removes the fact the outer rule bound when it fired.

If that fact has left working memory, including by a meaningful change, the action does nothing. A fact that has taken its place under the same key stays. Within the body nothing after the `withdraw` refers to the binding; an action of the outer actions after the one holding the body may.

*(Spec: [LGRA.10.1.3], [LGRA.10.1.4])*

### Service references

A `service_ref` names a service by its own name, resolved against every service declared in the compilation's import closure.

No library qualifier is admitted. A dotted path whose first segment names an imported library is a service name like any other, and resolves only if a service of that exact name is declared.

*(Spec: [LGRA.10.1.6])*

## Action arguments

### Argument forms

```text
action_arg ::= kwarg | flag
kwarg ::= NAME ':' value
flag  ::= NAME
value ::= expression
```

An action argument is a named value or a bare flag.

Where an expression is legal is [Expression positions](../expr/operators.md#where-an-expression-is-legal), a `null` argument follows [Verb policies](../values/null.md#verb-policies), and a fault raised evaluating an argument follows [Traps in actions](../values/null.md#traps-in-actions).

*(Spec: [LGRA.10.3.1], [LGRA.10.3.2])*

### Argument inventory

| Verb | Language-defined kwargs | Flags | User-declared kwargs |
|---|---|---|---|
| `log` | none | none | none |
| `emit` | [`retain:`](../capabilities/dynamic-ttl.md#per-emit-retain), on a `ttl` schema under `dynamic_ttl` | `logical` | the schema's slots |
| `publish` | none, as [`publish`](emit-publish.md#publish) states | none | the schema's slots |
| `call` | `cooldown:` | `nocooldown` | the service's declared kwargs |
| `cache` | `key:` and `value:`, both required; `ttl:` | none | none |
| `cache_delete` | `key:`, required | none | none |
| `withdraw` | none | none | none |

| Condition | Code |
|---|---|
| any other kwarg name | `DS_VALIDATE_BAD_KWARG` |
| any other flag name | `DS_VALIDATE_BAD_FLAG` |
| one kwarg named twice in an action | `DS_VALIDATE_DUPLICATE_KWARG` |
| a required kwarg left out | `DS_VALIDATE_MISSING_KWARG` |

`as` is a clause of `call`, not an argument. `retain`, `cooldown`, `nocooldown` and `as` are reserved, so a language-defined kwarg is never a slot or service kwarg.

```ds action error=DS_VALIDATE_BAD_KWARG
cache key: "limit" value: r.level size: 2
```

*(Spec: [LGRA.10.3.3], [LGRA.10.3.4], [LGRA.10.3.5], [LGRA.10.3.6])*

### Dynamic and literal kwargs

A kwarg a `call`'s service declares takes any expression the action's context allows.

A kwarg declared with a schema or with `Schema` takes a pattern binding. A kwarg the service marks `literal` takes an `INT_LIT`, `FLOAT_LIT` or `UNIT_LIT`, optionally preceded by `-`, a `BOOL_LIT`, or a `STRING_LIT` with no interpolation site; anything else is refused with `DS_VALIDATE_DYNAMIC_IDENT_KWARG`.

*(Spec: [LGRA.10.6], [LGRA.10.7])*

### Lines and blocks

```text
action_block    ::= INDENT block_line+ DEDENT
block_line      ::= action_arg+ NEWLINE
                 |  call_as NEWLINE
                 |  continuation
```

An `emit`, `publish` or `call` continues on indented lines under its head line, compiled exactly as the same arguments on the head line, head line first.

An indented block under `log`, `cache`, `cache_delete` or `withdraw` is a syntax error. Argument lines and continuations come in any order. A `call` holds at most one `as`, on its head line or in its block, and after an `as` line the block holds only continuations. An action is one logical line; a parenthesised expression on a `name: value` right-hand side continues it.

```ds rule
schema Note scope logical:
    id: String key
    text: String mutable

rule note:
    Reading r
->
    emit Note logical id: r.id
        text: r.label
```

*(Spec: [LGRA.10.1], [LGRA.10.2], [LGRA.10.8])*

## Special action forms

### Rate kwargs on `call`

`call` carries a mandatory [rate expectation](../calls/call.md#rate-expectation), `cooldown:` or `nocooldown`.

A `cached(key)` read is an [expression](cache.md#cached), not an action.

*(Spec: [LGRA.10.5.1], [LGRA.9.8.2])*

## String interpolation

### Interpolation site

```text
interp_site   ::= '{' interp_body (':' interp_format)? '}'
interp_body   ::= NAME ( '.' NAME | '[' INT_LIT ']' )*
interp_format ::= TIME_SPEC | NUM_SPEC
```

An interpolation site substitutes a bound path's value into a string, and its result is a [`String`](../values/strings.md#interpolation-result).

The leading `NAME` is an in-scope pattern binding, `const`, series companion or `let`, and a dotted body resolves as a [dotted name](../lang/program.md#dotted-names). A `let` bound to `now()` or `cached("k")` is admitted. A null value renders as the empty string, with no padding. `{{` and `}}` are literal braces in every string position. No whitespace is admitted inside the braces. How a site shows a unit is [Display unit](../units/checking.md#display-unit) and [Unit format](../units/checking.md#unit-format).

```ds action
log info "{r.id} at {r.level:.2f} {{raw}}"
```

*(Spec: [LGRA.2.9.6.1], [LGRA.2.9.6.2], [LGRA.2.9.6.6], [LGRA.2.9.6.7], [LGRA.2.9.6.10], [LGRA.11.2], [LGRA.11.4], [LGRA.11.5], [LGRA.11.6])*

### Eligible positions

A site is admitted in `log` strings, `call` kwarg values, `emit` and `publish` slot values, the `call ... as` correlation, and the key of `cached(...)`.

A valid `{path}` in any other string, such as a `let` right-hand side, a `where` predicate or an operand, is refused with `DS_VALIDATE_INTERP_INERT_POSITION`. In a `cached(...)` key, a segment reading a nullable slot or a `Json` sub-path is refused with `DS_VALIDATE_INTERP_NULLABLE_KEY`.

```ds expression error=DS_VALIDATE_INTERP_INERT_POSITION
"{r.id}"
```

*(Spec: [LGRA.2.9.6.8])*

### Site refusals

| Condition | Code |
|---|---|
| an unknown leading name | `DS_VALIDATE_UNKNOWN_BINDING` |
| a body outside the path grammar: a call, an operator | `DS_VALIDATE_INTERP_BAD_PATH` |
| a value kind the compiler cannot render; a whole `Json` value, or a `let` bound to one | `DS_VALIDATE_INTERP_UNSUPPORTED` |

Any other unescaped `{` or `}` that forms no valid site is a compile error. A site takes a bound path, not an expression.

```ds action error=DS_VALIDATE_INTERP_BAD_PATH
log info "{r.level + 1.0}"
```

*(Spec: [LGRA.2.9.6.2], [LGRA.2.9.6.7], [LGRA.2.9.6.9], [LGRA.2.9.6.11], [LGRA.11.7], [LEXP.9.3.1], Source: compiler/mercury/src/dsc.validate.m)*

### Timestamp format

```text
TIME_SPEC ::= TIME_DIR TIME_ITEM*
TIME_ITEM ::= TIME_DIR | TIME_CHAR
TIME_DIR  ::= '%' ( 'Y' | 'm' | 'd' | 'H' | 'M' | 'S' | 'f' | 'z' | '%' )
TIME_CHAR ::= <any character except '%', '{' and '}'>
```

A format starting with `%` renders a `Time` as directives and literal text, every field in the value's own UTC offset.

| Directive | Renders |
|---|---|
| `%Y` | the year, four digits |
| `%m` | the month, `01`–`12` |
| `%d` | the day of the month, `01`–`31` |
| `%H` | the hour, `00`–`23` |
| `%M` | the minute, `00`–`59` |
| `%S` | the second, `00`–`59` |
| `%f` | the microsecond, six digits; lower digits are truncated, never rounded |
| `%z` | the UTC offset as `+HHMM` or `-HHMM`, then `SS` when it has seconds, then `.ffffff` when it has a fraction of a second |
| `%%` | a literal `%` |

Any other `%` sequence, and this format on a value that is not a `Time`, is refused with `DS_VALIDATE_INTERP_BAD_FORMAT`.

```ds action
log info "{r.ts:%Y-%m-%d %H:%M}"
```

*(Spec: [LGRA.2.9.6.1], [LGRA.2.9.6.3], [LGRA.2.9.6.4])*

### Numeric and string format

```text
NUM_SPEC  ::= ALIGN? SIGN? ZERO? WIDTH? PRECISION? TYPE?
ALIGN     ::= '<' | '>'
SIGN      ::= '+'
ZERO      ::= '0'
WIDTH     ::= DIGIT+
PRECISION ::= '.' DIGIT+
TYPE      ::= 'd' | 'f' | 's' | 'x' | 'X' | 'b' | 'u'
```

A format not starting with `%` sets a value's digits or text, sign, width and precision.

| Type | Renders |
|---|---|
| none | the canonical text; a precision keeps at most that many code points of a `String` |
| `d` | an `Int` in decimal |
| `x`, `X` | an `Int` in hexadecimal, lowercase or uppercase digits; no prefix; a negative value is `-` and its magnitude |
| `b` | an `Int` in binary; no prefix; a negative value is `-` and its magnitude |
| `f` | fixed-point, never with an exponent: correctly rounded to the precision or six places, ties to even; an `Int` renders as the `Float` of its value; `±Inf` is `inf` or `-inf`; a negative value keeps its sign when every digit is zero; precision `0` writes no point |
| `s` | the `String`; a precision keeps at most that many code points |
| `u` | [Unit format](../units/checking.md#unit-format), rendered as a `String` is: it aligns left by default, a precision keeps at most that many code points, and `+` and `0` have no effect |

With no type, an `Int` is decimal, a `Bool` is `true` or `false`, a `Time` is its UTC [`iso8601` text](../time/types.md#iso8601-text), a `Date` is `iso8601`, and a `Duration` is its [compact form](../time/types.md#duration-compact-form).

With `+`, a non-negative number has a leading `+`; otherwise only a negative number has a sign. Width and precision count code points. Shorter text is padded with spaces: a number aligns right by default, a `String` or a `Bool` left. With `0`, zeros go between the sign and the digits. Longer text is written whole.

```ds action
log info "{r.n:>8d} {r.level:+08.3f} {r.label:<12s}"
```

*(Spec: [LGRA.2.9.6.1], [LGRA.2.9.6.3], [LGRA.2.9.6.5], [LGRA.2.9.6.10])*

### Format refusals

Each of these is refused with `DS_VALIDATE_INTERP_BAD_FORMAT`:

- an alignment with no width;
- zero padding with left alignment;
- a sign or zero padding on a `String` or a `Bool`;
- a precision on `d`, `x`, `X` or `b`;
- a precision above `20` on `f`;
- a precision with no type on a value other than a `String`;
- a type the value's kind does not take: `d`, `x`, `X` and `b` take `Int`; `f` and `u` take `Float` and `Int`; `s` takes `String`; a `Bool` takes none.

`i` or `j` as a type is refused with `DS_VALIDATE_COMPLEX_NOT_IN_V1`.

```ds action error=DS_VALIDATE_INTERP_BAD_FORMAT
log info "{r.n:.2d}"
```

*(Spec: [LGRA.2.9.6.5])*

### Format on a `Json` leaf

A format on a `Json` leaf compiles and is checked when the leaf is read.

A format part the leaf's kind does not take is a `TypeError`, and the activation is abandoned. A path reaching an object or an array is a `TypeError`, with or without a format. A leaf whose kind takes the format renders as above.

*(Spec: [LGRA.2.9.6.11])*

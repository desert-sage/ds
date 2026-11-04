<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Timed actions

## The clause

### `after`

```text
action_body   ::= action+ after_clause*
               |  after_clause+

after_clause  ::= 'after' UNIT_LIT ('as' expression)? ':' NEWLINE
                  INDENT
                      action_body
                  DEDENT
```

An `after` clause schedules its action list to run after its duration, measured from the firing of the activation that produced it.

A rule's actions carry zero or more clauses, after the immediate actions or in place of them. Clauses are independent: source order between them carries no firing guarantee beyond each one's duration. The body takes no `let`. The duration runs on the [monotonic clock](../time/types.md#monotonic-clock). Each clause lowers as [Lowering](inv:internals:std:doc#engine/lowering) states.

```ds action
log info "armed"
after 5_min:
    log info "{r.id}"
```

*(Spec: [LGRA.6.1], [LTAC.1.1], [LTAC.1.2], [LTAC.2.1], [LTAC.2.3], [LTIM.2.8.2])*

### Duration

An `after` duration is a duration literal: a `UNIT_LIT` on the `time` axis.

A named, computed or negative duration does not parse.

*(Spec: [LTAC.2.2], [LTAC.9.2], [LTAC.7.1])*

### Timing

A follow-up fires on the first pump at or after its duration has elapsed.

The integrator's pump cadence decides how soon that is, and a duration shorter than the pump interval compiles. A pump that comes late does not lose the firing. Timers due at one pump all fire at that pump, in the [total order](../rules/firing-order.md#total-order).

*(Spec: [LTAC.5.1], [LTAC.5.3], [LTAC.5.4], [LTAC.9.3])*

### Timer independence

A clause with no `as` schedules an independent timer on every firing, each with its own deadline.

A timer fires once. It has no TTL, and it fires at or after its deadline, however long the engine has been running.

*(Spec: [LTAC.2.2.1], [LTAC.4.2], [LTAC.4.3], [LTAC.4.4])*

## Composition

### Body

The body is an ordinary action list: any action legal in a rule's actions, with its own semantics, when the follow-up fires.

That includes `call` with continuations and further `after` clauses. The inner timer of a nested clause is asserted when the outer follow-up fires.

```ds action
after 1_s:
    log info "{r.id}"
    after 2_s:
        log info "{r.id}"
```

*(Spec: [LTAC.1.3], [LTAC.6.2.1], [LTAC.6.2.2])*

### With `call`

An `after` clause stands beside a [`call`](../calls/call.md#call)'s [`on`](../calls/continuations.md#on), [`timeout`](../calls/continuations.md#timeout) and [`error`](../calls/continuations.md#error) clauses, and inside their bodies; it fires on its delay regardless of any call's state.

A `call` inside an `after` body is depth two, and that call's `on` bodies hold no calls with continuations.

*(Spec: [LTAC.6.1.1], [LTAC.6.1.2], [LTAC.6.1.3], [LTAC.9.5])*

### Bindings in the body

The body reads the parent rule's bindings, captured when the rule fires.

A name the parent rule does not bind is refused with `DS_VALIDATE_UNKNOWN_BINDING`.

*(Spec: [LTAC.7.3], [LTAC.3.5], Source: compiler/mercury/src/dsc.validate.m, compiler/mercury/src/dsc.typecheck.m)*

### `after` refusals

| Condition | Code |
|---|---|
| a zero duration | `DS_VALIDATE_AFTER_NONPOSITIVE_DURATION` |
| a unit of another dimension | `DS_VALIDATE_BAD_UNIT_DIMENSION` |
| a `logical` emit in the body | [`DS_VALIDATE_LOGICAL_EMIT_SELF_ENDING`](../facts/logical.md#self-ending-emits) |

```ds action error=DS_VALIDATE_AFTER_NONPOSITIVE_DURATION
after 0_s:
    log info "{r.id}"
```

*(Spec: [LTAC.2.2], [LTAC.7.1], [LLOG.11.9])*

## `as` supersedure

### `as`

**`after <duration> as <expr>:`**, **`call <service> ... as <expr>`**

`as` declares a correlation key: a new firing with the same evaluated key supersedes the prior fact of that clause.

On `after`, the prior timer's body does not fire. On `call`, its place is at [Lines and blocks](actions.md#lines-and-blocks). The expression evaluates against the rule's bindings when the activation starts.

```ds action
after 5_min as r.id:
    log info "{r.id}"
```

*(Spec: [LRST.1.1], [LRST.1.2], [LRST.6.1], [LRST.6.11], [LRST.2.1], [LTAC.2.2.1])*

### Key types

An `after` key is a `String`, `Int`, `Float`, `Bool`, `Date`, `Time`, `Duration` or `Bytes`; a `call` key is a `String`.

Two keys of one declaration are the same exactly when `==` between them is `true`. `-0.0` and `0.0` are one key. A NaN is the same key as nothing. Two `Time` values denoting one UTC instant are one key. A computed key that evaluates to `""` supersedes nothing, and a `call` with such a key takes the correlation of a call with no `as`.

*(Spec: [LRST.1.2], [LRST.1.4], [LRST.1.4.1])*

### Key refusals

| Condition | Code |
|---|---|
| the literal `""` | `DS_VALIDATE_AS_EMPTY_KEY` |
| any other type | `DS_VALIDATE_AS_NON_EQUATABLE_TYPE` |
| a `call` key that is not a `String` | `DS_VALIDATE_CALL_AS_NOT_STRING` |
| `as:`, with a colon | `DS_VALIDATE_LEGACY_AS_COLON` |
| a `T?` | `DS_VALIDATE_NULLABLE_UNNARROWED` |
| a `Json` sub-path; an interpolated segment reading a nullable slot or a `Json` sub-path | `DS_VALIDATE_AS_SOFTFAIL_EXPRESSION` |

```ds action error=DS_VALIDATE_AS_EMPTY_KEY
after 5_s as "":
    log info "{r.id}"
```

*(Spec: [LRST.1.2], [LRST.1.3], [LRST.1.4], [LRST.1.4.1], [LRST.1.5], [LRST.1.5.1], [LRST.6.10], Source: compiler/mercury/src/dsc.validate.m)*

### Supersedure scope

| Fact | Scope |
|---|---|
| a timer or a [capture fact](../calls/continuations.md#capture) | the rule, the clause's position and the evaluated key |
| a call's response fact, `CallError` | the service and the evaluated key, whichever rule or clause issued the call |

Two clauses at different positions in one rule, and two rules, do not supersede each other under one expression.

*(Spec: [LRST.2.2], [LRST.6.5])*

### No cascade

Superseding a fact retracts it and its captured bindings, and no other fact of the activation.

The activation has no lifetime as a unit, and its other facts follow their own triggers.

*(Spec: [LRST.2.1], [LRST.2.3], [LRST.6.4])*

### Superseded call

A `call` re-fired with one correlation supersedes the prior call's response fact or `CallError` and its [captured bindings](../calls/continuations.md#capture).

The prior activation's continuations tied to that correlation do not fire. Its other facts are unaffected, and retract on their own triggers.

*(Spec: [LRST.4.1], [LRST.4.2], [LRST.4.3], [LRST.4.4], [LRST.6.6])*

### Superseded `after`

A new activation with a clause's `as` key retracts the prior timer and the prior captured bindings together, before scheduling its own.

*(Spec: [LRST.4.5])*

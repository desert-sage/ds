<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Call continuations

## Clauses

### Continuation

```text
continuation  ::= "on" constraint_expr ":" action_list
                | "timeout" duration ":" action_list
                | "error" code_pattern? ":" action_list

code_pattern  ::= ident ( "." ident )*
```

A continuation is a trailing clause on a `call`, each one a sibling rule matching the call's answer, joined by correlation.

A `call` carries zero or more of each, each a line of its [block](../actions/actions.md#lines-and-blocks). The clauses scope to the `call` above them, and each call has its own correlation.

A rule that makes a `call` and separate rules that match its answer are the same primitive, and one file may mix the two forms. Each clause lowers as [Lowering](inv:internals:std:doc#engine/lowering) states.

```ds action
call svc.ask level: r.level nocooldown
    on response.code == 200:
        log info "{r.id} ok"
    timeout 5_s:
        log error "{r.id}"
```

*(Spec: [LCCO.1.1], [LCCO.1.2], [LCCO.1.3], [LCCO.2.1], [LCCO.12.4.1])*

### All-match

Clauses are independent: every clause whose event occurs fires, and source order carries no meaning.

```ds action
call svc.ask level: r.level nocooldown
    on response.code == 200:
        log info "{r.id} ok"
    on response.code > 0:
        log info "{r.id} answered"
```

*(Spec: [LCCO.2.3])*

### `on`

**`on <constraint_expr>:`**

`on` fires when the call's response fact arrives and its slots satisfy the constraint.

The constraint has the grammar and typing of a `where`. `response` is a name bound to the response fact, and `response.<slot>` reads a slot of the service's response schema. The body sees the same fact as `response`, [bound in that body alone](#answer-bindings). Several `on` clauses are independent.

```ds action
call svc.ask level: r.level nocooldown
    on response.code == 200 and response.corr != "":
        log info "{r.id} {response.code}"
```

*(Spec: [LCCO.2.2], [LCCO.6.1], [LCCO.6.2], [LCCO.6.4])*

### `timeout`

**`timeout <duration>:`**

`timeout` fires when no response fact and no `CallError` for the call's correlation arrives within the duration, measured from the call's firing.

An answer on the call's correlation ends every `timeout` of the call, whether or not an `on` or `error` clause matches it. No `timeout` body of the call runs after the answer, including once the answer has expired or been superseded.

Each `timeout` clause fires at its own duration, and a firing leaves the call's other `timeout` clauses in place. A re-fire of the call supersedes the timer of each of its `timeout` clauses, in the [supersedure scope](../actions/after.md#supersedure-scope) of a timer.

```ds action
call svc.ask level: r.level nocooldown
    timeout 5_s:
        log warning "{r.id}"
    timeout 30_s:
        log error "{r.id}"
```

*(Spec: [LCCO.2.2], [LCCO.7.1], [LCCO.7.2], [LCCO.7.3], [LCCO.7.6], [LRST.2.2])*

### `error`

**`error [<code_pattern>]:`**

`error` fires when a `CallError` arrives whose `corr` is the call's correlation and whose `code` matches the pattern.

With no pattern, it matches every error for the correlation, including a code outside the [standard families](error-codes.md#standard-families). The body sees the `CallError` bound as `error`, [in that body alone](#answer-bindings). Several `error` clauses are independent: `error request:` and `error request.malformed:` both fire on `request.malformed`.

```ds action
call svc.ask level: r.level nocooldown
    error request.malformed:
        log error "{r.id} {error.message}"
```

*(Spec: [LCCO.2.2], [LCCO.8.1], [LCCO.8.2], [LCCO.8.3.3], [LCCO.8.3.4], [LCCO.8.4])*

### Code matching

A pattern matches a code when its segments are a prefix of the code's, at segment boundaries.

| Pattern | Matches |
|---|---|
| `request` | `request.malformed`, `request.unsupported` |
| `request.malformed` | `request.malformed` alone |
| `request.malform` | not `request.malformed` |

The pattern's first segment is [a family](error-codes.md#pattern-match-contract).

```ds action
call svc.ask level: r.level nocooldown
    error request:
        log error "{error.code}"
```

*(Spec: [LCCO.8.3.2])*

## Bindings

### Capture

The outer rule's bindings are in scope in every continuation body, as a snapshot taken when the rule fired.

Continuation rules read the snapshot whether or not the original facts are still in working memory. The engine holds it in a capture fact, an [`activation`](../facts/lifecycles.md#scope-activation)-lifecycle fact whose schema an author cannot name.

*(Spec: [LCCO.5.0], [LCCO.5.1], [LCCO.5.2], [LCCO.5.4])*

### Capture lifetime

A capture fact lives for the longest of the `ttl` of each fact the call's continuations match and the largest `timeout` the call declares.

On a call with one `timeout` clause, that clause's firing ends the capture. On a call with several, a `timeout` firing does not end it, and an answer arriving later still joins an `on` or `error` clause. The capture then ends by an `on` or `error` match, by supersedure or at the end of its lifetime.

*(Spec: [LCCO.5.3], [LCCO.7.2], [LCCO.7.3])*

### Answer bindings

An `on` body's `response` and an `error` body's `error` are bound in the body of the clause that matched them, and in no continuation of a `call` made inside that body.

A continuation of such a `call` sees the outer rule's bindings and its own `response` or `error`. A read there of an enclosing clause's `response` or `error` is refused with `DS_VALIDATE_UNKNOWN_BINDING`.

```ds action error=DS_VALIDATE_UNKNOWN_BINDING
call svc.ask level: r.level nocooldown
    on response.code == 200:
        call svc.ask level: r.level nocooldown as "inner"
            timeout 5_s:
                log info "{response.code}"
```

*(Spec: [LCCO.6.2], [LCCO.8.4], [LCCO.10.3])*

### Correlation in a continuation

An `as` flows to every continuation of its call.

A generated correlation is opaque: a rule outside the continuation block that matches the answer needs an explicit `as`.

```ds action
call svc.ask level: r.level nocooldown as "read"
    on response.code == 200:
        log info "{r.id} ok"
```

*(Spec: [LCCO.12.2.1])*

### Cooldown in a continuation

A call's `cooldown:` applies to the outer call, and a continuation has none of its own.

```ds action
call svc.ask level: r.level cooldown: 30_s
    on response.code == 200:
        log info "{r.id}"
```

*(Spec: [LCCO.12.1.1])*

## Chaining

### One-step chaining

A `call` in a continuation body may carry continuations of its own, and a further level is refused with `DS_VALIDATE_CONTINUATION_CHAIN_TOO_DEEP`.

The inner call's continuations are sibling rules on the inner correlation. They may read the outer rule's bindings, each as the outer capture held it when the outer continuation fired. An `after` boundary counts as an `on` boundary does, as [With `call`](../actions/after.md#with-call) states.

A continued `call` in the body of an `after` or a continuation, with no `as` or a computed `as`, is refused with `DS_VALIDATE_NESTED_CONTINUED_CALL_AS`.

```ds action
call svc.ask level: r.level nocooldown
    on response.code == 200:
        call svc.ask level: r.level nocooldown as "inner"
            on response.code == 200:
                log info "{r.id}"
```

*(Spec: [LCCO.10.1], [LCCO.10.2], [LCCO.10.3], [LCCO.3.8], Source: compiler/mercury/src/dsc.validate.m)*

## Compile-time validation

### Continuation refusals

| Condition | Code |
|---|---|
| a slot the response schema does not declare | `DS_VALIDATE_UNKNOWN_SLOT` |
| conjunctive constraints that cannot be satisfied | `DS_VALIDATE_PREDICATE_UNSATISFIABLE` |
| a name the outer rule does not bind | `DS_VALIDATE_UNKNOWN_BINDING` |

A numeric interval contradiction (`x < 60 and x > 100`) and an enum-set contradiction are unsatisfiable.

```ds action error=DS_VALIDATE_UNKNOWN_SLOT
call svc.ask level: r.level nocooldown
    on response.missing == 1:
        log info "{r.id}"
```

*(Spec: [LCCO.6.3], [LCCO.11.1], [LCCO.11.2], [LCCO.11.5], Source: compiler/mercury/src/dsc.validate.m)*

## What does not compose

### Two-sibling form only

These need a rule that makes the `call` and separate rules that match its answer:

- a match of several unrelated calls' answers together, as a continuation is per call;
- a request conditional on a prior response, which the request rule's patterns match;
- a chain deeper than two;
- a match against a live fact rather than the snapshot.

*(Spec: [LCCO.5.4], [LCCO.13.1], [LCCO.13.2], [LCCO.13.3], [LCCO.13.4])*

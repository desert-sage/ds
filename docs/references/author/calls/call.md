<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Calls

## The action

### `call`

**`call <service> <kwarg>: <value> ... (cooldown: <duration> | nocooldown) [as <expr>]`**

`call` asks a service for work, and the firing's actions complete without waiting.

The answer arrives on a later pump as a fact, and a rule matches it. The action's productions are at [Action](../actions/actions.md#action), and its kwargs at [Argument inventory](../actions/actions.md#argument-inventory). What the host does is [Calls](inv:integrator:std:doc#callbacks/call). A [dialect](../capabilities/registry.md#disabled-constructs) can disable `call`.

```ds action
call svc.op level: r.level cooldown: 30_s as "{r.id}"
```

*(Spec: [LCRS.2.1], [LCRS.11.1], [LCRS.11.2])*

### Modifiers on a call

`cooldown:`, `nocooldown` and `as` ride any call without being declared kwargs.

`retain:` on a call is refused with `DS_VALIDATE_RETAIN_UNWIRED`.

```ds action error=DS_VALIDATE_RETAIN_UNWIRED
call svc.op level: r.level nocooldown retain: 1_h
```

*(Spec: [LCRS.6.3.3], [LCRS.14.13])*

## Threading a call to its answer

### Correlation

A correlation is the `String` that threads through a call to its answer, never `null` and never empty.

It is the value of the call's [`as`](../actions/after.md#as), or a value generated for each firing where the call has no `as` or its `as` evaluates to `""`. Key refusals are at [Key refusals](../actions/after.md#key-refusals). The answer carries it, uninterpreted, in its `corr` slot.

Two call sites may reuse one correlation at different times with no interaction, provided their answers do not overlap in working memory. Picking values that do not collide with the live correlations of other rules with outstanding responses is the author's job. The same rule reusing a value [supersedes its earlier call](#superseding-call).

*(Spec: [LCRS.3.1], [LCRS.3.2], [LCRS.3.3], [LCRS.3.5])*

## Answers

### Exactly one answer

A call to a service declaring `response T` gets one fact of `T` when it succeeds, or a `CallError` when it fails, a [superseded](#superseding-answer) call aside.

The host asserts both. A rule that needs both paths has two matchers, and each call has its own answer.

*(Spec: [LCRS.4.2.2], [LCRS.4.3.1], [LCRS.9.2], [LCRS.9.10])*

### Response schema

A schema named in a `response_decl` is `ttl` and declares `corr` as a non-nullable `String`.

| Condition | Code |
|---|---|
| not `ttl` | `DS_VALIDATE_SERVICE_RESPONSE_NOT_TTL` |
| no such `corr` slot | `DS_VALIDATE_SERVICE_RESPONSE_NO_CORR` |

Every response is its own fact, and `corr` is never an identity key. `corr` is a slot name the language gives a meaning: the correlation of the call that brought a fact into working memory.

The name `CallResponse` is refused with `DS_VALIDATE_CALL_RESPONSE_RETIRED`, in a declaration, a pattern or a reference.

*(Spec: [LCRS.4.3.2], [LCRS.4.3.3])*

### `CallError`

`CallError` is a [built-in schema](../facts/builtin-schemas.md#the-built-in-schemas), `ttl`-scoped at 5 minutes, asserted when a call could not be fulfilled.

| Slot | Type | Meaning |
|---|---|---|
| `corr` | `String` | the call's correlation |
| `code` | `String` | the [error code](error-codes.md#code-form) |
| `message` | `String` | human-readable detail |
| `ts` | `Time` | when the error was received |

```ds rule
rule failed:
    CallError e where e.code == "request.malformed"
->
    log error "{e.corr} {e.message}"
```

*(Spec: [LCRS.4.2.1], [LCRS.4.2.3])*

### A rule asserts no answer

An `emit` or `publish` of `CallError`, or of a schema a `response_decl` of the program names, is refused with `DS_VALIDATE_ANSWER_EMIT_FORBIDDEN`.

A rule may match an answer. A response schema declared `ambient` is refused as [`ambient`](../facts/lifecycles.md#ambient) states.

```ds action error=DS_VALIDATE_ANSWER_EMIT_FORBIDDEN
emit CallError corr: r.id code: "request.malformed" message: "m"
```

*(Spec: [LCRS.4.3.4])*

### Reading a response

A rule matches the response schema, constrained on `corr`, and reads its slots as it reads any fact's.

The compiler checks those reads as it checks any slot access. A `Json` slot of the schema reads as any [`Json` slot](../values/json.md#json-slot) does. Several rules may match one response, each seeing the same slots.

*(Spec: [LCRS.5.5], [LCRS.6.5.1])*

## Lifetime

### Answer lifetime

An answer lives until a superseding call retracts it or its schema's TTL expires it.

The TTL is the duration the response schema declares, and 5 minutes for `CallError`.

*(Spec: [LCRS.6.1], [LCRS.6.6.1])*

### Superseding call

An issued `call S ... as K` first retracts every live fact of `S`'s response schema with `corr` `K` and every live `CallError` with `corr` `K`.

A call to a `no response` service retracts `CallError` facts alone. Responses of other services stay, whichever rule or clause position issued the call. A call its cooldown suppresses retracts nothing. The other effects of a superseded call are [Superseded call](../actions/after.md#superseded-call).

*(Spec: [LCRS.6.2.1], [LCRS.6.2.2])*

### Superseding answer

An arriving answer supersedes as the call does, before it enters.

| Answer with `corr` `K` | Retracts |
|---|---|
| a fact of a response schema `T` | every live fact of `T` with `corr` `K`, every live `CallError` with `corr` `K` |
| a `CallError` | every live `CallError` with `corr` `K`, every live fact of every response schema with `corr` `K` |

An answer whose `corr` is `""` supersedes nothing. For each non-empty correlation, either one `CallError` is live and no response fact is, or no `CallError` is live and at most one fact of each response schema is.

When replies arrive out of order, the answer to the earlier request is the one that stays.

*(Spec: [LCRS.6.2.4])*

### With `logical` emit

A [`logical` fact](../facts/logical.md#emit-x-logical) justified by a response fact retracts when the response fact does, by supersedure or at its TTL.

*(Spec: [LCRS.12.1.1])*

## Timeouts

### Timeout by absence

A timeout is a negated pattern over the response schema, bounded by `within` and constrained to the call's correlation.

A rule reacts to an absence only where it has such a pattern, or a [`timeout` clause](continuations.md#timeout). With neither and no answer, no rule fires, and the call's cooldown window runs as it does for any call.

```ds rule
rule no_error_yet:
    Reading r
    no CallError e within 30_s where e.corr == "read"
->
    log warning "{r.id}"
```

*(Spec: [LCRS.7.1], [LCRS.7.2], [LCRS.7.4])*

## Rate

### Rate expectation

Every `call` carries `cooldown: <duration>` or `nocooldown`; a call with neither is refused with `DS_VALIDATE_CALL_RATE_MOD`.

```ds action error=DS_VALIDATE_CALL_RATE_MOD
call svc.op level: r.level
```

*(Spec: [LCRS.8.1])*

### `cooldown` on a call

**`cooldown: <duration>`**

`cooldown:` suppresses a call when the same call site has issued it within the duration for the same key.

The key is the values of the declared `key` slots of each `logical` fact the activation binds, as a rule's [default key](../rules/cooldown.md#default-key) is. A `ttl` fact contributes no slot, and a `call` takes no `by:`, so with no such `logical` fact the key is empty and the call site has one window across its activations. Each call site has its own window. A suppressed call does not stop the rule's other actions.

*(Spec: [LCRS.8.2])*

### `nocooldown`

**`nocooldown`**

`nocooldown` issues the call every time the rule fires.

*(Spec: [LCRS.8.2])*

## Service names

### Service resolution

A call's whole dotted name is the service's name, resolved against every service in the import closure.

Exactly one declaration matches. No match is refused with `DS_VALIDATE_UNKNOWN_SERVICE`. Reference rules are at [Service references](../actions/actions.md#service-references).

```ds action error=DS_VALIDATE_UNKNOWN_SERVICE
call svc.none level: r.level nocooldown
```

*(Spec: [LCRS.10.2], [LCRS.10.4.1], [LCRS.10.4.2], [LCRS.10.4.4], [LCRS.10.5.2])*

### Unique names

Two declarations of one service name in a compilation's import closure are refused with `DS_VALIDATE_DUPLICATE_SERVICE`.

One declaration reached by two import paths is not a duplicate.

*(Spec: [LCRS.14.9])*

## Services with no answer

### `no response`

A call to a `no response` service asserts nothing when it succeeds, and a `CallError` when it fails.

It may bind `as`. Silence is not a timeout.

| Clause on it | Code |
|---|---|
| a response continuation | `DS_VALIDATE_NO_RESPONSE_CONTINUATION` |
| a `timeout` continuation | `DS_VALIDATE_NO_RESPONSE_TIMEOUT` |

```ds action error=DS_VALIDATE_NO_RESPONSE_TIMEOUT
call svc.op level: r.level nocooldown
    timeout 5_s:
        log info "{r.id}"
```

*(Spec: [LCRS.17.1], [LCRS.17.2])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Lifecycles

## Scope values

### `scope explicit`

**`schema Foo:`**, **`schema Foo scope explicit:`**

An `explicit` fact is asserted by `emit` and retracted by a `withdraw` of a binding that matched it; the engine does not manage its lifetime.

It is the scope of a schema with no `scope` clause.

*(Spec: [LSCP.1.4], [LSCP.2.1.1], [LSCP.2.1.2], [LSCO.4.5.9])*

### `scope logical`

**`schema Foo scope logical:`**

A `logical` fact is one state per identity key, replaced on each meaningful change and live until the next one or until its [justification](logical.md#justifiers) ends.

Every slot but `ts` is [`key` or `mutable`](schemas.md#key-and-mutable). A rule asserts one with `emit X logical`, and truth maintenance covers it. A source outside the rules also asserts one.

*(Spec: [LFAC.1.2.1], [LFAC.1.2.2], [LFAC.1.2.3], [LFAC.1.7.2], [LSCP.2.2.1])*

### `scope ttl`

**`schema Foo scope ttl <duration>:`**

A `ttl` fact is one event: facts of one schema accumulate, and each is retracted once the duration has passed since its assertion.

No identity applies, and no marker is admitted. The duration is the schema's default per-fact TTL, and expiry reads the monotonic clock. A rule asserts one with a plain `emit`, and [`retain:`](../capabilities/dynamic-ttl.md#per-emit-retain) sets a TTL per emit.

```ds declaration
schema Pulse scope ttl 100_ms:
    id: String
```

*(Spec: [LFAC.1.3.1], [LFAC.1.3.2], [LFAC.1.3.3], [LFAC.1.7.6], [LGRA.5.2], [LSCP.2.3.1], [LTIM.2.8.2])*

### `scope activation`

**`schema Foo scope activation:`**

An `activation` fact is asserted by an `emit` in a rule's actions and retracted on every completion path of that activation, as [Activation-scoped lifetime](#activation-scoped-lifetime) states.

*(Spec: [LSCP.2.4.1], [LSCP.6.3])*

### `ambient`

**`schema Foo scope logical ambient:`**

`ambient` makes a `logical` schema read-only to rules, keeping its lifecycle and identity.

An `emit` or `publish` of an ambient schema is refused with `DS_VALIDATE_AMBIENT_EMIT_FORBIDDEN`, and [`withdraw`](#withdrawal-scope) does not reach it. Patterns match it. A source outside the rules drives its assertion and retraction: a host, a test harness, or a publish from another tier. It carries no justification. Its rows are matched individually.

```ds rule error=DS_VALIDATE_AMBIENT_EMIT_FORBIDDEN
schema Feed scope logical ambient:
    id: String key

rule write_feed:
    Reading r
->
    emit Feed logical id: r.id
```

*(Spec: [LSCP.2.5.1], [LSCP.2.5.2], [LSCP.2.5.5], [LSCP.2.5.6], [LSCP.2.5.7], [LSCP.2.5.8], [LSCO.4.5.9], Source: compiler/mercury/src/dsc.validate.m)*

### `internal`

`internal` is the scope of the [built-in fault schemas](builtin-schemas.md#the-built-in-schemas): no author declares it.

The lifecycle is `explicit`, except that only the engine asserts the facts. Patterns match them and a rule may `withdraw` one it matched. An `emit` is refused with `DS_VALIDATE_INTERNAL_EMIT_FORBIDDEN`.

*(Spec: [LSCP.2.6.1], [LSCP.2.6.2], [LIMP.12.4])*

### Withdrawal scope

**`withdraw <binding>`**

`withdraw` is admitted on a binding of an `explicit` or `internal` schema; any other is refused with `DS_VALIDATE_WITHDRAW_SCOPE`.

```ds rule error=DS_VALIDATE_WITHDRAW_SCOPE
rule drop_reading:
    Reading r
->
    withdraw r
```

*(Spec: [LSCO.4.5.9], [LLOG.2.8.2], [LLOG.11.8])*

## Lifecycle categories

### Categories and verbs

`logical` and `ttl` are the two lifecycle categories, and a rule's verb must agree with the schema's.

| Schema | `emit X` | `emit X logical` |
|---|---|---|
| `logical` | refused | asserts, truth-maintained |
| `ttl`, `explicit`, `activation` | asserts | refused |

A refused row is `DS_VALIDATE_BAD_LIFECYCLE_FLAG`. A pattern matches a fact of either category with no special syntax, and the category belongs to the fact, not the rule.

*(Spec: [LFAC.1.2.5], [LFAC.1.3.5], [LFAC.1.6.1], [LFAC.1.6.2], [LLOG.11.1], Source: compiler/mercury/src/dsc.validate.m)*

### Absence by category

**`no X`**, **`no X within <duration>`**

`no X` on a `logical` schema tests for no live fact; `no X within <duration>` on a `ttl` schema tests for no matching fact in that last duration.

*(Spec: [LFAC.3.3], [LFAC.3.4])*

### `within` on a logical pattern

[`within <duration>`](../time/types.md#within) on a `logical` pattern matches a live fact whose last meaningful change falls within that duration.

*(Spec: [LFAC.2.7.4])*

### Identity

Two assertions of one `logical` schema with equal key values are one fact: the later supersedes the earlier, its payload replacing the prior.

| Keys | Shape | Behaviour |
|---|---|---|
| none | singleton | one live fact |
| one slot | entity-state | one live fact per key value |
| several slots | composite key | one live fact per combination |
| every slot | relation | distinct tuples coexist; identical tuples coalesce |

Key comparison is exact. Two `Float` keys are equal under IEEE 754 `==`, so `-0.0` and `0.0` are one identity. `String` and `Bytes` keys compare by bytes. A NaN `Float` never reaches a key. `ambient` does not change identity.

*(Spec: [LFAC.1.7.1], [LFAC.1.7.2], [LFAC.1.7.3], [LFAC.1.7.7], [LFAC.2.5.4])*

## Reassertion

### No-op reassertion

A reassertion of a live `logical` fact with equal slot values changes nothing: the fact is not retracted or re-entered.

`dwell` does not reset, no series sample is generated, and derived `logical` facts do not flicker. The live fact keeps its `ts`. The engine makes the comparison, for every source and every `emit X logical`.

*(Spec: [LFAC.2.1], [LFAC.2.2], [LFAC.2.3], [LFAC.2.4], [LFAC.2.5.1], [LFAC.2.6.1], [LFAC.2.6.2], [LFAC.2.6.3], [LFAC.2.7.5], [LLOG.6.1])*

### Equality for the no-op test

The comparison covers the author's slots; `ts` takes no part.

| Slot | Equal when |
|---|---|
| `String`, `Bytes` | same bytes |
| `Bool`, `Int` | exact equality |
| `Float` | IEEE 754 `==`, so `0.0` and `-0.0` are equal |
| `Json` | [deep structural equality](../values/json.md#json-equality); an integer and a float differ, so `1` and `1.0` are not equal |
| with [`tolerance`](schemas.md#tolerance) | exactly equal, or `\|delta\| <= tolerance` |

The tolerance bound is inclusive, compared on a unit-typed slot in its base unit. A change of exactly the tolerance is suppressed. Two equal infinities are equal under any tolerance.

*(Spec: [LFAC.2.5.1], [LFAC.2.5.4], [LUNI.7.4])*

### Meaningful change

A reassertion that is not a no-op replaces the fact: the prior fact for the key is retracted and a new one asserted.

One live fact per key remains. The new fact is another fact to [fact-reference equality](schemas.md#fact-references), takes a new entry stamp, and advances `ts`. No path mutates a fact in place, and none leaves a second live fact for the key.

*(Spec: [LFAC.2.5.3], [LTIM.2.8.6])*

## Activation-scoped facts

### Activation-scoped lifetime

An `activation` fact enters when its `emit` executes and is retracted as each completion path of the activation resolves.

The completion paths are the synchronous end of the actions, an `after` timer's firing, an `on response` match, an `on timeout` firing and an `on error` firing. Retraction is idempotent across paths; a fact on several paths is retracted when the first of them ends.

When the fact carrying a deferred path is superseded or withdrawn before it fires, the facts attached to that path are retracted at that withdrawal.

*(Spec: [LSCP.2.4.1], [LSCP.2.4.2], [LSCP.3.1], [LSCP.3.3], [LSCP.6.5])*

### Synchronous activation

In a rule with no `after` and no `call` continuation, an `activation` fact is asserted and retracted within one pump.

*(Spec: [LSCP.3.2])*

### Activation-scoped facts as facts

An `activation` fact carries the slot values of its `emit`, is matched by other rules' patterns and appears in the event trace.

Two activations with different slot values produce different instances. Matching one in another rule does not retract it.

```ds rule
schema Step scope activation:
    id: String

rule mark_step:
    Reading r
->
    emit Step id: r.id
```

*(Spec: [LSCP.2.4.3], [LSCP.2.4.4], [LSCP.6.5])*

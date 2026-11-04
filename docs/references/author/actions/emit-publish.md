<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Emit and publish

## Emit and publish verbs

### `emit`

**`emit <schema> [logical] <slot>: <value> ...`**

`emit` asserts a fact into the current tier's working memory, visible to that tier's rules alone.

The schema is a [schema reference](../lang/program.md#schema-references). The `logical` flag agrees with the schema's lifecycle, as [Categories and verbs](../facts/lifecycles.md#categories-and-verbs) states, and its effect is [`emit X logical`](../facts/logical.md#emit-x-logical). The arguments are at [Argument inventory](actions.md#argument-inventory).

```ds rule
schema Note scope logical:
    id: String key

rule note:
    Reading r
->
    emit Note logical id: r.id
```

*(Spec: [LGRA.10.1], [LTIE.4.2])*

### `publish`

**`publish <schema> <slot>: <value> ...`**

`publish` sends a fact to every tier connected upstream, and asserts nothing in the current tier's working memory.

No rule on the publishing tier matches what that tier publishes. A rule that needs the fact in both tiers writes `emit X` and `publish X`. Cross-tier assertion requires `publish`.

The `logical` keyword and a `retain:` kwarg on a `publish` are refused with `DS_VALIDATE_PUBLISH_MODIFIER`. The fact's lifetime is the [receiving schema's](#receiving-a-published-fact).

A `publish`'s values are judged as an `emit`'s: `ts` is filled first, a fault in a slot value abandons the activation, a value its slot does not admit raises a `TypeError`, and a `String` longer than its slot's `capacity` is refused. A refused `publish` sends nothing. No working-memory or series bound applies to a `publish`, and it has no deadline. How a host carries the fact is [Stream events](inv:integrator:std:doc#callbacks/stream).

```ds rule
schema Note scope ttl 1_h:
    text: String

rule note:
    Reading r
->
    publish Note text: "id {r.id}"
```

*(Spec: [LGRA.10.1], [LTIE.4.3], [LTIE.4.4], [LTIE.4.8], [LTIE.4.9], [LTIE.9.3])*

## Tiers

### Tier

A tier is a runtime-engine instance with its own working memory, clock source and dialect.

A deployment has one tier or many, and the language contract is the same. Each tier runs its own rules, compiled for its dialect. Tiers cooperate through `publish`; everything else is local to one tier, its [cache](cache.md#ownership) included.

*(Spec: [LTIE.1.1], [LTIE.1.2], [LTIE.1.3], [LTIE.1.4], [LTIE.1.5], [LTIE.1.7], [LTIE.9.1])*

### Upward-only rule

Facts flow from a lower tier to a higher tier, and never downward.

The tier graph is a directed acyclic graph. The compiler does not enforce this, as [Across tiers](../rules/cycles.md#across-tiers) states. The integrator wires tiers together and keeps the graph acyclic.

*(Spec: [LTIE.3.1], [LTIE.3.2], [LTIE.3.5], [LTIE.9.2], [LTIE.9.6])*

### Downward influence

A higher tier affects a lower tier through a [`call`](../calls/call.md#call), never a fact.

The lower tier observes a call's result, not a fact its rules match. Call responses follow the normal fact path.

*(Spec: [LTIE.3.4], [LTIE.5.1], [LTIE.5.3], [LTIE.5.4])*

## `publish` per lifecycle

### Receiving a published fact

A published fact crosses a tier boundary as its schema name and slot values, and the receiving tier asserts it under its own declaration of that schema.

Its lifecycle category and any TTL are the receiving schema's, the TTL counted from that assert.

*(Spec: [LTIE.9.4])*

### `publish` on a `logical` schema

Each upstream tier asserts the fact as it asserts an adapter's, with the same no-op reassertion and retract-on-key-change, and holds it with no justifier from the publishing tier, as [Across tiers](../facts/logical.md#across-tiers) states.

When two tiers publish a `logical` fact with one key to a third, the third holds one fact, and an identical second assert is a [no-op reassertion](../facts/lifecycles.md#no-op-reassertion). A retraction in the publishing tier reaches the receiving tier only if the integrator carries it.

*(Spec: [LTIE.4.6.1], [LTIE.4.6.2], [LTIE.9.4], [LTIE.9.5])*

### `publish` on a `ttl` schema

Each upstream tier asserts the fact under its own declaration of the schema and expires its copy independently. Facts from several publishing tiers accumulate, with no cross-tier coalescence.

*(Spec: [LTIE.4.7.1], [LTIE.9.4])*

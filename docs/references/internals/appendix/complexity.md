<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Complexity

## Operation costs

Each network operation has a fixed cost bound.

| Operation | Cost |
|---|---|
| alpha dispatch of a fact | O(1) schema-ID index, plus O(alpha nodes for the schema) test evaluation |
| beta join, right activation | O(left memory × alpha memory) per join node in the worst case |
| agenda | binary heap; insert and remove O(log n); size bounded by rules × live facts |

The hash-map costs are [oa operations](../engine/rete-network.md#oa-operations).

*(Spec: [IRET.17.2], [IRET.17.3], [IRET.17.4], Source: runtime/src/libds/rete/agenda.h)*

## Costs under linear_scan false

### Scope of the bounds

The bounds under this heading hold for a program that compiles under [`linear_scan: false`](inv:author:std:doc#capabilities/linear-scan).

*(Spec: [LNLS.5])*

### Join node retraction

A retraction on a join node, from either direction, is O(1) and evaluates no join test.

| Direction | Index | Joined entries |
|---|---|---|
| right retraction of a fact | `right_idx` | one token |
| left retraction of a token | `ltok_idx` | one fact |

The node's anchor is [Equality anchor under linear_scan false](../engine/rete-network.md#equality-anchor-under-linear_scan-false).

*(Spec: [LNLS.5.1])*

### Alpha test

An alpha test on a slot that is not a `String`, or an interned pointer comparison, is O(1).

An alpha node's tests cost O(T) per fact assert, where T is its test count, a compile-time constant. The other `String` tests are at [String operations](#string-operations).

*(Spec: [LNLS.5.2])*

### Supersedure lookup

Finding the fact an assertion supersedes is O(1) amortized for every `logical` schema.

The lookup reads the declared key. A schema whose key is empty holds at most one live fact. Removing the superseded fact costs [Fact removal](#fact-removal).

*(Spec: [LNLS.4.7], [LNLS.5.3])*

### Fact removal

Removing a fact from working memory is O(1) amortized in the live facts of its schema, whatever removes it: a supersedure, a retraction, a withdrawal or an expiry.

The bound covers every structure the removal updates, the per-rule record of facts already fired on and the release of the fact's values among them. Two terms are outside it.

| Fact | Added term |
|---|---|
| a fact in the deadline heap | O(log N_ttl), under [TTL fact costs](#ttl-fact-costs) |
| a `TimeZoneOffset` fact | O(log r) to leave its zone's index, where r is the live facts of that zone |

Each fact a cascade removes costs this bound again.

*(Spec: [LNLS.4.7], [LDTL.1.2], [LTIM.10.7])*

### Series absorb

A series absorb costs what its [backend](../values/series-backends.md)'s row states.

| Backend | Absorb |
|---|---|
| ring buffer | O(1) |
| FIFO deque | O(1) amortized |
| Welford | O(1) |
| monotonic deque | O(1) amortized |
| reservoir | O(1) |
| interval pulse | O(1) amortized |
| numeric integral | O(1) amortized |

*(Spec: [LNLS.4.8], Source: runtime/src/libds/series/monotonic_deque.c)*

### String operations

A string operation on a `String` slot costs its row's bound, in which `capacity` is a compile-time integer literal.

| Operation | Bound |
|---|---|
| `<`, `>`, `<=`, `>=` in single-pattern position | O(capacity) |
| `~`, `!~` | O(capacity × P), with P fixed in the `.dsc` |
| `==`, `!=` | O(1), by interned pointer, with or without `capacity` |
| `len` | O(1), stored with the interned string, with or without `capacity` |

*(Spec: [LNLS.5.7], [LNLS.3.10])*

## Costs of dynamic_ttl

### TTL fact costs

Asserting and retracting a `ttl` fact cost what the [`dynamic_ttl`](inv:author:std:doc#capabilities/dynamic-ttl) setting's column states.

| Operation | `dynamic_ttl: false` | `dynamic_ttl: true` |
|---|---|---|
| assert | O(1), an append to the schema's queue | O(log N_ttl), a heap insert |
| retract | O(1), a splice from the schema's queue | O(log N_ttl), a heap remove |

N_ttl is the number of `ttl` facts in the deadline heap. Under `dynamic_ttl: true` the heap holds every `ttl` fact, with or without a `retain:` override, and the costs hold for each. The expiry mechanism is [TTL sweep and tick](../engine/rete-network.md#ttl-sweep-and-tick).

*(Spec: [LDTL.3.1], [LDTL.4.2])*

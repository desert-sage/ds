<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Truth maintenance

## Justification count

libds implements [logical facts](../overview/runtime-architecture.md#logical-facts) with a count of live justifications on each logical fact and a dependency table from each activation to the facts it supports.

On every program the compiler admits, support is acyclic: no strongly connected component both emits and matches a schema. A fact's count is its fact record's `justif_count`; two activations supporting one fact give it a count of 2.

*(Spec: [IRET.1.8], [IRET.12.2], [IRET.12.3])*

## Justification

A firing's `ACTION_LOGICAL_ASSERT` records a justification for the logical fact F it emits.

1. Assert F into working memory; this is a no-op when F already exists with matching slot values.
2. Increment `F->justif_count`.
3. Record `(activation → fact_id)` in the dependency table.

*(Spec: [IRET.12.1])*

## Withdrawal

When an activation ends, its justifications are withdrawn.

An activation ends when its token is retracted: a supporting LHS fact was retracted, or a NOT condition stopped holding.

1. Look up the logical facts the activation supports in the dependency table.
2. Decrement each one's `justif_count`.
3. Retract each fact whose count reaches 0, emitting a `fact_retract` stream event. The retraction may cascade through the network.
4. Remove the activation's dependency-table entry.

An activation can end inside its own firing, when an action of the firing retracts a fact its token holds. The steps run at that action, and the firing continues. A logical fact the firing asserts after that action is not recorded against the ended activation: it is retracted as it is asserted, unless another live justification already holds it.

The clock tick's turnover ends no match. The tick is not a supporting fact, and the steps do not run when the only change to a token is the tick. The activation formed again with the new tick takes over the justifications of the one the tick's retraction removed (`carry_across_tick`). The activation ends, and its justifications are withdrawn, on the tick at which its time-dependent test goes false.

*(Spec: [IRET.12.2])*

## Dependency table

The dependency table is an [`oa`](rete-network.md#oa) map keyed by the justifying activation's creation timetag, which no two activations share.

Each value holds the activation's rule name and the IDs of the logical facts it justifies: up to 16 inline, with overflow in a heap list.

*(Spec: [IRET.12.4])*

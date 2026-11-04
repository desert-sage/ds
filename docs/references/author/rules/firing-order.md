<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Firing order

## The order

### Total order

When more than one activation matches at one clock instant, they fire by:

1. the rule's source order;
2. within one rule, activation-creation order.

The same event trace in two conforming engines gives the same activation order. The order depends on the inputs, so it is not readable from source text alone.

The mechanism is at [Agenda and actions](inv:internals:std:doc#engine/agenda-and-actions) and [Determinism](inv:internals:std:doc#guarantees/determinism).

*(Spec: [LDET.4.2], [LDET.5.1])*

### Source order

Within a file, the rule written first fires first. Across files, the order is import-graph topological order, leaf libraries first.

*(Spec: [LDET.5.4])*

### Creation order

Among activations of one rule, a match that completed earlier fires first. A match completes when the last of its facts enters working memory, and a replaced fact enters anew.

Matches that complete together, from one assertion, order lexicographically by their facts, pattern by pattern from the first, each fact ranked by when it entered working memory.

*(Spec: [LDET.5.5])*

### Blocked matches

A match held back by a negated condition keeps its place. When released, it fires where the time it first completed puts it, not as a new match.

*(Spec: [LDET.5.9])*

### Removal order

One step that removes several things removes them in this order, and everything they produce follows it:

| Removed | Order |
|---|---|
| facts | when each entered working memory |
| facts a TTL sweep expires | deadline, earliest first, then when each entered working memory |
| cache entries | when each entry's key was last set |

*(Spec: [LDET.5.11])*

## What an author relies on

### Guaranteed

For one rule set and one event trace:

- a test result holds on every run on every conforming runtime;
- a recording replayed against the same rules and the same mocked responses reproduces the session;
- a debugger shows the same state at the same instant on every run;
- a difference between two runs comes from a difference in the rules or the trace.

*(Spec: [LDET.7.1], [LDET.7.2], [LDET.7.3], [LDET.7.4], [LDET.7.5])*

### Not guaranteed

- The same behaviour between two runs outside replay, where service responses differ. The guarantee is over the event trace, not the wall clock.
- The same performance across runtimes.

*(Spec: [LDET.7.7], [LDET.7.9], [LDET.7.10])*

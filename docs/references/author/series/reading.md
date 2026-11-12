<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Reading a series

## Cursors

### Series cursor

**`binding`**, **`binding.label`**, **`binding.slot`**, **`binding.slot.label`**

A series cursor is a compile-time designator of one observation on one slot.

| Form | Required when |
|---|---|
| `binding` | one series-carrying slot, unlabelled line |
| `binding.label` | one series-carrying slot, labelled line |
| `binding.slot` | several series-carrying slots, unlabelled line |
| `binding.slot.label` | several series-carrying slots, labelled line |

The compiler accepts the shortest form that resolves unambiguously.

```ds expression series
mean(r)
p95(r.bag)
mean(r.level)
p95(r.level.bag)
```

*(Spec: [LEXP.16.1], [LSER.6.10.1], [LSER.6.10.2], [LSER.6.10.3], [LSER.10.6])*

### Companion slot

**`cursor.<agg>`**, **`<agg>(cursor)`**

`cursor.<agg>` is the same read as `<agg>(cursor)`, in any expression position.

`count_of` and `contains` take a value, and have the call form alone. A chain whose last component is not an aggregation name resolves as a slot read or a `Json` path. `t.slot` as a call's first argument designates the slot, and elsewhere reads its value. [`Series aggregations`](../expr/operators.md#series-aggregations) states how a read composes.

```ds expression series
r.mean
mean(r)
count_of(r, 1.0)
contains(r, 1.0)
```

*(Spec: [LEXP.16.3], [LGRA.7.11.1], [LGRA.7.11.2], [LGRA.7.11.3], [LSER.6.1], [LSER.6.2], [LSER.6.3], [LSER.6.4], [LSER.6.5], [LSER.6.11.2], [LSER.16.1])*

### Cursor resolution

A cursor narrows by its slot, then its label, then the observations covering the aggregation; exactly one must remain.

| Condition | Code |
|---|---|
| no observation covers it, or no series is declared | `DS_VALIDATE_NO_SERIES_FOR_COMPANION_SLOT` |
| several slots' series declare it | `DS_VALIDATE_AMBIGUOUS_COMPANION_SLOT` |
| any argument after the cursor, and after the value of `count_of` and `contains` | `DS_VALIDATE_BAD_ARITY` |

A read's window is the window of the declaration it resolves to.

```ds expression error=DS_VALIDATE_NO_SERIES_FOR_COMPANION_SLOT
r.mean
```

*(Spec: [LSER.6.7.1], [LSER.6.9.1], [LSER.6.9.2], [LSER.6.9.3], [LSER.6.9.4], [LSER.6.9.5], [LSER.6.9.6], [LSER.6.11.1], [LSER.6.11.3], [LSER.10.5])*

### Labels

**`as <label>`**

`as <label>` namespaces every aggregation of its line under the label, read as `t.<label>.<agg>`.

A labelled line produces no `t.<agg>`. An aggregation with a line under a label is read through that label.

| Condition | Code |
|---|---|
| several lines on a slot cover one aggregation, not all labelled | `DS_VALIDATE_SERIES_DUPLICATE_AGG_NEEDS_LABEL` |
| two lines under one label declare one aggregation | `DS_VALIDATE_SERIES_DUPLICATE_DECL` |
| a label equal to a slot name of the schema | `DS_VALIDATE_COMPANION_SLOT_COLLISION` |
| an unlabelled read of an aggregation that exists only under labels | `DS_VALIDATE_NO_SERIES_FOR_COMPANION_SLOT` |

```ds expression series
r.bag.p95
p95(r.bag)
```

*(Spec: [LSER.6.8.1], [LSER.6.8.2], [LSER.6.8.3], [LSER.6.8.4], [LSER.6.8.5], [LSER.6.8.6], [LSER.6.8.7], [LSER.6.12.1], Source: compiler/mercury/src/dsc.series.m)*

### Reserved aggregation names

An aggregation name is a [reserved word](../lang/lexical.md#reserved-words), and a slot declared under one is refused with `DS_VALIDATE_COMPANION_SLOT_COLLISION`, whether or not the schema has a series.

*(Spec: [LSER.6.6.1], [LLEX.9.7])*

## Cold reads

### Cold read

A read is cold when its backing holds no sample to aggregate for the identity: before the first absorption, or once every absorbed sample has left the window.

Its value is at [Series reads](../values/null.md#series-reads). `active_fraction`, `onset_rate` and `integral` read the slot as a step function, each absorbed value held until another is absorbed, so each of the three is cold only before the first absorption.

*(Spec: [LSER.19.8], [LSER.9.3.1], [LSIG.1.3.1], [LSIG.3.2], [LSIG.8.1])*

### Restart

A series lives in working memory, and starts empty after an engine restart.

A replay of a rule reading an aggregation matches byte for byte when its recording began at a cold engine.

*(Spec: [LSER.8.3.4], [LSER.9.2.1], [LSER.9.2.1a], [LSER.10.11])*

### Eviction

A `sliding` backing with no sample absorbed for its own declared window is evicted at the next pump that reads an advanced clock, and the next sample for the identity starts again from empty.

The state a signal aggregation reads is not evicted: the last absorbed value, any open interval and the time of the instance's first sample persist for the instance's life, and a stuck `true` reads as `true`. What `nulls: hold` keeps across eviction is at [Series null absorption](../values/null.md#series-null-absorption). An `all_time` backing lives until engine shutdown.

*(Spec: [LSER.9.3.1], [LSER.9.3.2], [LSER.19.7], [LSIG.5.4])*

## Interactions

### Samples

A series takes one sample of its slot per fact that enters working memory.

A meaningful change to any of the fact's slots is a new fact, and adds a sample whether or not the tracked slot changed. A no-op reassertion adds none. A retract ends the fact, and a later fact on the key absorbs its own sample. A fact superseded within a pump still contributes its sample.

*(Spec: [LSER.8.5.1], [LSER.8.6.5])*

### Sample and fire order

Samples absorb once per pump, after the agenda has drained, in fact-assert order.

Every rule firing in a pump, and its actions, reads the snapshot that held when the pump began, whichever assertion activated it. A rule firing for a fact does not read that fact's own sample.

*(Spec: [LSER.8.6], [LSER.8.6.1], [LSER.8.6.3], [LSER.8.6.4], [LSER.10.14])*

### Time-dependent reads

A `where` that reads an aggregation is [time-dependent](../facts/logical.md#time-dependent-tests).

It is re-evaluated when the pattern's bindings change and at every pump, against the pump's snapshot, and its rule fires once per false-to-true edge for a matched fact. A `logical` fact it justifies is retracted at the pump whose snapshot refuses the match. On a rule with more than one positive pattern it is refused, as [`where` on a join](../expr/operators.md#where-on-a-join) states. A pump does not add a sample to a series.

```ds rule series
rule high_mean:
    Reading r where r.mean > 10.0
->
    log info "{r.id}"
```

*(Spec: [LSER.8.1.1], [LSER.8.4.1])*

### `dwell`

[`dwell`](../facts/logical.md#dwell) needs no declared series.

*(Spec: [LSER.8.2.1], [LSER.10.4])*

### Tiers

Each engine keeps its own series state.

A fact [published](../actions/emit-publish.md#publish) from another tier absorbs into the receiver's series as an ordinary assertion.

*(Spec: [LSER.8.7.1])*

### Purity

An aggregation read computes its value as of the query clock from stored state, and changes no state.

The same read twice at one instant answers alike, however many rules read it.

*(Spec: [LSER.8.8.1], [LSER.8.8.2])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Series declarations

## Declaration

### `series`

```text
series_decl       ::= 'series' slot_ref block_opts? ':' NEWLINE
                      INDENT docstring? series_line+ DEDENT

slot_ref          ::= (NAME '.')? NAME

block_opts        ::= '(' block_kwarg (',' block_kwarg)* ')'
block_kwarg       ::= 'by' ':' (NAME | 'none')
                    | 'capacity' ':' INT_LIT
                    | 'nulls' ':' ('skip' | 'hold' | 'zero')

series_line       ::= agg_list time_model accuracy? gap_policy? ('as' NAME)? NEWLINE
agg_list          ::= agg_name (',' agg_name)*
agg_name          ::= NAME
gap_policy        ::= 'gap' ('hold' | 'zero' | 'skip')
time_model        ::= 'all_time'
                    | 'sliding'  duration
                    | 'tumbling' duration
                    | 'sample'   INT_LIT
accuracy          ::= 'exact'
                    | 'tolerance'  FLOAT_LIT
                    | 'confidence' FLOAT_LIT
                    | 'delta'      FLOAT_LIT
                    | 'bound' 'deterministic'
```

A `series` declaration names the aggregations to maintain over a slot's history, at file scope.

The body is one or more observation lines, each naming [aggregations](aggregations.md#aggregation-catalogue) and a [time model](time-models.md#time-model-phrases). A body with only a docstring is a compile error. The word `as` labels a line, as [Labels](reading.md#labels) states. `gap_policy` is [Gap policy](signal.md#gap-policy), and `accuracy` is refused, as [Accuracy phrases](time-models.md#accuracy-phrases) states. The [`series`](../capabilities/registry.md#capability-table) capability governs these declarations and the aggregations.

```ds declaration
series Reading.level (by: id, capacity: 500):
    mean, max sliding 10_min
    p95 sample 200 as bag
```

*(Spec: [LGRA.7.1], [LGRA.7.2], [LGRA.7.9], [LSER.7.1], [LSER.13.1], [LSER.13.5], [LGRA.7.6], [LGRA.7.6a], [LGRA.7.10.1], [LCAP.1])*

### Backing selection

The compiler picks the backings that hold a series' state from its observation lines.

The backings are [Series backends](inv:internals:std:doc#values/series-backends), and which aggregation each time model admits is the matrix at [LSER.18.1](inv:specs:std:label#lser-18-1).

*(Spec: [LSER.13.3], [LCNT.7.2])*

### One declaration per file

A file holds one series declaration per slot path; a second is refused with `DS_VALIDATE_SERIES_DUPLICATE_DECL`.

Declarations on one slot path in different files are independent, and a file's rules read the observations it declared.

*(Spec: [LSER.10.15], [LSER.13.6])*

## The slot

### Slot reference

**`<slot>`**, **`<Schema>.<slot>`**

An unqualified `slot_ref` binds to the one schema in scope with a slot of that name; the qualified form names the schema.

| Condition | Code |
|---|---|
| no schema in scope has the slot, or the named schema does not | `DS_VALIDATE_SERIES_UNKNOWN_SLOT` |
| two or more schemas in scope have the slot, unqualified | `DS_VALIDATE_SERIES_AMBIGUOUS_SLOT` |
| the qualified schema is not declared | `DS_VALIDATE_SERIES_UNKNOWN_SCHEMA` |

```ds declaration error=DS_VALIDATE_SERIES_UNKNOWN_SLOT
series Reading.missing:
    mean sliding 10_min
```

*(Spec: [LGRA.7.3], [LSER.7.7.1], [LSER.7.7.2], [LSER.7.7.3], [LSER.7.7.4], [LSER.10.17], [LSER.13.7], [LSER.13.8])*

### Schemas and samples

A series is declared on a `logical` or a `ttl` schema.

On `logical`, a sample enters on a meaningful change alone, as [No-op reassertion](../facts/lifecycles.md#no-op-reassertion) states. On `ttl`, every fact assertion absorbs as a sample. A series holds samples of a slot's history, across all activations.

*(Spec: [LSER.7.6.3], [LSER.10.13], [LSER.10.20])*

## Block options

### Block option values

`by:`, `capacity:` and `nulls:` apply to the whole block, and any other option name is a parse error.

Each takes the value its production names. An option given twice is refused with `DS_VALIDATE_SERIES_DUPLICATE_KWARG`. `nulls:` is [Series null absorption](../values/null.md#series-null-absorption).

*(Spec: [LSER.13.4], [LSER.13.9], [LSER.13.10], [LSER.13.11])*

### `by:`

**`by: <slot>`**, **`by: none`**

`by:` names the one slot a series keeps state per value of; `by: none` keeps one state per schema and slot.

With `by:` omitted:

| Schema | Identity |
|---|---|
| `logical`, one `key` slot | that slot |
| `logical`, several `key` slots or none | refused with `DS_VALIDATE_SERIES_NO_IDENTITY_SLOT` |
| `ttl` | refused with `DS_VALIDATE_SERIES_NO_IDENTITY_SLOT` |

A `by:` naming a slot the schema does not have is refused with `DS_VALIDATE_SERIES_BAD_IDENTITY_SLOT`.

*(Spec: [LSER.7.6.1], [LSER.7.6.2], [LSER.10.13])*

### `capacity:`

**`capacity: N`**

`capacity:` caps the samples each identity retains, for every backing the block's lines select that retains samples.

`N` below 1 is refused with `DS_VALIDATE_CAPACITY_NOT_POSITIVE`, and below the `n` of any `sample <n>` line with `DS_VALIDATE_SERIES_CAPACITY_BELOW_SAMPLE`. With no `capacity`, a window bounds the samples.

The count is the samples retained inside the window, plus each sample admitted for that identity in the current pump and not yet absorbed. A step aggregation's carried value before the window start is not counted. A `null` reading counts when the `nulls:` policy absorbs a value for it.

| Aggregation at capacity | Effect |
|---|---|
| `active_fraction`, `integral` | a [bounds refusal](../errors/dispositions.md#bounds-refusal) naming `CAP_SERIES_CAPACITY`: the fact is not asserted, and no line of the block absorbs the sample |
| every other aggregation | the identity's oldest sample is evicted, the fact is asserted, and a read covers the samples retained |

*(Spec: [LSER.13.14], [LSER.18.1], [LSIG.1.1])*

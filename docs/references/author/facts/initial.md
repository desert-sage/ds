<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Initial block

## Declaration

### `initial`

```text
initial_block ::= 'initial' ':' INDENT test_initial_item+ DEDENT
test_initial_item ::= test_fact | test_cache_seed | test_cache_block
test_fact ::= type_ref action_arg* NEWLINE
test_cache_seed ::= 'cache' STRING_LIT ':' expression NEWLINE
test_cache_block ::= 'cache' ':' INDENT test_cache_entry+ DEDENT
test_cache_entry ::= STRING_LIT ':' expression NEWLINE
```

`initial` declares a ruleset's starting facts and cache keys, in place before any rule is evaluated.

The artefact carries the block. No dialect gates it or its cache items.

```ds declaration
schema Mode:
    name: String

initial:
    Mode name: "auto"
    cache "limit": 10
```

*(Spec: [LGRA.24], [LGRA.24.1], [LGRA.24.2], [LGRA.21.1])*

### Initial block refusals

| Condition | Code |
|---|---|
| a second block in a file, or a block after a rule | `DS_VALIDATE_INITIAL_PLACEMENT` |
| a fact of a schema that is not `scope explicit` | `DS_VALIDATE_INITIAL_BAD_SCOPE` |
| a value that is neither a literal nor the name of a `const` | `DS_VALIDATE_INITIAL_NOT_CONST` |

Every file may hold one block, a library included. A fact item gives every author-supplied slot.

```ds declaration error=DS_VALIDATE_INITIAL_BAD_SCOPE
initial:
    Reading id: "a" level: 0.0 n: 0 label: "" ok: true
```

*(Spec: [LGRA.24.2])*

## Application

### First step

The engine applies every item at its first step, the first time it consumes an input or begins a pump, under that step's sample.

The items apply before the step's input is consumed and before any rule is evaluated. Between the load and the first step, working memory and the cache hold none of them.

*(Spec: [LGRA.24.3])*

### Application order

Within a file, items apply in source order; across files, a file's block applies after the blocks of the files it imports, leaf libraries first.

An importer's cache item therefore overwrites a library's for one key.

*(Spec: [LGRA.24.3])*

### Fact items

A fact item supplies no `ts`: its entry stamp is the step's monotonic sample, and its `ts`, where declared, is the step's wall sample.

A fact item whose `ts` the wall clock cannot fill is not placed, and raises a `ComputationError`.

*(Spec: [LGRA.24.3], [LFAC.9.2], [LTIM.2.8.3])*

### Cache items

A cache item seeds its key as the host's cache seed does: it raises no cache event and calls no write-through.

It overwrites a value an earlier item of the same application placed. A key the host seeded before the block applies keeps the host's value.

*(Spec: [LGRA.24.3])*

### Recording

Applying the block records no item in a fact stream.

A replay against the same artefact applies the block at its first step, under the recorded sample.

*(Spec: [LGRA.24.3])*

### Bounds refusal

An item that would exceed a declared cap refuses the step: none of the block and none of the step's input applies, and no rule is evaluated.

The block stays pending, and the next step applies it from its first item.

*(Spec: [LGRA.24.3])*

### Under a test

A `.dstest`'s own [`initial`](../tools/dstest.md#initial) overlays the ruleset's blocks.

Its cache entries are host seeds, so a block's cache item for one of those keys leaves the test's value. Its facts are host asserts, the first of which is the first step, so the block applies ahead of them.

*(Spec: [LGRA.24.3])*

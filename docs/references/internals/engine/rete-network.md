<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The Rete network

## Engine

### Scope

The C Rete network implements exactly the pattern forms, expression operators and action verbs the DS lowering emits, and nothing else.

It is libds's only rule-evaluation substrate, and nothing selects it. No textual rule language is parsed at runtime: the network topology and every expression tree arrive in binary form. The network spawns no thread and runs no background work.

*(Spec: [IRET.1.1], [IRET.1.2], [IRET.1.14], [IRET.15.1])*

### Feature mechanisms

Each DS feature the compiler emits maps to one network mechanism.

| DS feature | Mechanism |
|---|---|
| schema and slot types | schema descriptors; value arrays of the kinds in [Value storage](#value-storage) |
| `Schema s` pattern | alpha node, all slots bound |
| `where slot == literal` | alpha test |
| `where slot ~ /…/` | alpha regex test |
| `where` clause | join test over bound variables |
| `no Schema` | NOT node |
| `within <dur>` | join test over the monotonic sample minus the fact's `assert_ns` |
| `then … within` | multi-pattern join chain with a join test on `ts` ordering |
| `latest` | NOT sub-node excluding older anchors |
| refraction | per-terminal refraction table keyed by token identity |
| `emit X` | RHS assert action |
| `emit X logical` | RHS assert action and truth-maintenance registration |
| pure `let` | folded at compile time; no network mechanism |
| sync-impure `let` (`now()`, `monotonic_ns()`) | bind-once in the RHS expression context |
| async `let` | request and response rules; no network primitive |
| cooldown | the terminal's `fire_guard`, or a call site's gate, calling `FN_RATE_ALLOW` |
| `log`, `call`, `publish`, `cache` | RHS expression nodes dispatched to builtins |
| series aggregation in `where` | join test calling a series builtin |
| `$ClockTick` | schema with no slots; its assert and retract drive time-bound tests |
| string interpolation | one `InterpExpr` node: a linear sequence of format primitives |
| `Json` path | `json_path` expression node |
| logical facts | truth maintenance: reference count and dependency table |
| TTL expiry | deadline in the fact; swept once per pump, before anything fires |
| no-op reassertion | slot equality check, with per-slot tolerance, at assert |
| `scope activation` | schema with `DS_RETE_SCOPE_ACTIVATION` |
| `ambient` (`scope logical ambient`) | schema with `DS_RETE_SCOPE_AMBIENT` |

*(Spec: [IRET.2.1])*

### Wiring

`ds_engine_new` creates the Rete engine (`ds_rete_engine_create`, held as `engine->rete_engine`), registers the builtins (`ds_register_builtins`) and fills the engine's `ds_rete_adapter_config_t` with the action-verb callbacks (`ds_engine_wire_rete_adapters`).

libds drives the network through these entry points:

| Operation | Entry point |
|---|---|
| create, destroy | `ds_rete_engine_create`, `ds_rete_engine_destroy` |
| load the compiled network | `ds_rete_load` |
| before-fire and after-fire hooks | `ds_rete_set_before_fire`, `ds_rete_set_after_fire` |
| assert, retract | `ds_rete_wm_assert`, `ds_rete_wm_retract` |
| run the agenda | `ds_rete_run` |
| register a builtin | `ds_register_fn`, `ds_register_fn_rt` |

*(Spec: [IRET.15.1])*

### Engine create and destroy

`ds_rete_engine_create` initialises the string-intern table, the schema registry, the agenda (an empty binary heap), the truth-maintenance dependency table, the [builtin table](agenda-and-actions.md#builtin-dispatch), the clock and the fire hooks, in that order.

The fire hooks start `NULL`. `ds_rete_engine_destroy` tears down in reverse order and frees in-flight tokens and activations, the interned strings with the intern table, schema descriptors, node graphs and expression trees. When initialisation fails part-way, every subsystem already initialised is freed and no engine is returned.

*(Spec: [IRET.18.1], Source: runtime/src/libds/rete/agenda.h)*

## Clock

### Clock functions

The Rete engine's clocks are two caller-supplied functions sharing one context pointer: `clock_fn` returns the monotonic reading and `wall_fn` the UTC wall reading, or no value.

`ds_rete_set_clock`, which takes the monotonic function and the context, and `ds_rete_set_wall_clock`, which takes the wall function, install them; each returns `ds_result_t` and refuses a `NULL` function with `DS_ERR_INVAL`. Their defaults read `clock_gettime(CLOCK_MONOTONIC)` and `clock_gettime(CLOCK_REALTIME)`; a DS engine installs functions returning its held samples. The engine calls them only at the sample points, and no other code reads the time. A `NOW` node reads the held wall sample, and a `monotonic_ns()` node the held monotonic sample, as direct field reads; the `now` and `monotonic_ns` builtins read the same samples. The [clock source](../overview/runtime-architecture.md#clock-source) is the architecture.

*(Spec: [IRET.14], [IRET.14.1], [IRET.14.2], [IRET.14.3], [IRET.18.1])*

## Compiled network

### Network atoms

The compiled network is one `AlphaNode`, `BetaNode` or `TerminalNode` atom per node, with no container message.

| Atom | Carries |
|---|---|
| `AlphaNode` | `node_id`, the `schema_name` it filters, and its alpha test descriptors (kind, slot index, op, literal or regex pattern) |
| `BetaNode` | `node_id`, `right_alpha_id`, `left_parent_id` (`0` is the working-memory root), the join-test expression trees and the negative flag |
| `TerminalNode` | `node_id`, `parent_beta_id`, `rule_name`, `bind_count`, the RHS actions as expression trees, and an optional `fire_guard` |

Nodes reference each other by `node_id`, a `uint32`, never by array position. Schema descriptors are not in these atoms: the schema atom family registers them into the Rete schema registry first. An expression tree is a protobuf message with a top-level `oneof` over expression kinds and embedded child messages. A `CallExpr` carries a numeric `BuiltinFn` `op`, which the loader stores on the CALL node; no name is interned.

*(Spec: [IRET.16], proto: alfa.proto, beta.proto, term.proto, rete_expr.proto)*

### Load

The artefact loader, `dsc/rete_loader.c`, decodes the network atoms, and `ds_rete_load_network` builds the in-memory node graph from them.

1. Decode each atom body with `protobuf-c`; a decode failure is `DS_ERR_DSC_DECODE`, before any other check of the body. A node with `node_id` 0, or with a `node_id` another node holds, is `DS_ERR_RETP_INVALID`.
2. Check that every `node_id` reference resolves before any pointer is built; the first that does not is `DS_ERR_RETP_INDEX_OOB`.
3. The schemas are already registered.
4. Build the alpha nodes, compile each regex test's pattern and wire each node into its schema's alpha-dispatch entry.
5. Build the beta nodes: join-test expression trees, the negative flag, and the left-parent and right-alpha links.
6. Build the terminal nodes and their RHS expression trees.
7. Wire the downstream links: beta children, terminal children, and beta inputs on alpha nodes.

A failing step returns its error and spends the engine, and the loader undoes nothing it applied ([Failed load](../artefacts/dsc-format.md#failed-load)). An engine loads one artefact for its life. For a program compiled with `logical: false`, the truth-maintenance table is not initialised: no table entries, withdraw scratch or overflow buffers are allocated.

*(Spec: [IRET.15.2], [IRET.16.8], [IRET.18.2], [IRET.18.2.1], [IRET.21], [IRET.23.6], [RDSC.11.1], [RDSC.11.4])*

## Values

### Value storage

A slot value is a tagged union: a kind discriminant and one payload.

| Kind | Payload | Storage |
|---|---|---|
| `Int` | 64-bit signed | inline |
| `Float` | double | inline |
| `Bool` | boolean | inline |
| `Time` | UTC nanoseconds and a zone offset | inline |
| `Null` | none | inline |
| `String`, `Bytes` | pointer and length | interned, not owned by the value |
| `FactRef` | the target's fact ID | inline |
| `Json` | UTF-8 document tree | heap-allocated and owned, or borrowed from the working-memory wrapper that owns it |
| `Unbound` | none | inline |
| `Ratio` | numerator and denominator | inline |

A fact slot carries one of the slot-value kinds; `Unbound` (a `let` slot not yet bound), `Ratio` (the exact ratio currency conversion yields and rounding consumes) and a borrowed `Json` are evaluator-only. The set is closed. Copying a `String` or `Bytes` value copies no bytes, and neither is NUL-terminated: a reader uses the length. A `FactRef` holds an ID, so a target that leaves working memory leaves no dangling pointer. An owned `Json` value belongs to the fact owning the slot, which frees it before the fact. A fact's slot values are a flat array of `ds_rete_val_t` sized from its schema.

*(Spec: [IRET.1.3], [IRET.1.5], [IRET.3.1], [IRET.3.3], [IRET.20.3])*

### String intern table

The per-engine string table holds the pinned and counted entries of [String interning](../overview/data-model.md#string-interning) in one pointer space.

| Operation | Effect |
|---|---|
| `find` | non-mutating lookup, for the no-op check |
| `acquire` | find or insert, and increment; once per `String` or `Bytes` slot at fact commit |
| `release` | decrement, and free and remove at zero; once per slot at fact retract |
| `pin` | insert saturated |

The table is open-addressed with tombstone deletion. A value equal to a pinned literal shares the literal's pointer and stays pinned. A release that would take a count below zero trips an assertion. At the first pump the engine pins `""` and `$ClockTick` and freezes the pinned set: a later pinned insert of a new string trips an assertion, and counted inserts stay legal.

*(Spec: [IRET.1.4], [IRET.1.4c], [IRET.3.2], Source: runtime/src/libds/rete/intern.h, runtime/src/libds/engine.c)*

### Computed strings

A string the engine computes and does not store in a fact slot is never interned.

An interpolated string, a `gensym`, a `Json`-to-string conversion, a cache read's value and a `where` operand live in a per-engine fire-scoped arena of chained slabs, reset at pump entry. Each copy takes its own span, and growth chains a new slab, so a live pointer never moves. A computed string emitted into a fact slot is interned counted at the emit's commit, before the reset.

*(Spec: [IRET.1.4], [IRET.1.4a])*

### Slot equality at assert

The no-op check compares an incoming fact with the existing fact of the same schema and identity key, slot by slot.

| Slot | Comparison |
|---|---|
| no tolerance | value equality; `String` by pointer |
| tolerance `T > 0` | exactly equal, or `abs(new - old) <= T`, over the stored values, a unit-typed slot's in its base unit; two equal infinities are equal |
| `Json` | structural deep equality |

When every slot compares equal, the assertion is suppressed. Fact equality is [Fact identity](../overview/runtime-architecture.md#fact-identity).

*(Spec: [IRET.3.4], [RLOW.3.7.4], [LFAC.2.5.1], [LUNI.7.4])*

## Alpha network

### Alpha node

An alpha node is one pattern's participation in the network for one schema.

It holds the schema it matches, its alpha tests, its alpha memory and its downstream beta inputs. Two rules with identical patterns and tests on one schema share one alpha node, deduplicated by the compiler: one `ds_rete_alpha_node_t` may be the right input of several beta nodes.

*(Spec: [IRET.6.1], [IRET.6.6], Source: runtime/src/libds/rete/alpha.h)*

### Alpha dispatch

Each schema has a compact integer ID, and alpha dispatch is a flat array indexed by it.

Each entry lists the alpha nodes registered for that schema. Dispatching an asserted or retracted fact is one index and an iteration over that schema's alpha nodes. The schema IDs and the per-schema arrays are [Schema registry](../overview/data-model.md#schema-registry).

*(Spec: [IRET.1.7])*

### Alpha tests

On fact assert, the engine evaluates the alpha tests of every alpha node registered for the fact's schema.

Tests short-circuit: the first test answering `false` skips the fact for that node. A fact passing every test is inserted into the alpha memory, and the node's beta inputs are notified. Two tests can fault instead of answering: one whose `slot_index` names no slot of the schema, and a regex test whose subject is not a `String`. The engine does not short-circuit on either: the fact is rejected if another test of the node answers `false`, and the fault is raised only if none does.

A regex test's pattern is compiled once, at load, and stored in the alpha node; matching calls RE2 through `ds_re2_match`.

*(Spec: [IRET.6.2], [IRET.6.3], [IRET.6.4], [IRET.23.1])*

### Alpha memory

The alpha memory is a hash set keyed by fact ID.

Insert and remove are O(1) on average, and the set iterates for a join against a new right fact.

*(Spec: [IRET.6.5])*

## Beta network

### Token

A token is one partial match: the facts bound so far, one per LHS pattern position, in pattern order.

| Field | Holds |
|---|---|
| `fact_count` | the number of bound pattern positions |
| `facts` | the bound facts, indexed by pattern position |
| `creation_timetag` | the completion stamp the agenda orders by |
| `hash` | the cached hash of the fact-ID tuple |
| `next` | the intrusive link into a beta memory |

A token at a node with `n` patterns holds `n` facts: `facts[n-1]` is the newest, and the rest carry forward from the left parent. A binding is read directly, as `token->facts[i]->slots[j]`. The hash is an XOR-rotation over the fact IDs, a pre-filter for duplicate detection and refraction lookup and not a key: a collision is resolved by `tokens_equal` for duplicates and by the fact-ID tuple for refraction. Adding a token to a beta memory allocates nothing.

*(Spec: [IRET.1.6], [IRET.7.1], [IRET.7.2], [IRET.7.3])*

### Beta node

A beta node joins tokens arriving on its left with facts arriving on its right, and passes the matches to its children.

Its left parent is another beta node, or none, which makes working memory the left source. Its right input is an alpha node. It holds its join tests and a negative flag. Only the left side is stored, as the left memory of tokens; the right side is the alpha node's memory. Beta children and terminal children are kept in separate lists, and a node may feed both.

*(Spec: [IRET.7.4], Source: runtime/src/libds/rete/beta.h)*

### Join tests

A join test is a predicate over the token and the candidate right fact.

Join tests implement `where` predicates and the `within` and `then … within` constraints. They are evaluated in any order and combine as an absorbing `and`: a `false` rejects the pair whatever another test raises, and that fault reaches no surface. When no test answers `false` and several fault, the pair yields the one fault the absorbing `and` selects. A pair passes only if every test answers `true`.

*(Spec: [IRET.7.5], [IRET.7.6])*

### Equality anchor under linear_scan false

In a program compiled with `linear_scan: false`, every beta node of a positive pattern has an equality join test `BINOP(EQ, VAR(left, i, j), VAR(right, k))`, unless both schemas have empty keys, and the loader extracts it as the node's anchor.

The loader stores `(i, j, k)` in the node's `lmem_idx_*` and `ralpha_idx_*` fields and compiles a typed comparator over `t->facts[i]->slots[j]` and `f->slots[k]` that bypasses the expression evaluator. The comparator probes the index; the remaining join tests run as usual. A test is a legal anchor only when it is decided: both slots non-nullable and the comparison unable to raise by their declared types. The loader never anchors on a test that could answer `null` or raise.

*(Spec: [IRET.7.5.1])*

### Join algorithm

Each beta node handles four events.

| Event | Action |
|---|---|
| right activation (a fact added to the alpha memory) | for each left token, build the extended token and evaluate the join tests; propagate each pass to every child |
| left activation (a token from the left parent) | for each fact in the right alpha memory, build the extended token and evaluate the join tests; propagate each pass |
| right retraction (a fact removed from the alpha memory) | send a retraction downstream for each left token whose fact at that pattern position is the retracted fact; no join test is evaluated |
| left retraction (a token removed from the left parent) | send a retraction downstream for each extended token built from it |

A token retraction propagates depth-first to the terminals. At a terminal, it removes the activation from the agenda if it has not fired, and ends the activation, withdrawing the justifications its firing recorded.

*(Spec: [IRET.7.7], [IRET.7.8])*

### NOT node

A NOT node is a beta node with the negative flag: a token passes only when the join finds no right fact.

| Event | Action |
|---|---|
| left activation | count the right facts that join; at zero, propagate the token unchanged; otherwise record the blockers |
| right activation | for each left token the new fact joins, record it as a blocker; a token that had none retracts its downstream token |
| right retraction | for each token the fact blocks, remove the blocker, with no join test evaluated; a token left with none propagates downstream |

A token's block count is the number of right facts its left-token join index records against it, keyed by token identity; the index is a flat hash map, and there is no separate count structure. A passing token carries only its left facts: `fact_count` is unchanged downstream.

*(Spec: [IRET.7.9], [IRET.23.3])*

### Sequence chains

A `then … within` sequence compiles to a linear, left-associative chain of join nodes.

```text
alpha(A) → beta_join_1 → alpha(B) → beta_join_2(test: ts_B - ts_A < T) → terminal
```

Each further `then C within T2` appends one join node, whose `within` is a join test on the preceding pair. A `latest` anchor adds a NOT node after the sequence's last join. It blocks the match when a fact `f` of the anchor's schema has `ts_a < f.ts < ts_b` and `ts_b − f.ts < T`, and none of the anchor's and the followers' `where`s answers `false` with `f` in the anchor's place. Only the first follower's window and ordering involve `f`.

*(Spec: [IRET.7.10])*

## Terminals

### Terminal node

A terminal node turns a fully matched token into an activation.

It holds the rule's interned name, its terminal ordinal and its RHS action list. On a token it creates an activation and inserts it into the agenda; on the token's retraction it removes it. The terminal ordinal is the rule's zero-based index in the artefact's terminal sequence, read directly by the [comparator](../overview/runtime-architecture.md#agenda-and-conflict-resolver). A terminal holds the refraction table and the edge-once set of [Refraction](agenda-and-actions.md#refraction).

*(Spec: [IRET.8], [IRET.8.1], [IRET.8.2], Source: runtime/src/libds/rete/terminal.h)*

### Justifications

A firing records its activation as a justification for each fact its logical emits assert, and for no other.

An explicit `emit` records none. When a supporting token is retracted, `terminal_left_retract` copies the truth-maintenance IDs to a stack array, withdraws them from the truth-maintenance table and retracts each fact, which may cascade. Under `logical: false` it only removes the terminal token from the token pool.

*(Spec: [IRET.8.3], [IRET.8.4])*

## Expressions

### Expression nodes

An expression is a tree of tagged C structs, evaluated by a recursive walk over an evaluation context.

Each node is of one kind:

| Kind | Node |
|---|---|
| literal | an `Int`, `Float`, `String` or `Bool` constant, or `null` |
| var | a slot reference by pattern position and slot index |
| binop | binary arithmetic, comparison, logical or bitwise |
| unop | unary `not`, bitwise not or negate |
| call | a builtin invocation: an op and its arguments |
| interp | an interpolated string: literal text, values under their specs and time fields |
| now | a clock-source read |
| json-path | traversal of a `Json` value by path |
| if | a conditional |
| bind, bind-ref | a `let` binding and a reference to it |
| coalesce | `left ?? right`, evaluating `left` once |
| is-test | `x is <subject>`, a total tag test |
| entry-stamp | the entry stamp of the fact bound at a pattern position |

Name resolution happens at lowering: a var names a position, and evaluation performs no lookup. A pure `let` folds at lowering; a sync-impure one leaves a bind and bind-ref pair.

*(Spec: [IRET.1.10], [IRET.9.1])*

### Evaluation context

An evaluation reads only its context.

| Field | Holds |
|---|---|
| `token` | the current partial match |
| `right_fact` | the candidate right fact, during a join test |
| `bind_frame` | the `let` bindings in scope |
| `bind_count` | the number bound |
| `engine` | builtin dispatch and the clock |

`right_fact` is absent when a RHS action is evaluated. A var whose `pattern_index` is below `token->fact_count` reads `token->facts[i]->slots[j]`; `DS_RETE_VAR_RIGHT_FACT` reads `ctx->right_fact->slots[j]`. The bind frame is stack-allocated and zeroed at RHS entry: a bind evaluates its expression and stores it at `bind_frame[bind_index]`, and a bind-ref reads it back.

*(Spec: [IRET.9.2], [IRET.9.3], [IRET.9.4])*

### Evaluation order

`and` and `or` evaluate their operands in any order and stop once the result is decided, with the absorbing result.

A faulting operand (a trap, a `TypeError` or an `EngineError`) does not end the evaluation. The evaluator holds the fault and evaluates the rest. A `false` (`true` for `or`) among the rest decides the result and discards every held fault. When nothing decides, the expression yields the one fault the absorbing order selects. A discarded or unselected fault reaches no surface.

*(Spec: [IRET.9.5])*

### Ill-typed operations

Arithmetic on wrong types, and a format spec its value cannot render, yield no value and raise.

| Condition | Fault |
|---|---|
| an operand is `null` | `TypeError`; the activation is abandoned |
| no operand is `null`, and one derives from a `Json` slot | `TypeError`; the activation is abandoned |
| otherwise | `EngineError`; the tier halts |

The `null` test comes first. `Json` provenance starts at every read of a `Json` slot, is transitive and rule-local, flows through a `let`, and clears at a `::` cast and at `??`. The compiler computes it and lowers it onto the node as `Expr.json_tainted`; the evaluator reads it. An absent flag is clean. An interpolation segment carries the flag like any node. An absorbed fault of either kind abandons nothing and halts nothing. An unresolved `Json` path, and a path resolving to JSON `null`, read as `null` and raise nothing.

*(Spec: [IRET.9.6], proto: rete_expr.proto)*

### Operator table

Each DS operator is one binop or unop kind.

| DS | Node |
|---|---|
| `+` `-` `*` `/` | BINOP, ARITH |
| `//` `%` | BINOP, INT_ARITH |
| `==` `!=` `<` `>` `<=` `>=` | BINOP, CMP |
| `and` `or` | BINOP, LOGICAL |
| `&` `\|` `^` `<<` `>>` | BINOP, BITWISE |
| `~` | UNOP, BIT_NOT |
| `not` | UNOP, LOGICAL_NOT |
| `-x` | UNOP, NEGATE |

In a program compiled with `linear_scan: false`, the pump path never reaches a `DS_RETE_EXPR_JSON_PATH` node, or a `DS_RETE_EXPR_INTERP` node producing a novel string.

*(Spec: [IRET.9.7], [IRET.9.8])*

## Working memory operations

### Assert

`ds_rete_wm_assert` checks the fact's identity key, then inserts the fact and propagates it.

1. Find an existing fact of the schema whose KEY slots match exactly. With no KEY slot, any fact of the schema matches; with every slot KEY, only an identical tuple does.
2. If one is found and its MUTABLE slots compare equal under [slot equality at assert](#slot-equality-at-assert), suppress the assertion and return the existing fact.
3. If one is found and a MUTABLE slot differs, retract it, then continue.
4. Allocate a fact with a fresh monotonic ID and set `assert_ns` to the held monotonic sample.
5. Under `ttl` scope, set `deadline_ns = assert_ns + default_ttl_ns`.
6. Under `logical` scope, set `justif_count = 0`.
7. For each alpha node of the schema, evaluate its tests; on a pass, insert the fact into the alpha memory and activate each downstream beta input.
8. Emit `DS_EV_FACT_ASSERT`.

The fact's fields are [Rete fact](../overview/data-model.md#rete-fact).

*(Spec: [IRET.19.1])*

### Retract

`ds_rete_wm_retract` removes a fact from the network.

1. Remove the fact from each alpha memory holding it, and right-retract each downstream beta input.
2. Token retractions propagate depth-first to the terminals, which remove their pending activations.
3. A `logical` fact's `justif_count` is kept by the truth-maintenance path. A plain retract of a `logical` fact removes it unconditionally.
4. Emit `DS_EV_FACT_RETRACT`.
5. Free the fact.

*(Spec: [IRET.19.2])*

### TTL sweep and tick

The [TTL expiry](../overview/runtime-architecture.md#ttl-expiry) sweep iterates every live fact with `deadline_ns > 0` and calls `ds_rete_wm_retract` on each with `now_ns >= deadline_ns`.

A retraction cascades and may enqueue activations that fire on the fact's absence. The engine never ticks between two firings of one pump, and `ds_rete_run` does not tick.

The [clock tick](../overview/runtime-architecture.md#clock-tick) is a fact of the slotless synthetic schema `$ClockTick`. libds asserts it into the network's own fact store, not the working-memory table: it is not counted, not delivered to the fact callbacks, and not on the stream as a fact event. A `then … within` test compares two facts' `ts` values and is not re-evaluated by the tick.

A token that joins the tick is formed again on every tick, with the new tick's fact. While its time-dependent test stays true those tokens are one match: the edge-once set holds its [refraction](agenda-and-actions.md#refraction), keyed by the matched fact, and its [justifications](truth-maintenance.md#withdrawal) carry over. A test that goes false ends the match, and one that goes true again makes a new one.

*(Spec: [IRET.19.3], [IRET.19.4], [IRET.19.5], [IRET.11.3.5], [IRET.12.2])*

## Memory

### Ownership

The network follows libds's single-ownership discipline.

| Object | Owner | Lifetime |
|---|---|---|
| `ds_rete_engine_t` | the caller of `ds_rete_engine_create` | until `ds_rete_engine_destroy` |
| `ds_rete_schema_t` and slot descriptors | the engine | the engine's |
| alpha, beta and terminal node graphs | the engine | from load until destroy |
| `ds_rete_expr_t` trees | the engine | from load until destroy; read-only after the load |
| interned strings | the intern table | per [String intern table](#string-intern-table) |
| `ds_rete_fact_t` | working memory | from `ds_rete_wm_assert` until `ds_rete_wm_retract` |
| `ds_rete_token_t` | the beta node's left memory | from the join until retraction frees it |
| `ds_rete_activation_t` | the agenda | from the terminal's activation until its match ends |

A retracted token's downstream extended tokens are freed first, depth-first and post-order. Expression nodes are allocated individually at load. A builtin receiving a `Json` argument borrows it.

*(Spec: [IRET.20], [IRET.20.1], [IRET.20.2], [IRET.20.3])*

## Open-addressing map

### oa

`oa` is the open-addressing hash map behind the network's and working memory's hash tables.

Two tables are not `oa` tables: the [intern table](#string-intern-table), whose pinned and counted entries share one pointer space and delete by tombstone, and each terminal's [refraction table](agenda-and-actions.md#refraction), which a generation stamp empties in O(1). A probe array of `u32` slots indexes dense, packed key and value arrays. Each dense entry has a cached 32-bit hash, and a reverse map from dense index to slot. Capacity is zero or a power of two, at most 2³¹, and the live count stays strictly below it. Each table is configured with its key size, value size, growth threshold (default 70 %), hash, equality and value-destructor callbacks, a callback context, and a lock flag that forbids growth.

*(Spec: [IRET.28], [IRET.28.1], [IRET.28.3], [IRET.28.3.1], Source: runtime/src/libds/oa.h)*

### oa tables

The engine's `oa` tables, by the number code comments cite.

| # | Table (field, file) | Key | Hash and equality | Value |
|---|---|---|---|---|
| 1 | `table` (`ds_wm_state_t`, `wm.c`) | `rete_fact*` | pointer | `ds_fact_t*`, owning |
| 3 | `id_map` (`ds_rete_schema_t`, `wm_rete.c`) | `ds_rete_val_t*`, the fact's identity-key slots | the slots' content | `rete_fact*` |
| 4 | `wm_map` (`ds_rete_engine_t`, `wm_rete.c`) | `u32` fact ID | integer | `rete_fact*` |
| 5 | `ridx_map` (beta node, `beta.c`) | `u32` fact ID | integer | `oa_list<token*>` |
| 6 | `lmem_idx_map` (beta node, `beta.c`) | `ds_rete_val_t` | `lmem_idx_oa_hash`, `lmem_idx_oa_eq` | `oa_list<token*>` |
| 7 | `ralpha_idx_map` (beta node, `beta.c`) | `ds_rete_val_t` | as #6 | `oa_list<fact*>` |
| 8 | `ltok_idx_map` (beta node, `beta.c`) | `token*` | pointer | `oa_list<fact*>` |
| 10 | `lmem_map` (beta node, `beta.c`) | `token*` | `token->hash`, `tokens_equal` | `token*` |
| 11 | `map` (truth-maintenance table, `tms.c`) | `i64` timetag | integer | `ds_tms_just_t` |
| 12 | `memory.map` (alpha node, `alpha.c`) | `u32` fact ID | integer | `rete_fact*` |
| 13 | `act_map` (terminal, `terminal.c`) | `token*` | `token->hash`, `tokens_equal` | `activation*` |
| 14 | `by_id` (`ds_wm_state_t`, `wm.c`) | `u64` fact ID | `wm_id_hash`, `wm_id_eq` | `ds_fact_t*` |
| 15 | `oneshot` (terminal, `terminal.c`), the edge-once set | `u32` fact ID | `oneshot_oa_hash`, `oneshot_oa_eq` | none |
| 16 | `map` (cache, `cache.c`) | `char*`, owned | `cache_hash`, `cache_eq` | `ds_cache_entry_t` |
| 17 | `zones` (zone index, `wm_rete.c`) | `tz_zone_key_t` | the zone key | `tz_node_t*`, a tree's root |

Tables #1, #4 and #12 are iterated with `ds_oa_val_at`, #4 and #12 under [oa determinism](#oa-determinism); #12 is iterated on the join scan. Tables #5 to #8 are the multimaps of [oa_list](#oa_list). #10 keeps its doubly linked `left_head` list beside it, for ordered traversal. #13's discard path finds an activation by `act->token` and checks that the stored value is that activation; the activation's doubly linked list stays beside it. A clone and a replay build further `oa` tables that live only for that operation.

*(Spec: [IRET.28.2], [IRET.28.13])*

### oa invariant

After every public operation, an `oa` table satisfies seven invariants.

| | Invariant |
|---|---|
| RI-1 | `cap` is 0 or a power of two |
| RI-2 | `len < cap` when `cap > 0`, and `len ≤ cap · load_pct / 100` except inside `ds_oa_put` before a grow |
| RI-3 | each slot is empty (0) or holds a dense index plus one, in `[1, len]` |
| RI-4 | `slots` and `dslot` are mutual inverses over the live entries |
| RI-5 | every entry is reachable by probing from its home slot without crossing an empty slot |
| RI-6 | no two entries have equal keys |
| RI-7 | each `dhash[d]` is the low 32 bits of the mixed hash of its key |

`ds_oa_check`, compiled under `DS_DEBUG`, asserts all seven and that `cap` is 0 or a power of two with `len < cap`. The engine composes it with its own invariants: `ridx` and `ltok` are mutual inverses, `lmem_map` has `left_count` entries, and every `act_map` value is a live activation on the activation list.

*(Spec: [IRET.28.4], [IRET.28.15])*

### oa hashing

A key's slot is its mixed hash masked by `cap - 1`.

The callback returns a `u64`, and the table applies `oa_mix64` to it. The callback is a pure function of the logical key; for a handle key it may depend on pointer values, which move only the probe location. The stored `dhash` skips most equality calls and rehashes on growth without calling the hash.

*(Spec: [IRET.28.5])*

### oa operations

`oa` operations are amortised O(1); iteration is O(len).

| Operation | Behaviour |
|---|---|
| `ds_oa_init` | records the parameters, allocates nothing, cannot fail; `load_pct` 0 selects 70 |
| `ds_oa_reserve` | sets `cap` to the smallest power of two holding `n` entries at the load threshold, rehashing |
| `ds_oa_get` | returns a pointer into the table's value storage, or `NULL`; never fails |
| `ds_oa_put` | finds or appends the key; a new value is zeroed; grows first when needed |
| `ds_oa_del` | removes by backward shift and swaps the last dense entry into the hole; never fails, never shrinks |
| `ds_oa_clear` | runs the value destructor on every value and keeps the capacity and arrays |
| `ds_oa_free` | clears, then frees the arrays |

Lookup is linear probing from the mixed hash: an empty slot ends the search, and equality runs only on a matching cached hash. Growth doubles `cap`, or sets the initial capacity, moves the dense arrays by `memcpy` and re-seats the slots from the cached hashes, with no hash, equality or destructor call. A backward-shift delete clears the freed slot before scanning, and updates each moved entry's `dslot`. A pointer from `ds_oa_get` is valid until the next `put`, `del`, `reserve`, `clear` or `free` on the table. Iteration walks the dense arrays by index; deleting while iterating runs from high index to low. Values are relocatable by `memcpy`.

On failure, a table stays a valid map: `ds_oa_put` and `ds_oa_reserve` return `DS_ERR_OOM` with the table unchanged.

*(Spec: [IRET.28.6], [IRET.28.6.1], [IRET.28.6.2], [IRET.28.6.3], [IRET.28.6.4], [IRET.28.6.5], [IRET.28.6.6], [IRET.28.12], [IRET.28.14.1])*

### oa value lifecycle

The value destructor runs when an entry leaves the table, and never on growth.

It runs on `ds_oa_del`, before the swap overwrites the entry, on `ds_oa_clear` and on `ds_oa_free`. Growth and `ds_oa_reserve` move values by `memcpy`. A plain pointer, `u32` or POD value has no destructor.

*(Spec: [IRET.28.7])*

### oa_list

`oa_list` is the value of the multimap tables (`ridx`, `lmem_idx`, `ralpha_idx`, `ltok_idx`): a key's set of element pointers.

It holds `OA_LIST_INLINE` (8) pointers inline, equal to `DS_RIDX_INLINE`, and overflows to an owned heap array. Element order within a list is not stable. `ds_oa_list_free` is every multimap table's value destructor.

*(Spec: [IRET.28.8], [IRET.28.14.3])*

### oa determinism

An `oa` table's iteration order is its dense-vector order: append on insert, last into the hole on delete.

It is a function of the operation sequence alone, independent of capacity, pointer values and platform. The mixed hash and the mask move only probe locations. No timetag is derived from the order in which these tables are traversed.

*(Spec: [IRET.28.10], [IRET.28.10.1], [IRET.28.10.3])*

### oa memory

An `oa` table of capacity `cap` occupies `4·cap` bytes of slots and `(ksize + vsize + 8)·cap` bytes of dense arrays.

The 8 bytes are the cached hash and the reverse slot index.

*(Spec: [IRET.28.14.2])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Lowering

## Compile contract

### Engine instance

A tier instance's rules and schemas lower into one engine.

Cross-tier boundaries are bridged by the integrator, not by module boundaries inside the engine.

*(Spec: [RLOW.1.1])*

### Strict validation

Compile-time validation is strict, and nothing is validated later.

Every name resolves, every form is enabled by the program's settings, every typed slot access matches the slot's declared type, and every structural invariant holds. There is no lazy-validation path: the service set is fixed at compile time from the imported libraries and carried in the `.dsc`.

*(Spec: [RLOW.1.4], [RLOW.13.12])*

### Whole compile

A compile produces either a complete, valid artefact, or no artefact and its errors.

The compiler pins every diagnostic to a location in the source it compiles and never writes a partial artefact. A warning does not stop a compile.

*(Spec: [RLOW.2.2])*

### Unlowerable rule

A rule the compiler cannot lower refuses the compile with `DS_VALIDATE_RULE_NOT_LOWERED`.

The compiler emits one diagnostic per such rule, at the rule's span, naming the rule and the construct it could not lower. The code is the same for every construct. No artefact omits a rule its source declares.

*(Spec: [RLOW.1.6])*

### Source locations

The compiler records the source location of each node it attributes to a pattern or rule as a [`LineSpan`](../artefacts/dsc-format.md#linespan) atom.

A `ComputationError` names the node that raised it.

*(Spec: [RLOW.1.5], [RLOW.13.13])*

### Incremental compilation

A compiler may recompile only the rules that changed, provided it writes the artefact a full compile of the same source writes, with the same `dsc_sha256`.

A runtime never compiles; it loads the artefact it is given.

*(Spec: [RLOW.14.4])*

## Synthetic names

### Synthetic name

A synthetic name is a [synthetic identifier](../overview/runtime-architecture.md#synthetic-identifiers) the compiler uses.

The compiler uses a synthetic name for:
- the binding of a pattern written without one, which reaches a display name;
- every rule it synthesises, an `after` follow-up and a call continuation's sibling among them;
- engine-internal facts the runtime asserts directly, `$ClockTick` among them.

Series absorption and the clock tick are engine steps, not rules.

*(Spec: [RLOW.1.2], [RLOW.9.1.2], [RLOW.9.1.4], [RLOW.9.1.5], [RLOW.9.1.6], [RLOW.13.4])*

### Mangling

Synthetic names come from a deterministic, source-derived mangling scheme.

The same source compiles to the same set of synthetic names on every compile. The scheme is the implementation's, except where a clause fixes a name's form.

*(Spec: [RLOW.9.2.1])*

### Synthetic names in the artefact

A synthetic name is written unchanged, `$` included, wherever the artefact carries a name.

The compiler writes synthetic names into the schema-name, rule-name and fact-name positions of the atom set. Slot reads are `VarExpr` positions, so no synthetic binding name appears in an expression.

*(Spec: [RLOW.9.3.1], [RLOW.9.3.2])*

## Schemas

### Schema group

A schema lowers to its schema group: one lifecycle atom, `SchemaTtl` or `SchemaLogical`, then one `Slot` atom per declared slot in declaration order, then `SchemaSource` and `SchemaDef`.

Each `Slot` atom carries the slot's name and type. The runtime registers the schema by name, and the alpha nodes that match on it reference it by that name.

`SchemaDef` carries the schema's protobuf definition as `.proto` text. That definition types the `fact` bytes of a `FactAssert` body wherever one is encoded: in the recorded event trace and in any integrator transport that carries facts.

The schema's metadata has no atom of its own. The lifecycle atom carries the lifecycle and, for a `ttl` schema, the default TTL. Each `Slot` atom carries the slot's identity role on a `logical` schema, its tolerance, and its `sampled` and `retained` markers.

*(Spec: [RLOW.3.2.1], [RLOW.3.3.1], [RLOW.3.3.2], [RLOW.3.3.3], proto: slot.proto, proto: fact_assert.proto)*

### Field numbers

The compiler numbers the fields of a schema's generated `.proto` from 1, in slot declaration order.

The numbers are the same in every compile, and no field number is explicitly reserved.

*(Spec: [RLOW.14.5])*

### Lifecycle

The lifecycle does not change a schema's slot layout.

Each slot keeps its position and type under either lifecycle. The engine's fact-assert path reads the lifecycle from the lifecycle atom. A `logical` schema's `Slot` atoms also carry each slot's identity role and tolerance.

*(Spec: [RLOW.3.4.1])*

### `sampled` and `retained`

`sampled` and `retained` are compile-time slot markers.

The compiler records each in the field of the same name in the slot's `Slot` atom. The slot otherwise lowers as any other slot does.

*(Spec: [RLOW.3.5.1], [RLOW.3.5.2], proto: slot.proto)*

### Identity key

A `logical` schema's identity key is the set of slots marked `key`.

Every other slot is marked `mutable`, and there is no default. The compiler records each slot's role in the `identity_role` field of its `Slot` atom.

*(Spec: [RLOW.3.6.1], proto: slot.proto)*

### Tolerance

`tolerance T` records a per-slot epsilon in the slot's `Slot` atom; the slot descriptor is unchanged.

The compiler writes the epsilon in the slot's base unit, as a `Float`. For a slot whose declared unit converts to its base unit as `y = a*x + b`, the epsilon is `|a| * T`, where `T` is the literal's value, and `b` is dropped: `tolerance 1` on a `fahrenheit` slot is 5/9 kelvin. A slot declared in its base unit, and an `Int` or `Float` slot, has `a = 1`.

The engine compares slots by their `Slot` atoms at fact assert ([Slot equality at assert](rete-network.md#slot-equality-at-assert)). `tolerance 0` is exact equality: the compiler emits nothing further, and the slot takes the exact-equality path.

The compiler refuses a `tolerance` the language does not admit before lowering. That includes a `tolerance` on a slot that is not `mutable`, on a slot of a schema that is not `logical`, and on any slot other than an `Int` slot, a `Float` slot, or a slot typed by a base or tier-1 unit symbol, and so on a `Json` slot.

*(Spec: [RLOW.3.7.1], [RLOW.3.7.2], [RLOW.3.7.7], [RLOW.3.7.8], [LUNI.7.4], [LGRA.5.9.4])*

## Rules

### Rule

A rule lowers to a chain of Rete nodes ending in one terminal.

Each pattern, in source order, lowers to an `AlphaNode` over its schema and a `BetaNode` that joins it to the chain above. Every pattern with the same schema and tests shares one alpha node. A negated pattern's beta is negative. The pattern's `where` becomes the alpha's tests and the beta's join test ([`where`](#where)). The rule lowers to one `TerminalNode` under the chain's last beta. The terminal carries the RHS actions and, where the rule has one, a fire guard. The node kinds are those of [The Rete network](rete-network.md), and their atoms those of [Rule network](../artefacts/dsc-format.md#rule-network).

| Construct | Lowers to |
|---|---|
| schema | schema group |
| rule | alpha and beta chain, one terminal |
| pattern, `where` | alpha tests, beta join tests |
| expression | `Expr` tree |
| action | terminal action |
| series | backend atoms |

*(Spec: [RLOW.4.2.1], [RLOW.13.1])*

### Terminal order

The compiler emits terminals in canonical source order, which is the [terminal ordinal](../overview/runtime-architecture.md#agenda-and-conflict-resolver)'s order.

The `TerminalNode` carries no ordering value, and nothing on a terminal weights it ([Terminal node](rete-network.md#terminal-node)).

A synthesised terminal, an `after` follow-up or a call continuation's sibling, follows the terminal of the rule that induced it and precedes the next author rule's terminal, in this order:
1. the inducing rule's terminal;
2. the follow-up of each of its `after` clauses, in source order;
3. the sibling of each of its `call` continuations, in source order.

Each synthesised terminal is followed at once by the terminals it induces in turn, ordered the same way. The emitted sequence is a depth-first walk: each author rule, then everything it induced, then the next author rule.

The terminals of the oracle rules the compiler synthesises for tests follow every other terminal in the artefact, whichever module's test each serves, in ascending `test_id` and then ascending assertion position. Every other rule has the same ordinal whether or not the artefact carries tests.

*(Spec: [RLOW.1.3], [RLOW.13.2], [RLOW.13.3], [RLOW.14.3], [RLOW.14.6], [RLOW.14.7], [RTIM.14.13])*

### Binding scope

A read of a pattern binding's slot lowers to a `VarExpr`.

In the `where` of the binding's own pattern, which is that pattern's join test, the read is of the candidate fact. Everywhere else it is of the fact at the binding's position in the token. Only positive patterns hold a token position, so a negated pattern's binding is read only in its own `where`. A slot the rule never reads lowers to nothing.

*(Spec: [RLOW.4.4.1])*

### `let`

A `let`'s right-hand side is pure or sync-impure, and its tier decides how it lowers.

| Tier | Lowering |
|---|---|
| pure | the right-hand side, with earlier `let`s already substituted, is substituted at every use and lowered as an expression; no atom, node or bind slot |
| sync-impure | an `ACTION_CALL` whose expression is a `bind` carrying the `let`'s bind index and right-hand side, emitted ahead of the rule's other actions in source order; every use lowers to a `bind_ref` of that index |

A pure expression used at N sites is evaluated N times. The terminal's `bind_count` is the number of sync-impure `let`s, and each use of one reads one evaluation per firing. The clock functions read the pump's held samples, which do not change within a pump.

The compiler type-checks a rule before it inlines any `let`. A type error at a use is reported at the use, and an error in the right-hand side at the `let`.

*(Spec: [RLOW.4.5.1], [RLOW.4.5.2.1], [RLOW.4.5.3.1], [RLOW.4.5.5.1], proto: rete_expr.proto, proto: term.proto)*

### Rule `cooldown`

`cooldown T` in a rule header lowers to a `RuleCooldown` atom carrying `(rule_name, window_ns)` and a rate gate in the terminal's `fire_guard`.

The gate is a call of `FN_RATE_ALLOW` whose arguments are, in order: the rule's name; the activation key's values in the key's order, each a `VarExpr` read of its pattern's fact; the window in nanoseconds. The compiler emits the gate only for a rule carrying `cooldown`. Where the fire guard also holds a condition, the guard is their conjunction, the condition left and the gate right. The runtime evaluates the gate once per firing, and only once the condition holds. `cooldown` does not change how the clock re-drives the rule.

The activation key is what the rule's `by:` modifier names, or, without one, the composition of the bound facts' contributing slots. Each key has its own state, `(rule_name, activation_key) → last_fire_ns`.

Two keys are the same key only if they have the same length and, position by position, values of the same representation that are equal. The representation is the value's tag, not its declared type, so `1`, `"1"` and `true` are three keys, and a `Time` and an `Int` holding the same count are one key. Equality is `==` for a scalar, so `0.0` and `-0.0` are one key. For `Json` it is deep structural equality, and `null` equals only `null`. The comparison is exact and whole: nothing is rounded, truncated or compared by prefix, and a key has no length limit. A runtime stores keys as it chooses, provided the storage preserves this identity.

The gate's evaluation is the [fire guard](agenda-and-actions.md#fire-guard)'s. A key with no recorded firing is allowed. Every instant, zero included, is a valid `last_fire_ns`, and `mono_ns` is the pump's monotonic sample.

*(Spec: [RLOW.4.6.1], [RLOW.4.6.2.1], [RLOW.4.6.2.2], [RLOW.4.6.2.3])*

### Per-call `cooldown`

Exactly one of `cooldown: <dur>` or `nocooldown` is present on a `call`.

`cooldown: <DUR>` lowers to a rate-allow gate around the call site alone: an `IF` over `FN_RATE_ALLOW`, inline at the call's `ACTION_CALL`. The gate's arguments are the call site's tracker name `<rule>#call<N>`, the call's key, and the window in nanoseconds. `<N>` is the 0-based index of the call action within the rule, counted only for calls with a window above zero: a `nocooldown` call, and one with `cooldown: 0_s`, get no gate and do not advance it. The gate carries its own window, so a call site has no rule-metadata atoms, and `<rule>#call<N>` names nothing but the tracker. Two calls in one rule have independent trackers, and the gate does not apply to the rule's other actions. `#` is not legal in a DS `NAME`, so a tracker name never equals an author rule name.

`nocooldown` lowers to the bare `ACTION_CALL` with no gate, and the call fires every time its rule fires.

A rule carrying both a rule-level `cooldown` and a per-call `cooldown:` is refused with `DS_VALIDATE_CALL_COOL_INSIDE_RULE_COOL`.

*(Spec: [RLOW.4.6.6.1], [RLOW.4.6.6.2], [RLOW.4.6.6.5], [RLOW.4.6.6.6], [RLOW.7.3.5])*

## Patterns

### Bare pattern

A pattern `<Schema>` or `<Schema> <var>` with no `where` compiles to an `AlphaNode` over `<Schema>` with no tests and a `BetaNode` with no join test.

A read of its binding is a `VarExpr`.

*(Spec: [RLOW.5.1])*

### `where`

A `where` clause compiles to a beta-node join test, a boolean expression tree over the pattern's bound slots.

The token passes only when the expression evaluates true.

A conjunct is decided when every slot it reads is non-nullable and the declared types of its operands, read without narrowing, show it cannot raise. Only a decided conjunct is compiled to an alpha test, and only a decided conjunct is probed by the loader as the join's index key. A decided conjunct answers only `true` or `false`, and a `false` decides the `where` wherever it is evaluated. A conjunct that can answer `null` or raise stays in the join test.

*(Spec: [RLOW.5.5])*

### Alpha tests

A decided conjunct of a `where`'s top-level `and` chain compiles to an alpha test on a slot when it compares that slot of the pattern's own fact with a non-`null` literal.

| Conjunct | Alpha test |
|---|---|
| `==`, either operand order | `ALPHA_TEST_EQ` |
| `!=`, `<`, `>`, `<=`, `>=`, either operand order | `ALPHA_TEST_CMP` with the operator |
| `s.x ~ /p/f` | `ALPHA_TEST_REGEX` |

Under `linear_scan: false`, a regex conjunct compiles to an alpha test only when its slot declares a `capacity`. The test's `pattern` is `p` when `f` is empty, and otherwise RE2's scoped flag group `(?f:p)` with `f`'s letters. An alpha test carries no flags field, and the group does not capture. The compiler validates the wrapped pattern, and a conjunct whose wrapped pattern RE2 refuses stays in the join test. The regex is compiled at load time.

A `!~` conjunct, and every other conjunct, stays in the join test.

*(Spec: [RLOW.5.2.1], [RLOW.5.2.2], [RLOW.5.2.3], proto: alfa.proto)*

### `no`

A negated pattern compiles to a negative beta node over the pattern's alpha node, with the same alpha and join tests as the positive form.

The token passes only when no matching fact exists.

*(Spec: [RLOW.5.3])*

### `within`

`within <dur>` on a bare pattern compiles to the pattern's alpha node and a join test comparing the fact's age with the duration in nanoseconds.

The fact's age is the monotonic clock's sample minus the fact's entry stamp. The test is re-evaluated as the `$ClockTick` fact advances. Every relative-time test the compiler generates reads `monotonic_ns()`, never `now()`.

*(Spec: [RLOW.5.4], [RLOW.5.4.1])*

### `then` sequence

`A then B within T` compiles to `A`'s alpha node joined to `B`'s alpha node through a beta node whose join test is `B.ts > A.ts and B.ts - A.ts < T`.

Each further `then` adds one beta join, left-associatively, whose test pins the new step against the step immediately before it. Each `within` binds to the immediately preceding pair, and there is no parenthesisation. Every ordering predicate is strict: `>`, never `>=`.

On a one-line sequence a trailing `where` is the last step's. It lowers into that step's join test after the step's ordering and window predicates, reads every binding of the sequence, and adds no node. A sequence binds every named variable of every pattern in it. Each is in scope in every later step's `where`, the trailing one included, and on the RHS.

*(Spec: [RLOW.5.6], [RLOW.5.6.1], [RLOW.5.6.2], [RLOW.5.6.3], [RLOW.5.6.4], [RLOW.5.6.5.5])*

### `latest`

`latest` adds a NOT sub-node after a sequence's last join, which leaves the single latest qualifying anchor per follower match.

Without `latest`, a sequence lowers to every match, and the rule fires once per valid anchor.

At the NOT sub-node, the anchor `d`, the first follower `m` and every later follower are on the token. The sub-node blocks the match when a fact `f` of the anchor's schema has `d.ts < f.ts < m.ts` and `m.ts − f.ts < T`, and none of the anchor's `where` and the followers' `where`s, with `f` in the anchor's place, answers `false`. Only the first follower's window involves the anchor; in a two-pattern sequence, the last join is the first follower's. The test compares timestamps, not arrival order: an anchor whose `ts` is not before the first follower's never excludes a match.

The compiler refuses `latest` on any pattern but the first, so only the anchor lowers with the NOT sub-node, and a middle pattern lowers to every match.

*(Spec: [RLOW.5.6.5.1], [RLOW.5.6.5.2], [RLOW.5.6.5.3], [RLOW.5.6.5.4])*

## Expressions

### Operators

Every binary operator lowers to a `binop` node carrying its `BinopOp`, and every unary operator but `+` to a `unop` node carrying its `UnopOp`.

Unary `+` lowers to its operand, with no node of its own. Bitwise and shift operators lower to their own members and are never rewritten into arithmetic. Precedence is applied at parse time, and the expression tree encodes the parse tree.

| Operator | Node and op |
|---|---|
| `+` `-` `*` `/` | `binop`: `BINOP_ADD`, `_SUB`, `_MUL`, `_DIV` |
| `//` `%` | `binop`: `BINOP_IDIV`, `_MOD` |
| `==` `!=` `<` `>` `<=` `>=` | `binop`: `BINOP_EQ`, `_NE`, `_LT`, `_GT`, `_LE`, `_GE` |
| `and` `or` | `binop`: `BINOP_AND`, `_OR` |
| `&` `\|` `^` `<<` `>>` | `binop`: `BINOP_BAND`, `_BOR`, `_BXOR`, `_SHL`, `_SHR` |
| `~` | `unop`: `UNOP_BNOT` |
| `not` | `unop`: `UNOP_NOT` |
| unary `-` | `unop`: `UNOP_NEG` |

*(Spec: [RLOW.6.1.1], [RLOW.6.1.2], [RLOW.6.1.3], proto: rete_expr.proto)*

### Boolean rewriting

The compiler does not simplify `and` or `or` by absorption or distributivity.

The compiler may reorder operands and apply commutativity, associativity, De Morgan and double negation. It may fold an `and` with a literal `false` operand to `false`, and an `or` with a literal `true` operand to `true`.

*(Spec: [RLOW.6.1.4])*

### Comparison chains

A comparison chain compiles to comparison `binop` nodes joined by `BINOP_AND`, one per adjacent pair.

Mixed operators lower the same way: `a < b <= c` is `and(lt(a, b), le(b, c))`.

*(Spec: [RLOW.6.2], [RLOW.6.2.1])*

### `Date` arithmetic

`Date` arithmetic lowers to its own builtins, never to integer arithmetic.

A `Date` is held as a day count and a `Duration` as nanoseconds.

| Expression | Lowers to |
|---|---|
| `d + dur` | `FN_DATE_ADD_DURATION(d, dur)` |
| `d - dur` | `FN_DATE_SUB_DURATION(d, dur)` |
| `a - b`, both `Date` | `FN_DATE_DIFF(a, b)` |

*(Spec: [RLOW.6.1.5], proto: builtin_fn.proto)*

### `Duration` saturation

A `Duration`-valued `-`, `*` or `/` lowers to `FN_MAX(x, 0)`, where `x` is the integer operation.

This covers `a - b` with two `Time` or two `Duration` operands, `n * dur`, `dur * n` and `dur / n`. The constant folder folds each to the value this lowering computes. Where an operand's static type is nullable, the operation lowers to `IF(x is null, x, FN_MAX(x, 0))`, so a `null` operand yields `null`. `Date - Date` saturates inside `FN_DATE_DIFF`.

*(Spec: [RLOW.6.1.6], proto: builtin_fn.proto)*

### Interval operations

No runtime holds an interval value: each operation on an interval lowers to a comparison of its endpoints, inside `FN_INTERVAL_CHECK`.

The call is `FN_INTERVAL_CHECK(s₁, e₁, v)`, or `FN_INTERVAL_CHECK(s₁, e₁, s₂, e₂, v)` for an operation with two interval operands. Each `sᵢ .. eᵢ` is an interval operand, and `v` is the lowered endpoint comparison or component read. The check encloses `v` and is never an operand of an `and` beside it.

The engine evaluates the check as follows:
1. If no argument faults and every pair is valid, it yields `v`, `null` included.
2. Otherwise it yields one fault. The candidates are the faults of its arguments and, for each pair whose endpoints are two non-`null` values that are not `s <= e`, a `ComputationError` of kind `DOMAIN` whose offending operand is that pair's `s`.

A `null` `v` does not prevent the check, and a pair with a `null` endpoint is valid. Where both endpoints of a pair are compile-time constants and `s <= e`, the compiler may leave that pair out of the check. When no pair is left, it lowers the operation to `v` alone. The compiler never folds an operation over an invalid interval to a value; an invalid interval of literals is refused.

*(Spec: [RLOW.6.1.7], proto: builtin_fn.proto)*

### Path access

`b.s`, where `s` is a slot that the schema of pattern binding `b` declares, lowers to one `var` node carrying `b`'s pattern index and `s`'s slot index.

The compiler resolves the slot against the binding's schema at compile time. A path continues past the slot only when the slot is `Json`. It then lowers to a `call` node of `FN_JSON_PATH` whose arguments are the slot's `var` node and the rest of the path, as a string literal. The traversal returns the leaf value, or `null` where the path does not resolve. A leaf whose type does not match the operator raises a `TypeError` and abandons the activation.

*(Spec: [RLOW.6.3.1], [RLOW.6.3.2], [RLOW.6.3.3], [RLOW.6.3.4], [RLOW.13.5], proto: rete_expr.proto)*

### Clock reads

`now()` lowers to the `now` expression, and `monotonic_ns()` to a call of `FN_MONOTONIC_NS`.

What each reads is [Clock functions](rete-network.md#clock-functions).

*(Spec: [RLOW.5.4.1], proto: rete_expr.proto)*

### String interpolation

An interpolated string literal compiles, whole, to one `InterpExpr` node: a sequence of `FormatPrim`s in source order.

| Source | Primitive |
|---|---|
| literal text between sites, `{{` and `}}` reduced to `{` and `}` | `text` |
| a site with a numeric or string spec, or no spec | `value`: alignment, `+`, `0`, width, precision and type |
| a site with a timestamp spec | `time`: the value, evaluated once, and the pattern as items, one field per directive and text for the literal characters and each `%%` |

A site with no spec leaves every `value` field at its zero value, which renders the value's canonical text. The compiler resolves every format spec into the primitives' fields, and no format string reaches the runtime. The runtime renders the node in one pass, appending each primitive's text. Mismatched braces, an unknown binding or an unparseable format spec is a compile error.

*(Spec: [RLOW.6.4], [RLOW.6.4.1], [RLOW.6.4.2], [RLOW.6.4.3], [RLOW.6.4.4], [RLOW.6.4.5], [RLOW.13.6], proto: rete_expr.proto)*

## Actions

### `emit`

`emit X` compiles to a terminal action of kind `ACTION_ASSERT` carrying the target schema and its slot assignments; `emit X logical` compiles to the same action with kind `ACTION_LOGICAL_ASSERT`.

The action carries one slot assignment per slot kwarg the `emit` gives, and one `null` assignment per nullable slot it omits. A `retain:` is the fact's TTL override, not a slot assignment. The runtime asserts the fact through the dispatcher. Where the target schema declares `ts`, the action carries no value for it, and the runtime fills it with the wall clock's current sample as a UTC `Time`.

A logical emit passes the firing activation token as the TMS justifier, and the engine retracts the emitted fact when that activation ends. The compiler refuses `emit X logical` unless `X` is declared `logical`.

*(Spec: [RLOW.7.1.1], [RLOW.7.1.2], [RLOW.7.1.3], [RLOW.7.1.4], [RLOW.13.7])*

### `withdraw`

`withdraw` compiles to a terminal action of kind `ACTION_WITHDRAW`.

Where the binding is a continuation body's capture of an outer pattern, the kind is `ACTION_WITHDRAW_BY_ID`.

*(Spec: [RLOW.13.8])*

### `publish`

`publish X` compiles to a terminal action of kind `ACTION_CALL` whose expression calls `FN_PUBLISH` over the target schema's name and the slot values.

The runtime routes the action through the dispatcher's publish path.

*(Spec: [RLOW.7.2.1], [RLOW.13.8])*

### `call`

`call` compiles to a terminal action of kind `ACTION_CALL` whose expression calls `FN_CALL` over the service, the correlation and the call's typed arguments.

The action enters the dispatcher as `(service, correlation, args)`:
- the service is the one the dotted path names;
- the correlation comes from `as`, or, for a call with no `as`, is generated by the compiler for each firing;
- `args` holds one typed argument per kwarg the call supplies, other than `cooldown` and `as`.

The compiler emits each kwarg as its name and its value expression, sorted by name, so source order does not change the artefact. The runtime evaluates each value to its kind, and a fact kwarg's binding becomes a `FactExternal`. No JSON is built. A `Float` argument whose value is NaN refuses the call.

Each generated correlation value lowers to one `FN_GENSYM`, bound before the terminal's first action. Every reader of that correlation reads that one binding: the call, a continuation's capture fact, and its timeout timer.

The service resolves in the dispatch table at compile time, and the argument types match the service's request schema.

A call compiles to no supersedure sweep. The engine performs the retraction while it evaluates the call's `FN_CALL`, on that call's correlation and before it issues the request. It takes the response schema from the service's `ServiceDef`. A `cooldown` gate that denies the call leaves the `FN_CALL` unevaluated, and nothing is retracted. A generated correlation is swept as an `as` value is.

*(Spec: [RLOW.7.3], [RLOW.7.3.1], [RLOW.7.3.2], [RLOW.7.3.3], [RLOW.7.3.4], [RLOW.7.3.8], [RLOW.7.3.10], [RLOW.13.8], proto: service_def.proto)*

### Quantity arguments

A quantity argument on a unit-typed kwarg is lowered in the kwarg's unit.

Unless the kwarg's unit is tier-2, the compiler folds a value it knows at compile time into the kwarg's unit and emits a literal. Any other value, and every value on a tier-2 unit, is wrapped in the unit's conversion from the base unit:

| Dimension storage | Conversion |
|---|---|
| `float64` | arithmetic expression nodes with constants the artefact carries: a tier-1 unit's inverse affine map, a tier-2 unit's `from_base` |
| `int64` | `FN_INT_DIV_EXACT` of the base-unit value and the unit's factor, a whole number of base units |

`FN_INT_DIV_EXACT(n, d)` yields `n / d` when `d` divides `n` exactly. A zero `d` raises a `ComputationError` of kind `DIVIDE_BY_ZERO`, and a `d` that does not divide `n` raises one of kind `NOT_REPRESENTABLE`. A `null` operand yields `null`.

*(Spec: [RLOW.7.3.9], proto: builtin_fn.proto)*

### `cache` and `cache_delete`

`cache` compiles to a terminal action of kind `ACTION_CALL` whose expression calls `FN_CACHE_SET` over the key, the value wrapped in an `FN_JSON_VALUE` call, and the TTL. `cache_delete` calls `FN_CACHE_DELETE` over the key.

The TTL is zero when the action gives none. The key is the action's string literal, and lowers to a literal. The runtime routes each action to its cache dispatcher entry.

*(Spec: [RLOW.7.4], [RLOW.13.8])*

### `cached`

`cached(key)` is an expression, not an action, and there is no cache-read action verb.

It is admitted as the whole right-hand side of a `let` or in a `where`. In a `let` it is sync-impure and is bound once per firing ([`let`](#let)).

*(Spec: [RLOW.7.5.1])*

### `log`

`log` compiles to a terminal action of kind `ACTION_CALL` whose expression calls `FN_LOG` over `(level, category, message)`.

The compiler encodes the level, in any case, as its `LogSeverity` number, so `info`, `INFO` and `Info` are one level. The category is the rule's name and has no source form.

*(Spec: [RLOW.7.7], [RLOW.7.7.1], [RLOW.13.8], proto: log_level.proto)*

### Comments

DS source comments are non-semantic and are preserved by the `DsSource` atom.

`DsSource` carries the module's DS source text verbatim, comments included. A tool reads a node's source context from `DsSource[module_id]` through the node's `LineSpan` atom.

*(Spec: [RLOW.7.8.1])*

## Series

### Series declaration

A series declaration compiles to runtime backend atoms, not to an observable runtime construct.

The compiler resolves the declaration's observation lines into one or more backend atoms. The identity slot is the `by:` block-option's, or the schema's declared identity where it has one, with no by-name default. The compiler selects the backings, and the author never names one. It emits one backend atom per (backing, window), each carrying the window of the observation line it serves. A line with no exact backing is refused before lowering, and a declaration no lowered rule reads emits no backend atom.

Sample absorption is an engine step, not a compiled rule: the engine absorbs once per pump, after the agenda drains. The compiler emits the backend atoms and keys the per-(schema, slot, identity value) backend state as the aggregation call reads it.

*(Spec: [RLOW.8.1.1], [RLOW.8.1.2], [RLOW.8.1.3], [RLOW.13.9])*

### Aggregation call

Each series read of an aggregation lowers to a call of that aggregation's `FN_SERIES_*` builtin.

The arguments are, in order:
1. the schema's name;
2. the slot's name;
3. the identity slot's name, empty when the series has none;
4. the identity value, read from the bound fact;
5. the window of the observation line the read resolves to, in nanoseconds, and `0` for `all_time` and `sample`.

`FN_SERIES_PERCENTILE` takes its rank as a sixth argument, and `count_of` and `contains` take their value there. In a `where` the call is in the pattern's beta join test. The call reads the backend state for the fact's own identity value. Every aggregation read, in a `where` or on the RHS, sees the pre-sample snapshot: the state at the start of the pump, before any sample absorbed in it.

*(Spec: [RLOW.8.1.4], [RLOW.8.2], [RLOW.8.2.1], proto: builtin_fn.proto)*

### Companion slots

A companion slot desugars at compile time to its aggregation call.

| Companion | Lowers to |
|---|---|
| `s.mean`, and so for every aggregation | `mean(s)` |
| `s.stdev` | `stdev(s)` |
| `s.p95` | `FN_SERIES_PERCENTILE` with rank `95` |
| `s.dwell`, `logical` bindings only | `FN_MONOTONIC_NS` minus an `entry_stamp` read |

`s.dwell` is a compile-time alias, not a series query. Every other companion's call carries the window of the observation line it resolves to: the slot, the aggregation, and the label where the slot declares that aggregation on more than one line. A companion with no declared observation covering it is a compile error. The desugaring runs before backend emission, and companion references drive backend atom emission as aggregation references do.

*(Spec: [RLOW.8.3.1], [RLOW.8.3.2], [RLOW.8.3.3], [RLOW.8.3.4], [RLOW.8.3.5], [RLOW.8.3.6], [RLOW.8.3.7], proto: rete_expr.proto)*

## Settings

### Dialect gating

The compiler resolves the program's settings to determine which constructs are permitted, and a rule using a construct its settings forbid fails compilation.

A capability set `false` refuses the forms it gates. The compile fails, so no node is generated for the rule, and nothing else in the artefact moves:

| Setting | Effect |
|---|---|
| `series: false` | a `series` declaration fails compilation, no backend atom is emitted, and a series read has no declaration to resolve against |
| `cache: false`, `cache_delete: false` | each refuses its own action verb; a `cached(key)` read is gated by neither and lowers unchanged |
| `call` disabled | a rule using `call` fails compilation; the dispatch table is still built from the imported service declarations, and the setting does not gate the other action verbs |
| `publish` disabled | a rule using `publish` fails compilation |

The compiler is aware of tiers only through the dialect, and a tier's name has no lowering of its own. Two tiers with the same dialect get the same lowering.

*(Spec: [RLOW.10.1.1], [RLOW.10.2.1], [RLOW.10.2.2], [RLOW.10.2.3], [RLOW.10.2.4], [RLOW.10.2.5], [RLOW.10.3.1], [RLOW.13.11])*

## Tests

### `test` declaration

A `test` declaration lowers to the `Test*` and `Oracle*` atom families.

| Source | Atoms |
|---|---|
| each case | `TestCase` |
| `initial`, `inputs` | `TestFact`, `TestCacheSeed` |
| `responses` | `TestResponse`, `TestReply` |
| each `produces` assertion | one `Oracle*` atom |

A constructed fact, `TestFact`, `TestReply` or `TestCacheSeed`, carries literal slot values, with every author-supplied slot given. An `Oracle*` atom carries a partial match: inline slot-equality constraints or, on `OracleEmit` and `OraclePublish`, a `where` predicate in their place, never both. That predicate is flagged by `has_where` and realised as a compiler-synthesised internal rule.

The compiler numbers the tests a compile carries from 1: by module, in ascending `module_id`; within a module, the `.ds` file's tests in source order, then its companion `.dstest`'s. A test's number is its `TestCase`'s `test_id`, which every `Test*` and `Oracle*` atom of the test carries, and no two tests in one artefact share one.

Every test reference binds at compile time. `OracleActivated` rule names, every `Oracle*` schema name and `TestFact` schema names resolve against the compiled program's rules and schemas. A dangling reference is a compile error: `DS_VALIDATE_TEST_UNKNOWN_RULE`, `DS_VALIDATE_TEST_UNKNOWN_SCHEMA`, `DS_VALIDATE_TEST_UNKNOWN_SLOT` or `DS_VALIDATE_TEST_NON_LITERAL`. A `for call … as` correlation is a string literal.

*(Spec: [RLOW.17.1], [RLOW.17.2], [RLOW.17.3])*

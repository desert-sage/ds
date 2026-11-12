<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The `.dstest` language

## Model

### Test model

A declarative relation between an input timeline and the outputs a program must produce.

The runtime derives every engine operation from the timeline. At each stamp it asserts that stamp's inputs in source order and pumps to quiescence, and it advances the clock across the union of all stamps, firing `$ClockTick` and TTL sweeps along the way.

The compiler lowers a test to the `Test*` and `Oracle*` test atoms, and the runtime parses no test source. A constructed fact takes `emit`'s colon-keyword arguments, a matched fact takes pattern syntax, and a stub takes `call`'s `as` form.

*(Spec: [LTSL.1.1], [LTSL.1.2], [LTSL.1.3], [LTSL.3.4], [LGRA.21.3])*

## File structure

### `test`

**`test_decl ::= 'test' STRING_LIT ':' INDENT test_section+ DEDENT`**

**`test_section ::= test_inputs | test_initial | test_responses | test_produces | test_until`**

A top-level declaration, written in a `.ds` beside the rules it exercises or in a `.dstest` file, under one grammar.

`produces` is required. `initial`, `inputs`, `responses` and `until` are optional, and a section keyword appears at most once. A test with no `inputs` supplies `until`.

| Condition | Code |
|---|---|
| no `produces` section | `DS_VALIDATE_TEST_NO_PRODUCES` |
| a section keyword repeated in one test | `DS_VALIDATE_TEST_DUPLICATE_SECTION` |
| neither `inputs` nor `until` | `DS_VALIDATE_TEST_NO_INPUTS_OR_UNTIL` |

```ds declaration
test "idle":
    until 1_s
    produces:
        wm empty
```

*(Spec: [LGRA.21.1], [LTSL.2.1], [LTSL.2.3], [LTES.7.5])*

### `.dstest` file

A file of `test` declarations and nothing else.

| Condition | Code |
|---|---|
| any other top-level declaration | `DS_VALIDATE_TEST_COMPANION_DECL` |
| a `use` directive | `DS_VALIDATE_USE_IN_TEST` |

*(Spec: [LTSL.2.1], [LTSL.2.2], [LDIA.2.10.6])*

### Companion

The `.dstest` file in a module's directory with the module's stem: `board_model.dstest` beside `board_model.ds`.

The compiler reads the companion of each module it compiles, wherever the module's import resolves: beside the program, in a `-L` directory or in the bundled library. It reads no other `.dstest`.

A diagnostic in a companion names it as at [Input name](dsc.md#input-name).

*(Spec: [LTSL.2.4])*

### Carried tests

A compile carries the tests of the program and of every module in its import closure. A module's tests are the `test` blocks of its `.ds` file and of its companion, and a test belongs to its module whichever file holds it.

A module's tests see the module's own declarations and what it imports. A reference that resolves to no rule, schema or slot there is refused:

| Condition | Code |
|---|---|
| a rule | `DS_VALIDATE_TEST_UNKNOWN_RULE` |
| a schema | `DS_VALIDATE_TEST_UNKNOWN_SCHEMA` |
| a slot | `DS_VALIDATE_TEST_UNKNOWN_SLOT` |

A test takes the resolved settings of the program it is compiled in. Indentation, comments and string and unit literals are DS's.

*(Spec: [LTSL.2.2], [LTSL.2.4], [LTSL.4.1], [RLOW.17.3])*

### Reserved words

`test`, `never` and the heads of a test body are [reserved](../lang/lexical.md#reserved-words). Each has its keyword meaning in its own position.

*(Spec: [LGRA.21.2])*

## Time

### Relative coordinates

**`time_coord ::= UNIT_LIT | postfix`**

A `UNIT_LIT` is an offset from the test's start (`0_s`, `5_min`, `100_ms`). It drives the monotonic engine clock that `ttl`, `cooldown` and `then within` read. The test runner sets the wall clock to the offset from the Unix epoch: `at 5_s` is `1970-01-01T00:00:05Z`, and the test's start is the epoch. `now()` and an engine-filled [`ts`](../facts/schemas.md#ts) read it. A test stepping by `5_s` pumps at that instant.

*(Spec: [LGRA.21.1], [LTES.3.3.2], [LTSL.3.1], [LFAC.9.2])*

### Absolute coordinates

A [`calendar.time`](../time/calendar.md#calendartime) call in the `at` or `until` position, whose arguments fold. It sets the wall clock to its instant and advances the monotonic clock by the interval since the previous coordinate.

With relative coordinates, a rule that reads the calendar from `now()` reads a date in 1970. A test uses one mode throughout.

| Condition | Code |
|---|---|
| relative and absolute coordinates in one test | `DS_VALIDATE_TEST_MIXED_TIME_MODE` |
| a coordinate of any other form, one whose fold faults, or one before 1970-01-01T00:00:00Z | `DS_VALIDATE_TEST_BAD_TIMESTAMP` |

```ds declaration head
import calendar
test "dated":
    until calendar.time(2026, 6, 18, 14, 0, 0)
    produces:
        wm empty
```

*(Spec: [LTSL.3.2], [LTSL.3.7])*

### `until`

**`test_until ::= 'until' time_coord NEWLINE`**

Extends the run past the last input stamp.

*(Spec: [LGRA.21.1], [LTSL.3.5])*

## Facts

### Construction

**`test_fact ::= type_ref action_arg* NEWLINE`**

In `initial`, `inputs` and `responses` replies, a fact is the schema name and a colon-keyword value for every author-supplied slot. A value is a literal or the name of a [`const`](../lang/program.md#constant-declarations), which the compiler folds:

- an `Int` or `Float` literal, optionally negated;
- a duration literal;
- a `Bool`;
- a `String` with no interpolation site;
- `json("…")` over one string literal, whose escapes are decoded and whose braces are literal text.

Any other value is refused with `DS_VALIDATE_TEST_NON_LITERAL`. The test runner refuses a scenario whose `json()` text is not a JSON value.

`ts` is not given. A value for it is refused with `DS_VALIDATE_TS_READ_ONLY`, at [`ts` read-only](../facts/schemas.md#ts-read-only).

```ds test
initial:
    Reading id: "a" level: 2.0 n: 1 label: "x" ok: true
```

*(Spec: [LGRA.21.1], [LTSL.4.1], [LFAC.9.3])*

### Matching

In `produces` heads and `for call` keys, a head with slot arguments matches by subset equality: the named slots equal the observed fact's, and other slots are free.

An `emitted` head takes a binding and a `where` clause in place of slot arguments, never both. The predicate has the expression surface of a rule's `where`. A `where` match is a fact emitted in the run. An input or `initial` fact that satisfies the predicate is not a match.

A `published` head takes slot arguments alone. A `where` on a `published` head, with or without `never`, is refused with `DS_VALIDATE_TEST_PUBLISHED_WHERE`.

```ds declaration
test "bound":
    until 1_s
    produces:
        never emitted Reading r where r.n > 0
```

*(Spec: [LTSL.4.2], [LTSL.8.4], [RTIM.14.7])*

### Exact value match

A test compares a literal with an observed value in a subset-matching head's slots, a `for call` stub's argument keys and a `cached` head's value. The two are equal exactly when:

- both are numbers and denote the same number: an `Int`, `Duration` or `Float` literal with an `Int`, `Float`, `Duration`, `Time` or `Date` value, neither side promoted or rounded;
- a `String` or `Bool` literal and a value of its own kind hold the same value;
- a `Json` literal and a `Json` value, or any literal and a cache value, are the same JSON value: numbers by the number they denote, an object by its members in any order, an array element by element in order;
- a literal with no value meets a null value.

Any other pair is unequal. A `Json` literal is unequal to a `String` or number slot or argument, and a `String` literal to a `Json` one. A slot a head names that the observed fact does not carry is unequal to every literal.

*(Spec: [LTSL.4.3])*

### Schema names

A test names a schema as a rule pattern does, `Name` or `lib.Name`, and the name resolves the same way. The [schema](../facts/schemas.md#schema) is the program's.

*(Spec: [LGRA.21.1], [LTSL.4.4])*

## Starting state

### `initial`

**`test_initial ::= 'initial' ':' INDENT test_initial_item+ DEDENT`**

**`test_initial_item ::= test_fact | test_cache_seed | test_cache_block`**

The starting state, applied before the timeline. The oracle does not observe an `initial` fact or cache seed.

*(Spec: [LGRA.21.1], [LTSL.5.1])*

### Pre-loaded fact

A construction line in `initial` places a fact in working memory before the first input.

*(Spec: [LTSL.5.3])*

### Cache seed

**`test_cache_seed ::= 'cache' STRING_LIT ':' expression NEWLINE`**

**`test_cache_block ::= 'cache' ':' INDENT test_cache_entry+ DEDENT`**

**`test_cache_entry ::= STRING_LIT ':' expression NEWLINE`**

Seeds the engine's live cache before the run. A rule's later [`cache`](../actions/cache.md#cache) write is visible to a later [`cached`](../actions/cache.md#cached) read.

```ds test
initial:
    cache "limit": 5.0
```

*(Spec: [LGRA.21.1], [LTSL.5.2])*

## Input timeline

### `inputs`

**`test_inputs ::= 'inputs' ':' INDENT test_at_block+ DEDENT`**

**`test_at_block ::= 'at' time_coord ':' INDENT test_fact+ DEDENT`**

A set of `at` blocks of constructed facts, unordered in source. `at` appears in `inputs` only.

The runtime orders the facts by stamp, and by source order within a stamp. It asserts each as an external source would.

```ds test
inputs:
    at 30_s:
        Reading id: "a" level: 2.0 n: 1 label: "x" ok: true
```

*(Spec: [LGRA.21.1], [LTSL.3.3], [LTSL.6.1], [LTSL.6.2])*

## Stubs

### `responses`

**`test_responses ::= 'responses' ':' INDENT response_stub+ DEDENT`**

The environment's replies to outbound calls, and nothing else.

Every outbound call a program makes during the run matches a `for call` entry. An unaccounted call fails the test case.

*(Spec: [LGRA.21.1], [LTSL.7.1], [LTSL.7.6])*

### `for call`

**`response_stub ::= 'for' 'call' service_ref kwarg* ('as' STRING_LIT)? ('after' UNIT_LIT)? ':' INDENT response_body+ DEDENT`**

**`response_body ::= reply_fact | no_response_line`**

A stub keys on the outbound call by its [correlation](../calls/call.md#correlation) or by argument equality. One with neither is refused with `DS_VALIDATE_TEST_STUB_UNKEYED`.

An `as` value is written on the `for call` key. A call with no `as` carries a generated correlation, and its stub keys on arguments.

```ds test
responses:
    for call svc.op level: 2.0:
        no response
```

*(Spec: [LGRA.21.1], [LTSL.7.2], [LTSL.7.7])*

### Reply

**`reply_fact ::= type_ref action_arg* NEWLINE`**

One or more constructed facts. A reply to a call of a service declaring `response T` is a fact of `T` or a [`CallError`](../calls/call.md#callerror), and any other schema is refused with `DS_VALIDATE_TEST_STUB_REPLY_TYPE`.

`corr` is the one slot a constructed fact may leave out. A reply that omits it takes the correlation of the call the stub matched, and a `corr` the reply writes is kept as written.

*(Spec: [LGRA.21.1], [LTSL.4.1], [LTSL.7.2], [LTSL.7.3])*

### `after`

**`'after' UNIT_LIT`**

Delays the reply by that interval. With no `after`, the reply arrives at the call's instant.

A delayed reply's deadline is an instant of the run, as an input stamp is. At a shared instant, input facts are asserted before replies, and replies due at one instant arrive in the order the calls were issued.

Before the clock moves to the next input stamp, reply or `until`, it moves to each [engine deadline](inv:integrator:std:doc#engine/clock) earlier than that instant, and the engine pumps there. An engine deadline at the same instant as an input fact or a reply takes no step of its own: the inputs and replies are applied, and one pump follows them.

*(Spec: [LGRA.21.1], [LTSL.7.4], [RTIM.14.5], [RTIM.14.6])*

### `no response`

**`no_response_line ::= 'no' 'response' NEWLINE`**

Declares an intentionally unanswered call, for a [timeout by absence](../calls/call.md#timeout-by-absence).

A stub for a call of a service that declares [`no response`](../calls/call.md#no-response) contains only this line. One with a reply is refused with `DS_VALIDATE_TEST_STUB_NO_RESPONSE_MISMATCH`.

*(Spec: [LGRA.21.1], [LTSL.7.5])*

## Observations

### `produces`

**`test_produces ::= 'produces' ':' INDENT test_assertion+ DEDENT`**

An unordered set of observations, each checked over the whole run. It is satisfied when every listed observation holds, and an output it does not mention does not fail it.

*(Spec: [LGRA.21.1], [LTSL.3.6], [LTSL.8.1], [LTSL.8.5])*

### Assertion heads

| Head | Asserts |
|---|---|
| `activated <rule>` | the rule produced and ran an activation |
| `emitted <Schema> …` | an `emit` of a matching fact |
| `published <Schema> …` | a `publish` of a matching fact |
| `called <service> [as "corr"]` | an outbound call to the service, optionally with that correlation |
| `cached "k" [: v]` | a cache write of `k`, optionally with value `v` |
| `cache_deleted "k"` | a cache delete of `k` |
| `logged <level> ["substr"]` | a `log` at that level, optionally matching a substring |
| `retracted <Schema> …` | a matching fact left working memory, by TTL expiry or [logical supersedure](../facts/logical.md#superseded-justifications) |
| `wm has <Schema> …` | a matching fact is live at the end of the run |
| `wm count <Schema> == N` | exactly N matching facts are live at the end of the run |
| `wm empty` | working memory holds no facts at the end of the run |

`emitted`, `published`, `retracted` and `wm has` match by subset equality, and `emitted` also by `where`. `called` matches by service and correlation, `cached` by key and value and `logged` by level and substring. Call-argument equality is keyed on the `for call` stub.

*(Spec: [LGRA.21.1], [LTSL.8.2], [LTSL.8.4], [LTSL.8.6])*

### Polarity

**`test_assertion ::= 'never'? test_head NEWLINE`**

A bare head asserts the observation occurred at least once over the run. `never` asserts it occurred zero times.

*(Spec: [LGRA.21.1], [LTSL.8.3])*

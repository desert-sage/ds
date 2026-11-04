<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `dstrace -i` — a time-travelling query shell for a DS program

**Specification · status: stages 0 to 6 built (§12), firing changes deferred (§8.5), stages 7 and 8 specified**

> **Implemented by `dsdb` now.** The Python this specification was
> first built in, the Python `dstrace` and its shell package, has retired:
> `dsdb` (`dsdb/`, [DSDB.md](DSDB.md)) matches it command for
> command and transcript for transcript, and is where stages 7 and 8 and the
> firing changes are built. This document stays the specification of
> behaviour. Where it names a Python file, it describes how that stage was
> first built; the file is in git history.

`dstrace` renders an RFCS fact stream as text. This specification adds
`-i`: an interactive shell over a compiled program. It keeps a current position,
**point**, on a **timeline**. A timeline is a recorded trace, a live session
driven by hand, or a **hypothesis** forked from either. At point, or over all
time, the shell can:

- count and chart facts, rule firings and calls (§4.3, §4.4);
- answer DS queries, written as a rule's left-hand side (§4.2, §7);
- inspect facts, firings and calls, and step through the history (§4.5, §4.6);
- fork hypotheses that change facts, call replies, single firings or the rules
  themselves, and recompute the future (§4.9 to §4.12);
- show the Rete network as it stands (§4.13);
- explain any fact or activation with its full derivation tree (§4.14).

It is time-travel debugging on the command line, beside the
[DAP](../../docs/references/author/tools/dap.md) integration, which needs an editor.

Sections 1 to 6 say what the tool does. Sections 7 to 9 say how it is built.
Section 10 records the research each decision rests on, with its evidence.
Sections 11 and 12 list the changes needed outside dstrace and the build order.
Section 13 is a wishlist of what the design does not yet cover.

---

## 1. Principles

**The compiler is the only parser.** [LTSL.1.2]. Queries and `emit` lines are DS,
compiled by the Mercury `dsc`, the only compiler dstrace targets, through
`pyds.compile()`. dstrace contains no DS expression parser. It does split
command lines into a sigil, scope and body (§4), which is shell syntax, not DS.

**The engine is the only evaluator.** A query is answered by libds running a rule.
dstrace never evaluates a DS expression against decoded facts.

**The trace is authoritative about the past.** dstrace never computes an expiry,
supersession or derivation for reality. It reads them from the trace, or from an
engine that re-runs the recorded inputs.

**Actions are callbacks.** Every rule action leaves the engine through an
integrator callback. In a live session or a hypothesis, dstrace is the
integrator. It records, drops, alters or fakes actions in its own callbacks, and
needs no engine hook to do so.

---

## 2. Invocation and session modes

```
dstrace -i PROG.dsc                    live
dstrace -i PROG.dsc RUN.dstrace [-f]   replay
dstrace -i RUN.dstrace [-f]            replay of a self-contained trace ([RFCS.13])
```

Files are recognised by what they are, not by position or flag: a trace has a
`StreamHeader`, a `.dsc` is atoms with none, and a `.ds` is source text. Any
order works. `.ds` files and `-L` are the last resort for a stripped program
(below).

| Mode | `%0` is | Point can move | `emit` at the end of `%0` |
|---|---|---|---|
| live | a fresh engine running the program, recording itself | anywhere in `%0`'s own history; forward by advancing the clock | applies to `%0` |
| replay | the trace on disk | anywhere in the trace | opens a hypothesis |

- **The `.dsc` is required.** It supplies every schema, each schema's lifecycle,
  and the program itself. A self-contained trace carries it at the front.
- **In replay,** the trace header's `dsc_hash` must equal the `.dsc`'s, or
  dstrace refuses to start and prints both hashes.
- **`-f` in replay** keeps reading as the file grows. New records extend `%0` and
  every cached answer timeline (§7.5).
- **Without `-i`,** dstrace behaves exactly as it does today.

**Program source, as a last resort.**

```
dstrace -i PROG.dsc RUN.dstrace PROG.ds [-L DIR]...    a stripped .dsc, plus its source
dstrace -i PROG.ds [-L DIR]...                         live, from source
dstrace -i PROG.ds RUN.dstrace [-L DIR]...             replay, from source (below)
```

Several features need the program's source text, not just its artefact: rule
hypotheses (§8.6), pattern text in `rete` (§8.7), and the `emit` lines, `let`
lines and negated patterns in derivation trees (§8.8). A `.dsc` normally embeds
its source (§10.11), and dstrace uses that. A `.dsc` built with `dsc --strip`
does not: it drops the source and debug atoms (`DsSource`, the source-location
atoms, and the display-name templates). For that case:

- **a `.ds` file** among the files given is the program's entry source file;
- **`-L DIR`, `--search-path DIR`**, repeatable, names where its imported
  libraries live, exactly as `dsc -L` does. Without it, the entry file's own
  directory is searched, as `pyds.compile_file` does.

dstrace compiles the source with the Mercury `dsc` and **checks that it is the
program in the `.dsc`** before using it. The two must declare the same schemas,
with the same slots, roles and lifecycles (§7.1 reads both the same way), and
the same rules by name. A difference refuses the source, naming the first
mismatch, and the shell starts without it. The features that need source then
say so. A byte-for-byte hash comparison is not possible, because a stripped
artefact's bytes differ from an unstripped one's.

**The order of preference** is the `.dsc`'s embedded source, then a `.ds`
given, then none. Given both, the embedded source wins and the `.ds` is ignored
with a note.

**With no `.dsc` at all**, a `.ds` can stand in for it:

- **live**, always: dstrace compiles the source and runs that;
- **in replay**, only if the compiled artefact's `dsc_hash` equals the trace
  header's, which holds when the trace was recorded with an unstripped build of
  exactly this source and compiler. Otherwise dstrace asks for the `.dsc`.

What works with no source at all: everything in stages 1 to 5 except `show
rule`, plus `rete` with alpha test text only, and derivation trees without
source lines.

**Exit status.** `0` after `quit` or end of input, `2` on a usage error, `3` when
the trace and `.dsc` do not belong together, `4` when a file given cannot be
read as a trace or a `.dsc` at all. A malformed record later in a trace does not
stop the shell (§6).

**Known limit on types.** Both compilers lower `Time`, `Date` and `Duration` to
`Int` and unit-typed slots to their storage kind, in the `.dsc`
as well as the trace. Until those are fixed, declarations generated from the
`.dsc` say `Int` or `Float`. A query using a `Time` operation or a unit literal
on such a slot fails to compile, and dstrace prints the compiler's error plus
one line naming the issue.

---

## 3. The model

### 3.1 Records

dstrace works on **records**, one per atom, decoded once. Each record has:

| Field | Meaning |
|---|---|
| `index` | its ordinal in the timeline, from 0 |
| `kind` | the atom's name (`FactAssert`, `FactEmit`, …) |
| `seq` | the engine sequence number, or none |
| `clock_ns` | the atom's own clock, or the last clock seen before it |
| `cls` | `inject`, `derived` or `structural` (below) |
| `body` | the decoded fields |

| Class | Kinds | Meaning |
|---|---|---|
| `inject` | `FactAssert`, `FactRetract`, `ClockAdvance`, `PumpBoundary` | what the host did: its inputs, the clock samples taken for them, and its pumps |
| `derived` | `FactEmit`, `FactWithdraw`, `RuleFireAnnotation`, `CallIssued`, the four fault atoms | what the engine did in response |
| `structural` | `StreamHeader`, `SchemaDef`, `Slot`, unknown | framing, no replay role |

This is [RFCS.17.5]'s inject and compare split, with compare renamed
`derived`. The engine writes a `PumpBoundary` for every pump ([RFCS.22]), and
a `ClockAdvance` carrying both clocks before the input or pump it was sampled
for. Of the inject records, the **inputs** are `FactAssert` and
`FactRetract`: what the integrator asserted or retracted, and what a count of
inputs counts.

A hypothesis or live timeline builds its records from the engine's stream
callback instead of from a file (§8.4). The record model is the same, so every
command reads every timeline the same way.

### 3.2 Positions and point

A **position** is a `seq` value, printed as eight hex digits as `dstrace.py`
prints it. Sequence numbers are not contiguous in a trace. The engine numbers
every stream event, and several kinds are never recorded (§10.2).

The state **at** position `N` is every record up to and including the last one
whose **anchor** is at most `N`. A record's anchor is its own `seq`, or for a
record with none, the anchor of the record before it. An integrator's
`FactRetract` carries no `seq`, so it belongs to the position before it.

**Point** is the current position of the current timeline. Each timeline keeps
its own. `@N` for a position that no record has moves to the nearest earlier
one and says so. `@N` past the last position is refused with the last position
named.

### 3.3 Settled points

The trace records every pump, so where each cascade ended is read off
the trace rather than assumed. A **step** is the host's inject records up to
and including a `PumpBoundary`: any inputs, the clock sample taken for them,
and the pump that runs them to quiescence. The replayer applies exactly that
(§10.3). So a **settled point** is:

- the position just before each step's first inject record, and
- the end of the timeline.

Any other position is **mid-cascade**, a state no rule saw as final. Several
inputs before one pump are one step, and the points between them are not
settled.

**A superseding assert starts one record early.** When a logical assert
supersedes a fact, the recorder writes the old fact's `FactWithdraw` (cause
`SUPERSEDED`) before the new fact's `FactAssert`. The settled point for that
input is therefore just before the withdrawal. Stage 5's program engine found
this: at the point between the two, the trace had withdrawn the old fact and
no engine state ever had.

A stream with no `StreamHeader` is not a whole trace: dstrace reports "settled
points unknown", stepping is by record only, and hypotheses cannot fork in
replay.

**A settled point before a retract is written `@N-`.** When a step begins
with an integrator's `FactRetract`, the settled point just before it and the
point just after it share an anchor, since the retract carries no `seq`. `@N`
means the later one, which is mid-cascade: the step's `PumpBoundary` has not
run yet. The settled point is `@N-`, where `p` and `n` stop and the prompt
shows it. A `seq` on `FactRetract` would remove this.

### 3.4 Clock

Every record has a clock: its own `clock_ns`, or the last one seen. Histograms
use clock time on their horizontal axis. Everything else uses positions. Times
print as seconds from the first record's clock, with three significant decimals
when needed (`12.0s`, `41.215s`).

### 3.5 Timelines

| Name | What it is |
|---|---|
| `%0` | reality: the trace in replay, the session's own record when live |
| `%1`, `%2`, … | hypotheses, numbered from 1 in order of creation and never reused |

Every command runs on the **current timeline** unless it names others (§4.8).

---

## 4. The command language

### 4.1 Lines

A line is one of:

- a **query or count**: a sigil, a scope, optional timelines, and an optional body;
- a **navigation** line starting with `@`, or one of `n`, `p`;
- a **command word** with arguments;
- a **row number**, a bare decimal integer, which drills into that row of the
  last listing.

Leading and trailing spaces are ignored. An empty line does nothing. `#` starts a
count, not a comment.

### 4.2 Grammar

```
line       = query | nav | command | row
query      = sigil scope { ' ' timeline } [ ' ' body ]
sigil      = '?' | '#' | '!' | '^'
scope      = '.' | ':' | '@' pos
timeline   = '%' decimal
body       = ds-lhs [ ' -> ' projection ] [ hist-opts ]
           | '(' NEWLINE { ds-pattern NEWLINE } [ '->' projection NEWLINE ] ')' [ hist-opts ]
           | regex [ hist-opts ]
           | hist-opts
projection = ds-expr { ',' ds-expr }
hist-opts  = [ ' tumbling ' duration ] [ ' ' ( 'min' | 'max' | 'mean' ) ]
nav        = '@' [ pos | '<' | '>' | '$' | ( '+' | '-' ) ( decimal | duration )
                 | duration | '#' decimal | '[' | ']' ]
           | ( 'n' | 'p' ) [ ' ' ( 'atom' | 'fire' | 'tick' ) ]
pos        = hexdigit { hexdigit } { '-' }
duration   = number '_' unit           (a DS unit literal with its underscore)
row        = decimal
```

- **`@<` is the start of time**, before any record, and **`@>` the end**. `@$`
  is kept as an alias for the end. `@0` is an ordinary position, seq 0, like any
  other hex: the start has its own spelling, so no number needs a special
  meaning.
- **`@[` and `@]`** are the fact inspector's: where the fact shown began and
  where it ended, bracketing its life.
- **`hist-opts` are read only from the end** of a body, and a regex only when it
  is the whole body. A DS query may itself contain `/regex/` or a slot named
  `max`, and reading options out of its middle would change the query.

- **Hex versus time.** A token of hex digits only is a position. A clock amount
  must carry its underscore (`12_s`, `1_d`), because DS lets a unit follow a
  number directly and `d` is both a hex digit and the day unit.
- **`@` alone** prints the current timeline, position, clock and settledness.
- **`%N` is recognised only** as a command's argument or directly after a
  scope. Inside a DS body, `%` is modulo.
- **The body** is passed to the compiler unchanged, except that a bracketed body
  has its outer brackets removed and each inner line placed as its own pattern.
  A line ending in `(` after the scope opens the bracket, and a line holding only
  `)` closes it. The prompt shows `...` while one is open.
- **`!` and `^` take a regex** over rule names in place of a DS body. `#` with no
  query takes a regex over schema names.

### 4.3 The query and count matrix

| | list | count |
|---|---|---|
| **facts** | the inspector (§4.6) | `#` with no query |
| **query answers** | `?` | `#` with a query |
| **rule firings** | `!` | `^` |

| | `.` point | `:` all time | `@N` position |
|---|---|---|---|
| `?` + query | answers at point | every answer that held at any position, with when it held | answers at `N` |
| `#` + query | count at point | answer population over time | count at `N` |
| `#`, no query | per-schema live counts at point | per-schema population over time | per-schema counts at `N` |
| `!` | firings in the cascade that led to point | every firing | firings in the cascade that led to `N` |
| `^` | firings per rule in that cascade | firings per rule over time, as a rate | firings per rule in that cascade |

"The cascade that led to" a settled point is every derived record since the
previous settled point. At a mid-cascade point, it is those up to point.

### 4.4 Output formats

Rows are numbered from 1 in each listing. A later bare number refers to the most
recent listing.

**`?.` and `?@N`**

```
- ?.Thermometer t where t.temperature > 85.0
  1  t = Thermometer#88   entity_id="kitchen" temperature=91.0
  2  t = Thermometer#140  entity_id="hall"    temperature=86.5
  2 answers at @00001aba 12.0s
```

With a projection, the columns are the projected values:

```
- ?.Thermometer t where t.temperature > 85.0 -> t.entity_id, t.temperature
  1  kitchen  91.0
  2  hall     86.5
```

The projection follows ` -> ` on the query's line, or is a line starting `->`
at the end of a bracket block. A prompt cannot wait to see whether a next line
is coming, so a projection on its own line after a one-line query is not
possible. A projection is compiled as `let` bindings on the query rule, and the
engine reports their values through a `log` action (§7.2), rendered as DS
interpolation renders them.

**`?:`** lists each binding tuple once, with every interval it held over:

```
- ?:Thermometer t where t.temperature > 85.0
  1  t = Thermometer#12   0000004a..00000090   2.1s..4.9s
  2  t = Thermometer#88   0000011f..now        12.0s..
```

**`#.` and `#@N`** with a query print one number. Without a query they print one
bar per schema on a **shared scale**, sorted by count then name, keeping zero
rows. At point each row also shows its change since the previous settled point.

```
- #.
  @00001aba  12.0s
  Thermometer   ████████████████████████  11
  Occupied      ██████▌                    3  +1
  DoorEvent     ██                         1
  ForecastReply                            0
```

**`#:`** with a query draws one row, the answer population. Without a query, one
row per schema, **each scaled to its own peak**. `^:` draws one row per rule, the
firings per bucket. All three share this layout:

```
- #:
  0s ──────────────────────────────── 41.2s     peak   now
  Thermometer   ▁▂▃▅▇██████████████▇▇▇▇▇▇▇▇▇     12     11
  DoorEvent     ▁ ▃▁  ▆▂▁ █▃▁   ▂  ▅▁  ▁▃▁        4      1
                              ▲ point @1aba 12.0s
```

- **Buckets.** The terminal width minus the label and number columns, or fixed
  by `tumbling D`.
- **Summary.** For `#`, each bucket shows the maximum population in it by
  default, and `min` or `mean` picks another. `mean` is weighted by time. For
  `^`, each bucket is a count.
- **Glyphs.** Eight block heights, `▁` to `█`. A zero bucket is a space.
- **The marker line** shows where point falls.
- **Picking a bucket.** `@#N` moves point to the first position of bucket `N`,
  counted from 0 at the left edge. Every tenth bucket is numbered under the
  axis. (`@` and a bare number would read as a hex position.)

**`!.`, `!@N` and `!:`**

```
- !.
  cascade to @00001aba  12.0s   3 firings
  1  mark_occupied     tt 0x4f1   emit Occupied#140
  2  heat_warning      tt 0x4f2   (no fact or call recorded)
  3  evening_forecast  tt 0x4f3   call weather.get_forecasts as "fc-evening"  waiting
```

"No recorded effect" means the firing's actions are all of kinds a trace does
not record, such as `log` (§10.2). In a live session or hypothesis those are
captured and shown.

**`^.` and `^@N`** print one row per rule with its count in the cascade.

### 4.5 Navigation

| Line | Effect |
|---|---|
| `@1aba` | point to position `00001aba` |
| `@+10`, `@-10` | move by ten records; the count is decimal, because it is typed as a count, not copied from a listing |
| `@+500_ms`, `@-2_s` | move by clock time, to the first position at or after the target |
| `@12_s` | to the first position at or after that clock time |
| `@<`, `@>` | the start of time, before any record; the end of time. `@$` is an alias for `@>` |
| `n`, `p` | next or previous settled point |
| `n atom`, `p atom` | next or previous record |
| `n fire`, `p fire` | next or previous `RuleFireAnnotation` begin |
| `n tick`, `p tick` | next or previous `ClockAdvance` |
| `watch QUERY` | after every move, show the query's answers with `+` and `-` marks |
| `unwatch` | stop |
| `next change`, `prev change` | move to the next or previous position where the watched query's answer set changes |

**In a live `%0` at its end**, `@+D` with a duration advances the engine's mock
clock by `D` and pumps, and `n` pumps once without advancing it. A move by
positions past the end is refused.

### 4.6 The fact inspector

A row number drills into the row's first fact, or into its only fact.

```
- 1
  Thermometer#88  logical  asserted @0000011f 12.0s by the integrator
    entity_id    "kitchen"
    temperature  91.0
  withdrawn      not yet
  prior version  Thermometer#71, held 00000102..0000011f, superseded
```

| Command | Effect |
|---|---|
| row number | drill into the fact in that slot, when the slot holds a fact reference |
| `up` | back to what was inspected before |
| `<`, `>` | previous or next version of the same identity |
| `@[`, `@]` | point to where this fact was asserted, or where it was withdrawn: the brackets of its life |
| `why` | the fact's derivation tree (§4.14) |
| `match` | trace the fact through the matching network's alpha tests, where an engine holds it (§8) |

**Versions.** Two facts are versions of one identity when they are the same
logical schema and one's withdrawal has cause `SUPERSEDED` at the position where
the other was asserted. The key slots are not in the trace (§10.2), so identity
is read from the supersession, not from the slots.

**`match`** calls `rete_match_trace(fact_id)` on the engine that holds the fact at
point. That is the program engine in a live session or hypothesis. In replay it
builds the program engine to point first (§8.2).

### 4.7 Fact references

`#88` names fact 88 of the current timeline. In another timeline it is `%1#212`,
and every fact from a timeline other than the current one prints with its
prefix. A hypothesis continues its source's id counter, so the same number can
be different facts in different timelines.

### 4.8 Other timelines in a query

```
- ?.%2 Occupied o                  %2, at %2's point
- ?.%0 %1 Occupied o               compare %1 against %0
- #:%0 %1 %2 Occupied o            overlay populations
```

The first timeline named is the **baseline**. Rows are marked `+` when only in
the others and `-` when only in the baseline. Within a hypothesis a single named
timeline is compared against `%0`. Positions differ after a fork, so the
comparison aligns each timeline at the same **settled-point count since the
fork**, and histograms overlay on clock time.

Answers are matched across timelines by binding tuple. Facts in a tuple are
matched by fact id up to the fork and by schema and slot values after it.

### 4.9 Hypotheses

**Spelling (§4.16).** A change at point is written `from here …`:
`from here emit`, `from here withdraw`. `save` is `save trace`. The tables below
keep the short names for what the commands do.

| Command | Effect |
|---|---|
| `emit SCHEMA slot: value …` | assert a fact at point |
| `withdraw #N` | withdraw a live fact at point |
| `hyp` | list every timeline |
| `fg %N` | switch to timeline `N`, `%0` included |
| `real` | `fg %0` |
| `bg %N` | `%N` follows `%0`'s point (below) |
| `stop %N` | `%N` stays where it is, which is the default |
| `fork` | clone the current hypothesis at point into a new number |
| `kill %N` | close `%N` and free its engine |
| `%` | print the current timeline's name |
| `save %N PATH` | write `%N`'s record as a trace |

**Where a change applies.**

| Where point is | `emit`, `withdraw`, `answer`, `fail` |
|---|---|
| a live `%0`, at its end | apply to `%0` |
| a live `%0` behind its end, or replay `%0` | open a new hypothesis forked at point, and switch to it |
| a hypothesis at its end | add to it |
| a hypothesis behind its end | discard its records after point, apply, and recompute forward to where its end was |
| mid-cascade anywhere | refused, naming the settled points either side |

**`emit`** is compiled as the right-hand side of a one-off rule over the
program's schemas (§7.2), so its slot names and types are checked. It must not
say `logical`. The fact is an input, like an adapter's. Ambient and
adapter-published schemas are allowed.

**`withdraw #N`** retracts the fact. If it was rule-derived and its support
still holds, the engine may assert it again during the same pump. dstrace
reports that with the rule that did it.

**Stepping a hypothesis forward** (`n`) feeds it reality's next step (§3.3):
its inject records through the `PumpBoundary` that ends it, so the hypothesis
lands on a settled point as reality did. Two exceptions, each reported as a
note on the line where it happens:

- a recorded `FactRetract` of a fact this hypothesis has already withdrawn, or
  never had, is skipped;
- a recorded reply (§4.10) is delivered only if this hypothesis issued a call
  with that `corr` and has no reply to it yet (§5): a call waiting on it, or,
  for a `CallError`, one that does not wait.

**`bg`.** A background hypothesis is fed reality's steps whenever `%0`'s point
moves forward past its own position. It never moves backward.

**Prompt.**

```
-                          %0
[2 calls] -                %0 with two calls waiting
%1 @1aba +1-1 r1 a1 R1 ~   %1, forked at 00001aba: 1 emit, 1 withdraw, 1 reply
                           replaced (§4.10), 1 firing altered (§4.11), 1 rule changed (§4.12)
```

**`hyp`.**

```
- hyp
  %0  reality                  @00001aba   48.2 MiB
  %1  forked @00001aba  +1-1   @0000002c   stopped      48.9 MiB
  %2  forked @00000f10  r1     @00000f40   background   47.6 MiB
  total 144.7 MiB
```

Memory is the engine's `total_bytes` from `ds_engine_mem` (§11.1), plus the
size of dstrace's own record lists for that timeline. `%0` in replay without a
program engine shows only the record lists.

**`save`** writes the timeline's records as an RFCS stream, as recorded. For a
hypothesis it also prints the description -- the fork position, the source
trace's session id and each change -- and writes it nowhere: the stream carries
no annotation atom.

A live `%0` is recorded by its own engine as it runs (§8.4), so `save` copies
that recording: a canonical trace that verify-replays. Two conditions come with
any such recording, not with dstrace:

- **Start the replayer on the mock clock at 0.** A session's first inputs are
  asserted at mock clock 0, before any `ClockAdvance` is recorded, and
  libds's replayer switches to the mock clock only at the first `ClockAdvance`.
  A replay engine left on the live clock stamps those first facts with the
  wall clock and diverges at the first rule-emitted fact.
- **No service calls.** A stream carrying `CallIssued` atoms is not
  verify-replayable by design, since a bare replay engine cannot reproduce a
  call's host-side effects. Such a stream is read with apply-only replay.

### 4.10 Service calls

A **reply** is an integrator assert of a fact carrying a `corr` slot, the slot
the language gives the meaning "the correlation of the call that brought this
fact in". A response is a fact of the service's response schema;
a failure is a `CallError`.

A call is **waiting** at point when its service declares a response, it has a
`corr`, and no reply to it has arrived since: a fact of its response schema or
a `CallError`, with its `corr`. A call to a `no response` service, or one with
no `corr`, never waits; one with a `corr` can still be failed, since a
`no response` service may fail. A later call with the same `corr`
**supersedes** it ([LCRS], calls.md "When the reply expires"). Which schema a
service responds with is the program's; a trace does not record it.

- **The prompt** counts waiting calls.
- **A step that issues calls** prints one line per call, with its number.
- **`calls`** lists waiting calls: number, service, arguments, `corr`, rule,
  `timetag`, issue position, and time waited. `calls all` adds answered, failed,
  superseded and `no response` calls with their outcome. The arguments are one
  JSON object, as DSDB.md §9.1 writes them, less a fact argument's bytes.
- Numbers are per timeline, from 1, in issue order.

`answer`, `fail` and `silence` are written `from here answer`, `from here fail`
and `from here silence` (§4.16).

| Command | Effect |
|---|---|
| `answer N JSON` | assert a fact of the call's response schema: the JSON object's slots, typed as a JSONL row of it (DSDB.md §8), with the call's `corr` |
| `fail N code: "…" message: "…"` | assert `CallError corr: <call's corr> code: … message: … ts: <point's clock>` |
| `silence N` | on an answered call only: suppress its recorded reply (below) |

`answer` refuses a `corr` in its object, since the call gives it, and refuses
a call that does not wait: one to a `no response` service is failed or left
alone. Both commands print the `emit` they stand for. On a waiting call they
are an `emit` at point and follow §4.9's table.

**A program that never reads `CallError` cannot fail a call.** The engine
registers `CallError` only when some rule matches it. `fail` checks first and
says the program has no rule reading it. A response schema is declared by the
program, so it is always there.

**On an answered call**, `answer`, `fail` and `silence` replace the reply:

1. point moves to the settled point just before the recorded reply's
   `FactAssert`, and the shell says so;
2. a hypothesis forks there, with that record on its skip list;
3. the replacement is asserted, or nothing for `silence`.

### 4.11 Rule firings

`!` rows drill into a **firing**:

```
- 3
  evening_forecast  tt 0x4f3  cascade to @00001aba  12.0s
  matched   (not recorded in a trace; the provenance pass supplies it, §8.8)
  effects
    1  call weather.get_forecasts  entity_id="weather.home"  as "fc-evening"
         call 3, waiting
    2  emit ForecastRequested zone="home"
         ForecastRequested#141
```

**Effects** are every derived record carrying this firing's `(rule, timetag)` or
lying between its begin and end annotations. In a live session or hypothesis the
firing also has its **matched facts**, from the engine's `rule_lhs_facts` event,
and its uncaptured-in-traces effects: log lines and cache operations.

**Changing a firing.** Inside the firing inspector:

| Command | Hypothesis |
|---|---|
| `skip` | all of this firing's effects are dropped |
| `skip K` | effect `K` is dropped |
| `change K slot: value …` | effect `K` happens with these slots or arguments replaced |
| `add ACTION` | one more effect after the firing's last, written as a DS action |

Each moves point to the settled point before the firing's cascade, forks there,
and records the change keyed by `(rule, timetag)` and effect number. The fork is
deterministic up to that firing, so the same activation recurs with the same
identity. When it fires, dstrace applies the change in its callbacks (§8.5).
Only that activation changes. Changing a rule for every firing is a rule
hypothesis (§4.12).

### 4.12 Rule hypotheses

**Withdrawn.** A rule that exists only from some point on
has no meaning in DS and cannot be recorded in a trace, so a hypothesis no
longer changes the program: the program is edited for all time (§4.16), and
`rules` becomes `changes`. This section and §8.6 describe stage 6 as built,
until §4.16 replaces it.

A hypothesis may change the program itself: add a rule, redefine one, or
remove one, from point onward.

| Command | Hypothesis |
|---|---|
| a `rule NAME:` block with a new name | the rule exists from point on |
| a `rule NAME:` block with an existing name | the rule has this definition from point on |
| `unrule NAME` | the rule does not exist from point on |
| `rules` | list the current timeline's rule changes |
| `show rule NAME` | print the rule's source, as the timeline has it |

**Entering a rule.** A line starting `rule ` opens a block, and the prompt shows
`...` until a blank line closes it. The block is DS exactly as in a `.ds` file:
header, indented patterns, `->` at column 0, indented actions.

**Where it applies.** The same table as §4.9: at the end of a live `%0` it
changes `%0`; anywhere in recorded reality it opens a hypothesis; inside a
hypothesis it adds to it. Only at a settled point.

**What happens to logical facts.** A rule removed at point takes its
justifications with it, so the `logical` facts it alone supported are withdrawn
with cause `JUSTIFIER_ENDED` in the first cascade after point. A redefined rule
does the same for its old definition, and its new one derives afresh. This is
what "the rule stopped existing" means under truth maintenance, and the shell
reports each such withdrawal.

**The prompt** counts rule changes as `R`, as in `%3 @1aba R2 ~`. `hyp` lists
each changed rule by name.

**Requirements.** The program's source: embedded in the `.dsc` (§10.11), or,
for a `.dsc` built with `dsc --strip`, a `.ds` file given with `-L` (§2).
Without either, rule hypotheses are refused with that reason.
Building one replays from the start of the trace (§8.6), so the shell shows
progress, and the result is kept as a checkpoint chain like `%0`'s.

### 4.13 The Rete network at point

`rete` shows the matching network as it stands at point: every node, what it
holds, and how that changed since the previous settled point. A graph does not
fit a terminal, and does not need to. DS rules compile to left-deep chains, an
alpha node per pattern joined one pattern at a time down to the rule. So the
network is shown as one chain per rule, read top to bottom, with shared nodes
marked, not drawn twice.

```
- rete
  rete at @00001aba 12.0s · 4 alpha · 2 join · 3 rules · 10 facts held · 2 tokens

  rule entry_detected                                              fired 4 · pending 1
     1  α DoorEvent d     d.action == "opened"                       2 facts
     2  ∧ Motion m        m.entity_id == d.entity_id                 1 token        +1  ◀ α Motion  5 facts
     3  ¬ no Ack a        a.corr == d.corr                           1 token            ◀ α Ack     0 facts
     4  ▶ entry_detected                                             1 activation

  rule heat_warning                                              fired 2 · refracted 2
     5  α Thermometer t   t.temperature > 90.0  (also heat_log)      3 facts        -1
     6  ▶ heat_warning                                               0 activations

  rule heat_log                                                                fired 0
     7  α Thermometer t   t.temperature > 90.0  (also heat_warning)  3 facts        -1
     8  ▶ heat_log                                                   0 activations
```

| Glyph | Node | Count shown |
|---|---|---|
| `α` | alpha: the first pattern's schema and its single-fact tests | facts held |
| `∧` | join: the next pattern, and it holds too | tokens in its left memory |
| `¬` | negated join, for a `no` pattern | tokens in its left memory |
| `▶` | the rule's terminal | pending activations |

**Reading a chain.** Top to bottom, as the rule reads: "we have `d`; and
that `d` with an `m`; and no `a` for them; so the rule." Each row's count is
what **arrives from the rows above**: row 2's one token is one `d` waiting to
meet an `m`, not a `(d, m)` pair; the pairs that met are row 3's tokens, and
what passed every row is the `▶` row's activations. So a row's count is the
matches of every pattern above it. It is never the row's own output, which
libds does not report for the last join (its terminal counts only unfired
activations).

**Why `∧`.** A join is "and this pattern too", which is how a rule reads, and
`∧` beside `¬` says it in one vocabulary. The relational bowtie `⋈` is also
defensible, since a DS join is an inner join on the `where` that holds, but it
invites reading the network as a database query plan, which is not what the
view is for. `∧` also points up, at what it is fed.

- **Pattern text** on each line is the rule's own source pattern, from the
  `.dsc`'s embedded source (§10.11), split at its `where`. Join nodes carry no
  test text of their own (§10.12). The text is the source's even where the
  compiler moved part of a `where` into the alpha node: the view shows what
  the author wrote. `rete schemas` shows the alpha tests as libds has them.
- **The first pattern is its alpha node.** Its beta is a root, whose left
  memory holds only the nil token ([RDSC.4a.7]), so what it holds is its
  alpha's facts. A `no` first pattern is a `¬` row like any other.
- **`◀`** names the alpha memory feeding a join from the right, with its count.
- **`(also …)`** lists the other rules sharing an alpha node ([IRET.6.6]). A
  shared node is shown under each rule that uses it.
- **Changes.** `+N` or `-N` after a count is the change since the settled
  point before the one shown, at `rete @N` too. When the program differs
  between the two (a rule change came between), no changes are shown, and the
  view says so.
- **The rule header** shows how many times the rule has fired up to point,
  and its pending and refracted activations when they are not zero. Refracted
  is what libds reports for the current cycle, which every assert and retract
  restarts ([IRET.11.3.2]), so at a settled point it is usually zero.
- **The view's header** counts the whole network, and with a `/regex/` adds
  how many rules are shown.
- **Only at a settled point.** An engine exists only between pumps, so `rete`
  mid-cascade is refused with the settled points either side, as `match` and
  a fork are.
- **Patterns that do not line up.** When a rule's source patterns and its
  chain differ in number (a `then … within` sequence adds nodes, [IRET.7.10]),
  the chain is shown with each alpha node's own test text, and the rule's
  header says how many of each there were (§8.7 step 3).
- **Drilling in.** A row number opens the node's contents. An alpha node lists
  its facts, which open in the fact inspector. A join lists its tokens as
  binding tuples, as `?` lists answers. This needs a new accessor (§11.2);
  until it lands, a row says so.

| Command | Effect |
|---|---|
| `rete` | the network at point, by rule |
| `rete @N` | at position `N`, without moving point |
| `rete /regex/` | only rules whose names match; `rete @N /regex/` combines them |
| `rete schemas [@N]` | alpha-first: each schema's alpha nodes, their tests, facts held, and the rules consuming them |
| `rete dot FILE` | the whole network as Graphviz, with counts at point on the nodes, for when the real graph is wanted; a join's right input is drawn dashed |

`rete` in a hypothesis shows that hypothesis's engine. `rete %1` is not
supported: two networks side by side do not fit either.

### 4.14 Derivation trees

`why #N` prints, at point, everything that led fact `#N` to exist with the
values it has: the rule firing that emitted it, the facts that firing matched,
what emitted each of those, and so on down to the inputs. It answers the
question from the fact back, across the whole history before point.

```
- why #140
  Occupied#140  room="kitchen"        logical, live at @00001aba 12.0s
  │  emitted by: emit Occupied logical room: m.room
  ├─ 1  supported by mark_occupied  tt 0x4f1  fired @0000011f 11.9s
  │  └─ 2  m = Motion#120  room="kitchen" state="on"      ttl, @00000118 11.8s
  │     │  emitted by: emit Motion room: s.room state: s.state
  │     └─ 3  motion_in  tt 0x4e0  fired @00000118 11.8s
  │        ├─ 4  s = Sensor#88  entity_id="pir.kitchen" room="kitchen"
  │        │     input @00000117 11.8s
  │        └─    no (Suppress x where x.room == s.room)   held at 11.8s
  └─ 5  supported by mark_occupied  tt 0x4f7  fired @00000130 12.0s
     └─ 6  m = Motion#131  room="kitchen" state="on"      ttl, @0000012e 12.0s
        └─ 7  motion_in  tt 0x4f5  fired @0000012e 12.0s
           └─    s = Sensor#88   (see 4)
```

Node 7's binding repeats node 4, so it is printed once and referred to.

**What each node is:**

| Node | Shows |
|---|---|
| the fact | its slots, lifecycle, and whether it is live at point |
| `emitted by:` | the source line of the `emit` or `publish` that produced it, from the `.dsc`'s embedded source, with the rule's `let` lines when the values come through them |
| `supported by` | a firing: rule, `timetag`, and where it fired |
| a binding | `name = Schema#id` and the matched fact's slots, then that fact's own derivation beneath it |
| `input` | a fact the integrator asserted, a leaf |
| `no …` | a negated pattern as the source writes it, and that it held when the rule fired; absences bind nothing, so there is nothing to recurse into |
| `reply to call N` | a reply (§4.10), a response or a `CallError`, is an input, but its cause is the call it answers; the tree follows it to the firing that issued the call |

**Which firings count.** A `logical` fact is shown with every firing that
**supports it at point**: its current justifiers. There may be several, and
the tree shows each. A fact that is not truth-maintained is shown with the one
firing that emitted it.

**Values, not only existence.** For a logical fact that has been superseded,
the tree is for the version live at point, the one whose values are shown.
`<` in the tree moves to the prior version's tree, and says what changed.

**Keeping it finite.** The graph of causes is a DAG, and repeats. Every node is
numbered. A fact or firing already printed is shown once more as a one-line
reference to its number. `why #N depth D` stops after `D` firing levels, and
any row number expands its node. Leaves are inputs, absences and facts whose
cause is outside the trace.

**Facts gone by point.** A matched fact that has since been withdrawn is still
shown, marked with where and why it ended. It supported the firing when the
firing happened.

**Why it ended.** `why #N` on a fact that has ended by point also says what
ended it, under its `emitted by:` line. It follows what ended that, and so on,
back to what began the cascade it ended in:

```
- why #140
  Occupied#140  room="kitchen"   logical, ended @0000013a 71.9s JUSTIFIER_ENDED, not live at point
  │  emitted by: emit Occupied logical room: m.room
  │  ended: its support mark_occupied  tt 0x4f1 lost m = Motion#120
  │         → Motion#120 ended @0000013a 71.9s TTL_EXPIRED: its ttl ran out
  └─ 1  mark_occupied  tt 0x4f1  fired @0000011f 11.9s
     └─ …
```

| How it ended | `ended:` says | and follows |
|---|---|---|
| a `FactRetract` | retracted by the integrator | nothing: it is an input |
| `TTL_EXPIRED` | its ttl ran out | nothing: it is the clock |
| `SUPERSEDED` | replaced by the fact that took its place | nothing: `<` and `>` move between the versions |
| `AUTHOR_WITHDRAWN` | withdrawn by the firing whose `withdraw` it was | nothing: that firing has a tree of its own |
| `ACTIVATION_COMPLETED` | the activation that emitted it completed | nothing |
| `JUSTIFIER_ENDED` | the support it lost: the firing, and the fact it matched that ended in the same cascade; or the `no` pattern that began to match, and the fact that made it match | the lost fact's own end, the same way |

A `logical` fact's support there is its justifiers just before that cascade,
from an engine at the settled point the cascade began from. Where no engine can
say, it is every firing that emitted the fact. When nothing a supporting firing
matched ended in the cascade, and no absence began to match, `ended:` says
that the trace does not say how.

`why` also works from the fact inspector on the fact shown.

**An activation's tree.** `why` also takes an activation: why did this rule
fire, then, for these facts.

| Form | Activation |
|---|---|
| `why !3` | row 3 of the last `!` listing |
| `why entry_detected 4f1` | the firing of that rule with that `timetag` (hex) |
| `why` in the firing inspector | the firing shown |

```
- why !3
  entry_detected  tt 0x4f1  fired @0000011f 11.9s   (1st firing for these facts)
  │  triggered by: Motion#120 asserted @00000118, emitted by motion_in in this cascade,
  │                from input Sensor#88 @00000117
  ├─ 1  d = DoorEvent#101  action="opened" entity_id="front"     ttl, @000000f0 10.2s
  │  └─ 2  input @000000f0 10.2s
  ├─ 3  m = Motion#120  entity_id="front"                         ttl, @00000118 11.8s
  │  └─ 4  supported by motion_in  tt 0x4e0 …   (as in a fact's tree)
  ├─    no (Ack a where a.corr == d.entity_id)   held at 11.9s
  └─    DoorOpen d then Motion m within 30_s    d.ts 10.2s, m.ts 11.8s
```

The children are the same as a fact's firing node: each matched fact with its
own derivation, and each negated pattern. Three things are shown only here:

- **What triggered it then.** The input record that began the cascade the
  activation fired in. Where that input reached the rule through facts derived
  in the same cascade, the chain is shown from the input to the matched fact.
  If the cascade began with a withdrawal and the rule has a `no` pattern, the
  trigger is the absence that withdrawal created. If it began with a clock
  advance, the trigger is time: a `within` window, a `dwell` test or an
  `after` timer coming due.
- **Rule-level conditions**, each shown with the values it was judged on:
  - `cooldown`: when the rule last fired for this key and whether the window
    had passed;
  - `then … within`: each step's timestamp, beside the window from the source;
  - `hold`: the lock it took.
- **Refraction.** Whether this is the first firing for this combination of
  facts, or a re-firing because one of them changed, and which.

An activation that is **pending** at point gets
the same tree from the engine at point, marked pending, with what it is
waiting for. That needs an engine at point (§8.1).

**As built (dsdb, stage 8).**

- **Row numbers** expand a node into its own tree: a fact's number into the
  fact's tree, a firing's into its activation tree.
- **Mid-cascade**, no engine exists to ask (§3.3: a pump runs to exhaustion,
  and libds refuses calls from inside one), so each fact is shown with every
  firing that derived it up to point: its first `FactEmit` and each re-emit
  that coalesced with it (§10.13 check 2). A trace does not record one
  justification ending while others hold, so a support lost within the
  cascade cannot be seen, and the tree says so.
- **The trigger** prints the cascade's input, then one line per firing between
  it and this one: `→ Motion#120, emitted by motion_in in this cascade`.
- **`cooldown`** shows the rule's previous firing and whether the window had
  passed. The key the window is per is not in the trace or the metadata, so
  it is the rule's previous firing, not the key's.
- **`hold`** is not shown: it is not a rule modifier in the grammar
  ([LGRA.6.1]).
- **Not built yet:**
  - a pending activation's tree, which needs the terminal's contents (§11.2);
  - `<` in a tree.

### 4.15 Other commands, and an index

| Command | Effect |
|---|---|
| `list [K]` | the plain `dstrace` listing of `K` records either side of point, default 10 |
| `help [WORD]` | this section's tables, or one command's |
| `quit`, end of input | leave |

**Every command, by where it is specified:**

| Commands | § |
|---|---|
| `?` `#` `!` `^` with `.` `:` `@N` | 4.3, 4.4 |
| `@…`, `n`, `p`, `watch`, `unwatch`, `next change`, `prev change` | 4.5 |
| row numbers, `up`, `<`, `>`, `@[`, `@]`, `match` | 4.6 |
| `from here emit`, `from here withdraw`, `hyp`, `fg`, `real`, `bg`, `stop`, `fork`, `kill`, `%`, `save trace` | 4.9 |
| `calls`, `from here answer`, `from here fail`, `from here silence` | 4.10 |
| `skip`, `change`, `add` (in the firing inspector) | 4.11 |
| `show rule` (rule hypotheses withdrawn, §4.16) | 4.12 |
| `rete`, `rete schemas`, `rete dot` | 4.13 |
| `why` | 4.14 |
| `list`, `help`, `quit` | 4.15 |
| definition blocks, `del`, `ls`, `mv`, `save code`, `save trace`, `changes`, `from here …` | 4.16 |

### 4.16 Editing the program: a REPL

**Built in dsdb** (`lib/core/program-text.js`,
`lib/core/edit.js`; tests `edit.test.mjs`, `live.test.mjs`, `mcp.test.mjs`).
The shell edits the program itself,
by its structure, and every timeline follows. The loop it serves: write some
DS, run it, look, change it, run it again, and when it behaves, save the
program to a file. The same commands back the MCP server's tools
(`DSDB_MCP.md`).

**Two kinds of change, told apart by a marker.**

| Kind | Marker | Commands | What it does |
|---|---|---|---|
| **all time** | none | a definition block, `del`, `mv` | changes the program; every timeline is rebuilt under it from the start |
| **from here** | `from here` | `from here emit`, `from here withdraw`, `from here answer`, `from here fail`, `from here silence` | changes one timeline's **inputs** at point, as §4.9 and §4.10 say: at a live `%0`'s end it applies to `%0`, elsewhere it opens or extends a hypothesis |

**The program is only ever changed for all time.** A DS
program has no "from this point on": a rule that exists after some point, or
before, or between two, means nothing in the language, and no trace can
record it. So §4.12's rule hypotheses and §8.6's gates are withdrawn. A
hypothesis is a different set of inputs, never a different program.

**From any point.** `from` takes a point, and `here` and
`start` are two names for one:

```
from here  WORD …     at point
from start WORD …     at the start of time, before the first input (as from @<)
from @1def WORD …     at that point: a position (@1def, @1def-), @<, @>, or a clock (@12_s)
```

`from @N WORD …` is `@N` then `from here WORD …`: point moves there, which
must be a settled point, and the change lands as §4.9's table says (at a live
`%0`'s end it applies to `%0`; elsewhere it opens or extends a hypothesis).
It holds for all five words.

- **`from start emit Schema …`** adds an input before the first one, as a DS
  top-level `emit` would be asserted before the first pump.
- **`withdraw #N` where `#N` is not yet asserted** means its input never
  happens: the hypothesis forks at the settled point just before that input,
  with the input on its skip list, as a replaced reply's is (§4.10), so the
  fact and everything it caused are gone. `from start withdraw #N` is this.
  Only a fact the integrator or an adapter asserted (a reply included) can be
  withdrawn so; a rule-derived one is refused, naming the rule. Where `#N` is
  live at the point, `withdraw` retracts it there, after its effects so far.

`changes` lists each change with the point it was made at.

The `from here` spellings replace §4.9's `emit` and `withdraw` and §4.10's
`answer`, `fail` and `silence`. A bare `emit` is left unused on purpose: a
top-level `emit` in DS, asserted before the first pump, is proposed for the
language, and typed as a definition block it would be an all-time edit like
any other. `skip`, `change` and `add` in the firing inspector (§4.11) keep
their names: they change one activation, which the inspector already names.

**A definition block.** A line at the prompt that starts a DS top-level
declaration (`schema`, `rule`, `service`, `series`, `use`, `import`, a
constant) opens a block. The prompt shows `...` until **two blank lines** end
it, so a single blank line inside a definition is part of it. A block is **one
definition**: two are refused, so each block edits exactly one thing.

- A new name adds the definition.
- An existing name replaces it. A replaced rule keeps its place in the rule
  order; a new rule goes last.
- The edit is **all or nothing**: the program with it is staged, compiled and
  replayed. If the compiler refuses, the program is unchanged, and the message's
  line numbers point into the block.

```
- schema Reading scope logical:
...     entity_id: String key
...     level: Float mutable
...
...
  + schema Reading · replayed 0 inputs
- rule hot:
...     Reading r where r.level > 80.0
... ->
...     emit Hot logical entity_id: r.entity_id
...
...
  + rule hot · replayed 3 inputs · Hot#4 new
```

**`del`.** `del NAME` removes the definition called `NAME`: a rule, schema,
service or series. `del use` removes the `use` line, and `del import PATH` an
import. DS keeps schemas and rules in separate namespaces, so where a name is
both, `del` asks for `del schema NAME` or `del rule NAME`. Removing a schema a
rule still reads is the compiler's to refuse.

**Order.** DS has one order for everything but rules, and dsdb keeps it:
`use`, imports, schemas, services, series, then rules. Rule order is behaviour
(ready rules fire in source order), so it is the user's:

```
- ls rules
    1  hot        Reading r where r.level > 80.0      fired 2
    2  alarm      Reading r where r.level > 90.0      fired 1
    3  answered   FooReply c                           fired 1
- mv alarm 1
  alarm moved to 1 · replayed 11 inputs · no change
```

`mv RULE N`, `mv RULE before OTHER` and `mv RULE after OTHER` move a rule. A
move is an all-time edit, replayed like any other. `ls` alone lists every
definition by kind; `ls schemas`, `ls services`, `ls series` and `ls rules`
narrow it. `ls rules` shows each rule's first pattern and how often it fired on
the current timeline.

**What an all-time edit does to the session.** The program changes for every
timeline:

- **`%0`** is rebuilt by replaying its inputs from the start: a live session's
  own, or a trace's. In replay, the recording stays as the reference the
  behaviour diff and the self-check (§8.2) compare against.
- **Each hypothesis** is rebuilt the plain way: the new `%0` is forked at the
  same position, and its `changes` are made again, each at its recorded
  position. Positions keep their meaning; after an edit they name points in
  the new timeline, where things may happen at other times and in another
  order. Where a position no longer exists, or is no longer settled, the change
  is made at the nearest settled point before it, and the shell says so. A
  change that no longer applies (an `emit` into a schema that no longer fits, a
  reply to a call no longer made) stops the rebuild there; the hypothesis is
  marked halted, and the shell says which change.
- **A point at a timeline's end stays at its end.** Any other point keeps its
  position, which may now name another moment: an added rule writes more
  records per input, so the same position comes earlier in the run.
- **Points the user was following** are theirs to find again: an edit changes
  the whole timeline. A helper that maps old points to new ones could come
  later, on top of this.
- **Inputs that no longer apply** to the new program (their schema removed, or
  its slots changed) are skipped and listed.
- **The answer to "what did my edit do"** is the behaviour diff of the current
  timeline against itself before the edit: facts and firings that appeared,
  disappeared or differ, in the form of a cross-timeline comparison (§4.8).

**`changes`** lists the current timeline's from-here changes, in the order
they were made, each at its point. It replaces §4.12's `rules`, which listed
only rule changes:

```
- changes
  1  from here emit Reading entity_id: "c" level: 99.0    @00000012
  2  from here answer 1 {"ok": false}                     @00000018   replaces the recorded reply
  3  from here withdraw #7                                 @0000001a
```

**Saving.**

- **`save code FILE`** writes the program as it now stands, as **one file**, in
  the order above, each definition's text as it was entered, comments
  included. It is a reloadable record of the work: `ds FILE` opens it again.
  How it is split into files afterwards is the author's business.
- **`save trace [%N] FILE`** is §4.9's `save`: the timeline's record as a
  trace. `save FILE` stays as its old spelling.

**Starting empty.** `ds` with no program opens a live session on an empty
program, to be built up block by block. Starting from a `.ds` or a `.dsc` with
its source loads that source as the first definitions.

**How it is built** (sketch). The program is an ordered list of named
definitions, found by their column-0 headers as `rules.js` already finds rule
blocks; nothing reads DS beyond that, and the compiler judges every edit. An
edit stages the list as one file, compiles it through the `compileFiles` port,
and replays each timeline's inputs through a program engine, as a rule
change's replay does today. Building it retires stage 6's gates (§8.6); the
replay and the self-check stay.

---

## 5. Calls in replay, live and hypotheses

| Where | Where calls come from | Where replies come from |
|---|---|---|
| replay `%0` | `CallIssued` records | recorded `FactAssert`s of replies (§4.10): response facts and `CallError`s |
| live `%0` | dstrace's call callback | `answer` and `fail` only |
| hypothesis | dstrace's call callback | recorded replies that match a call it made (§4.9), plus `answer` and `fail` |

A call left unanswered is a model too. Advancing the clock lets the program's
own absence patterns, such as `no ForecastReply r where r.corr == "fc" within
1_h`, fire. dstrace shows how long a call has waited, never a deadline.

---

## 6. Errors

| Condition | Behaviour |
|---|---|
| compile error in a query or `emit` | the compiler's message, its line numbers shifted to count from the query's first line; nothing else changes |
| query uses a construct the query engine cannot evaluate (a `call`-dependent pattern with no calls, say) | answered as the engine answers; dstrace does not second-guess |
| trace ends in a partial record | treated as end of stream ([RFCS.19.2]); with `-f`, read again later; the listing without `-f` names its offset on stderr and exits 0 |
| malformed record | the shell reports its byte offset and stays usable up to the last good record; with `-f`, nothing past it is read |
| a file that is not a trace or `.dsc` at all | exit 4 (§2) |
| a retract or withdraw of an unknown fact id in reality | kept as a record, counted in `#` output as "unmatched", never taken below zero |
| an engine halts (`EngineError`) | the timeline is marked halted at that position; its engine refuses further steps; queries over its records still work |
| hypothesis self-check fails (§8.2) | every prompt on replay hypotheses shows `unreliable`, and `hyp` says why |

---

## 7. Queries: how they are built

### 7.1 Declarations from the `.dsc`

dstrace reads the `.dsc`'s atoms with the generated bindings pyds ships, and
writes a DS declaration per schema (the shell's `program.py`):

```ds
schema Thermometer scope logical:
    entity_id: String key
    temperature: Float mutable tolerance 0.5
```

This needs, per schema, scope and TTL, and per slot, kind, key or mutable role,
nullability, tolerance, fact-reference target, and `sampled` or `retained`.
The artefact has all of it: `SchemaDef` and `Slot` for the shape, including
every slot field; `SchemaLogical` for logical and its `ambient` flag;
`SchemaTtl` for the duration; `DialectInfo` and `CapabilityInfo` for the `use`
line. pyds's `Schema` object exposes less, so this reads the atoms instead, and
**no pyds change is needed**.

Engine-provided schemas are not written out, since the compiler already knows
them: `CallError`, `HydrationComplete` and `HydratedSample`
(`_BUILTIN_SCHEMAS` in the compiler), and every `$`-named synthetic schema
([LLEX.10.6.1]), which no author name can be. A
program's `activation` schemas carry no distinguishing atom and are declared
`explicit`, which a query does not notice.

**An explicit schema looks logical in the artefact.** A schema written with no
`scope` gets the same `SchemaLogical` atom a logical one does. A logical schema
marks every slot key or mutable, so one whose slots carry no role at all is
explicit, and is declared with no scope. The round-trip test found this.

**Generated names avoid the reserved value names too.** `p1`, `p2` and so on
are reserved as percentile names ([LGRA.22.7]), so projection variables are
`col_1`, `col_2`.

The tests check the round trip: declarations generated from a `.dsc`, compiled
and read back, give the same schemas.

### 7.2 A query is a rule

For query `?.Thermometer t where t.temperature > 85.0`, dstrace compiles:

```ds
use default
# declarations from §7.1

schema QH7 scope logical:
    t: Thermometer key

rule q7:
    Thermometer t where t.temperature > 85.0
->
    emit QH7 logical t: t
```

- **One hit schema per query**, with one fact-reference `key` slot per binding.
  Each distinct binding tuple is then a distinct hit fact, and truth maintenance
  keeps it alive exactly while that tuple matches. A query with no positive
  pattern, such as `no (Hot h where h.level > 90.0)`, gets one constant key
  slot, so its single hit means "true now". DS refuses a binding that is never
  used, so a bare `no Hot h` is not a query.
- **Names.** `QH<n>` and `q<n>` with `n` counting up per session, lengthened
  while they collide with a program schema name. The query program holds none
  of the program's rules, so rule names cannot collide.
- **Bindings and their schemas.** The hit schema needs each positive pattern's
  schema and binding. dstrace reads the pattern HEADS, `[latest] [lib;]Schema
  binding`, at the start of each pattern line and after each `then`, and skips
  lines starting `no`. It reads no expressions. The compiler then validates the
  whole rule, and the binding names read are checked against the ones the
  compiler reports in the rule's display-name template (DNAM, [RDSC.6.8]), in
  order. On any difference the query is refused with a request to write one
  pattern per line in a bracket block, never guessed through.
- **Projection.** `-> a, b` adds `let col_1 = a` and `let col_2 = b`, and one
  more action, `log debug "{col_1}\x1f{col_2}"`. The log line reaches dstrace's log
  callback with the engine's own rendering of each value, split on the unit
  separator. No slot types are needed. Values are as of the firing that began
  the match. A value that changes without a new match, such as `dwell`, is
  therefore shown as it was then. A `Time` value
  cannot be interpolated today, so projecting one is a compile error
  until that is fixed.
- **Compilation** is `pyds.compile(source, file="<query>")`. Line and column
  are mapped back by subtracting the generated prefix.

**An `emit` typed at the prompt** is evaluated the same way, by an engine. dstrace
compiles a scratch program of the declarations, a one-slot trigger schema, and
`rule e<n>: E<n>Trigger x -> <the emit line>`. It loads that into a scratch
engine, asserts the trigger, pumps, and reads the emitted fact's schema and
slots with `fact_inspect()` in the `action_emit` callback. It then asserts those
values into the target engine with `assert_with_ttl`. The compiler checks the
slot names and types. The engine computes the values.

### 7.3 The query engine

One query engine per timeline and query. It holds the generated program: the
declarations, the hit schema and the query rule, and none of the program's
rules. dstrace drives it through the public pyds API, record by record:

| Record | Applied as |
|---|---|
| before the first record | `clock_set_mode("mock")` |
| any with `clock_ns` later than the engine's clock | `clock_set(clock_ns)` first |
| `FactAssert`, `FactEmit` | `h = assert_with_ttl(schema, ttl_ns, **slots)`; map trace id to `h` |
| `FactRetract`, `FactWithdraw` | `retract(h)` if the fact is still live; otherwise nothing |
| `ClockAdvance` | `clock_set(clock_ns)` |
| others | nothing |

After each record that changed state, dstrace calls `pump()`. That fires the
query rule and runs the engine's own TTL sweep. The sweep expires facts at the
deadlines the recording had, because each fact's deadline is its assertion clock
plus its recorded TTL window. A later recorded `FactWithdraw` of an
already-expired fact is then a no-op. Logical supersession happens inside the
assert, so a recorded `SUPERSEDED` withdrawal is likewise a no-op.

**Mid-cascade, the two can differ by one record.** The query engine withdraws a
superseded fact at the new fact's assert, while the recording may list the
withdrawal one record later. At settled points they agree, and the tests check
every settled point against the recorded facts. A fact whose schema no rule in
the query program reads is not registered there and is skipped, and so is a
fact the trace could not type. The shell reports how many were skipped.

Liveness is tracked by trace id from the callback, where a handle is valid. A
handle kept outside the callback may point at a fact the sweep freed, so
dstrace never asks one anything after its fact may have gone.

This does **not** use libds's replay context. Its apply-only mode never applies
`FactWithdraw`, so rule-derived facts would never leave (§10.3).

### 7.4 Reading answers out

The query engine's stream callback sees, for each new match:

1. `rule_lhs_facts` for `q<n>`: the matched facts' handles, whose `fact_id()`
   dstrace maps back to trace ids;
2. `rule_fire_begin`;
3. `action_emit` of the hit fact;
4. `rule_fire_end`.

It records `answer(hit id) = (binding tuple, start = current record index)`. A
later `fact_retract` event for that hit's handle sets `end`. The **answer
timeline** is that list. Projected values come from the firing's `action_log`
event (§7.2).

### 7.5 Caching and cost

- **Cache key:** the query's text, normalised for spacing, and the timeline.
- **`?.`, `#.` and `?@N`** evaluate only up to the needed position, and resume
  from there later.
- **`?:` and `#:`** evaluate to the end.
- **With `-f`,** new records are fed to every cached query engine.
- **Cost:** one compile per new query, then one pump per state-changing record.
  A hypothesis invalidates only its own cached answers after the change point.

### 7.6 The no-query forms

`#` with no query, `!` and `^` need no engine. They read the timeline's records:

- **Population:** each `FactAssert` or `FactEmit` starts a fact. Its
  `FactRetract` or `FactWithdraw` ends it.
- **Firings:** each `RuleFireAnnotation` begin, paired with its end by
  `(rule, timetag)`.
- **Effects:** every derived record between a firing's begin and end.

---

## 8. Engines

### 8.1 Which engines exist

| Engine | Program | Exists when |
|---|---|---|
| query engine | generated (§7.2) | a query has been asked of a timeline |
| program engine for `%0` | the real `.dsc` | always in live mode; in replay, once a hypothesis, `match`, `rete` or the provenance pass (§8.8) needs it |
| one per hypothesis | a clone | while the hypothesis is open |
| checkpoints | clones | while the `%0` program engine exists |

### 8.2 The program engine in replay

Built by: `Engine()`, `load_dsc(dsc)`, `clock_set_mode("mock")`, then for each
**inject** record in order, as libds's replayer does (§10.3):

| Record | Then |
|---|---|
| `ClockAdvance` | set the monotonic clock to `clock_ns`, and the wall clock to `wall_ns` when it has one |
| `FactAssert` | `assert_with_ttl(schema, ttl_ns, **slots)` |
| `FactRetract` | `retract(h)` if live |
| `PumpBoundary` | `pump()` |

The engine pumps where the trace says it pumped, and nowhere else. A
`ClockAdvance` whose sample has no wall clock leaves an earlier wall time in
place: libds's replayer unsets it, and `libds.h` has no call that does.

Derived records are not fed. The engine re-derives them. The first time the
program engine is built, dstrace checks it: its `action_emit` fact ids and
schemas, `rule_fire_begin` `(rule, timetag)` pairs and `action_call`
`(timetag, corr)` must equal the recorded `FactEmit`, `RuleFireAnnotation` and
`CallIssued` records, in order, up to point. On the first difference the timeline
is marked unreliable (§6) at that position.

**Checkpoints.** Every 256 steps, at the settled point that begins one, and at
each fork, dstrace keeps a
`clone()`. Moving the program engine back to point restores the latest
checkpoint at or before it and replays forward.

### 8.3 Forking

`h = checkpoint_or_program_engine.clone()` at the settled point, then register
dstrace's callbacks on `h` ([NLFC.8.3]: a clone has none). Then apply the
change and `pump()`.

### 8.4 Building a timeline from an engine

For a live `%0` and every hypothesis, the engine records itself and dstrace
reads the recording back as it is written:

- **The records are the engine's own recording.** dstrace calls
  `record_to(path, flush=True)` on the engine. After every input it reads the
  atoms written since with the same decoder a recorded trace goes through
  (§3.1). So a live timeline holds exactly what a recording of the session
  holds: the engine's own withdrawal causes, TTL windows and event ids.
- **The callback adds what a trace does not hold.** dstrace's stream callback
  runs alongside the recorder (pyds RECTEE1, §11.1). It keeps each firing's
  matched facts from `rule_lhs_facts` and its log lines, and attaches them to the
  firing's begin record, and a call's fact arguments' FactExternal bytes, which
  a trace holds decoded, to its `CallIssued` record. It also keeps the handle of
  every live fact, which is how `withdraw #N` finds the fact to retract. Cache
  operations would be attached the same way.

For each event, the recorder writes the atom first, then the callback runs, so
nothing the callback sees is ahead of the file.

### 8.5 Applying firing changes in callbacks

dstrace tracks the current firing from `rule_fire_begin` and `rule_fire_end`.
While a changed firing is current:

- a **call, log, cache or record-event** callback for a skipped effect does
  nothing, and the record marks it skipped; a changed one is recorded, and
  treated as waiting or cached, with the replaced arguments;
- an **emit or publish** cannot be changed this way. **Open, not built.**
  libds's `emit_cb` runs after the fact is asserted: `emit Out` lowers to an
  `ACTION_ASSERT` that the Rete terminal executes with `ds_rete_wm_assert`
  itself (`rete/engine.c`), and only then calls `emit_cb` and
  `emit_action_cb`. By the time any callback sees an emit, the fact is in
  working memory and has propagated to the agenda. Dropping or altering one
  needs either a pre-assert hook in libds on that terminal path, or retracting
  the fact from inside the callback, which re-creates negated-pattern
  activations with new timetags and cannot undo a logical emit that merged
  into an existing fact. Stage 5 answers `skip`, `change` and `add` with this
  reason. **Deferred** until stages 6 to 8 are built.
  *Decided: a pre-assert hook in libds*, on the Rete
  terminal's path before `ds_rete_wm_assert`, through which dsdb drops or
  replaces an emit; the only exact one of the three. It is libds's change,
  and the bindings take it up. Until it lands dsdb
  refuses as above. Considered and not chosen:
  - retracting from inside the callback, wrong where a negated pattern's
    activations come back with new timetags, or an emit merged into a fact
    already there;
  - leaving emits unchangeable, an all-time edit of the rule (§4.16) being the
    only way;
  - a rule hypothesis scoped to the one activation, which needs a gate that
    names the matched facts through a fact-reference slot, and such a slot
    cannot be recorded;
- an **added** effect is performed when the firing ends: dstrace makes the
  call, logs the line or asserts the fact itself.

### 8.6 Rule hypotheses: a recompiled program

**Withdrawn with §4.12.** What follows describes stage 6
as built, until §4.16 replaces it. Its replay of a timeline's inputs under a
recompiled program is what §4.16 keeps; the gates go.

A clone copies an engine's state but not a different rule set, so a rule
hypothesis is a new program, replayed.

Built in stage 6 (the shell's `rules.py`):

1. **The source.** dstrace reads every `DsSource` atom of the `.dsc`, one per
   source file, and stages them in a directory. The first is the entry file.
   For a stripped `.dsc` it stages the checked `.ds` file given instead, and
   compiles with the `-L` directories on the search path (§2).
2. **Where each rule is.** From the compiler's own source location for it,
   `RuleMeta.src_file` and `src_line` (the SRCR atom), checked against the
   text. The header line naming it is the fallback, for a stripped `.dsc`.
   Nothing reads a pattern or an expression.
3. **One gate per change.** Change `n` appends
   `schema DstraceGate<n> scope logical:` with one key slot `gate` to the
   entry file. (`on` would read better, but it is a reserved word,
   [LLEX.9.5].) Then:
   - an **added rule** is appended to the entry file, with
     `DstraceGate<n> g where g.gate == <n>` as its **last** pattern, so it
     cannot activate until the gate fact exists;
   - a **removed rule** gains `no DstraceGate<n> g where g.gate == <n>` as its
     last pattern, so it stops matching when the gate fact appears;
   - a **redefinition** is both: whatever stood for the rule is gated off,
     and the new text is gated on under the generated name
     `<rule>__dstrace<n>`. Its records are shown under the original name.

   The gate is the last pattern, on its own line just before the `->` at
   column 0. That keeps it after a header's rate modifiers and any docstring,
   and leaves the order of the other patterns alone. A redefinition is placed
   **directly after** the rule it replaces, because ready rules fire in
   source order; an added rule goes at the end.
4. **Compile** with `pyds.compile_file`, the search path being the staging
   directory followed by any `-L` directories. A compile error is shown with
   the staged file named by its own name, and nothing changes.
5. **Replay** the timeline's own inject records into a fresh engine with the
   new program, as §8.2 applies them, up to point. Every earlier
   change's gate fact is itself an inject record in the timeline, so the
   replay reproduces each earlier change at its point. Nothing is re-applied
   by hand, and a second change in a hypothesis is just a longer replay.
6. **Check** this engine against the timeline up to point, as §8.2's
   self-check does, but on fact ids, schemas, rule names and withdrawals. It
   skips `timetag`, because the gates' extra network may number activations
   differently while behaving identically. A difference marks the hypothesis
   unreliable (§6). The stage 6 tests check this holds on the shared
   recording, with a program that gates a redefinition, a removal and an
   added rule.
7. **Place it, and assert the gate fact.** The same table as §4.9: at the
   end of a live `%0` the new engine becomes `%0`'s; in recorded reality a
   hypothesis forks; in a hypothesis, the hypothesis continues from point with
   the new engine, its records after point discarded and reality fed again up
   to where its end was. Then the gate fact is asserted as an input and the
   engine pumped. Each `logical` fact the old rule alone supported is
   withdrawn with cause `JUSTIFIER_ENDED` in that cascade, and the shell lists
   them.

**What the gate does when it arrives: working memory is kept.** A change
means "the program is different from here on, over the same working memory".
So an added or redefined rule activates for every tuple matching at that
moment, as a rule loaded into a running engine would. A new rule has never
fired, so refraction does not hold it back. For a redefinition this includes
tuples the old text already fired for, whose calls and TTL facts are made
again, and the shell shows them in the cascade after point. The gate is never
retracted, so a rule gated off stays off.

### 8.7 Reading the network

`rete` needs an engine at point: the live `%0`, a hypothesis's engine, or in
replay the program engine moved to point by its checkpoints (§8.2).

1. **Nodes and edges.** `rete_network(None, include_occupancy=True)` on that
   engine, for the whole network. dstrace walks the edges itself and does not
   use the `rule_filter` argument, which misses a multi-pattern rule's upstream
   alpha nodes and never filters joins (§10.12).
2. **Chains.** From each terminal, follow edges upstream to rebuild the rule's
   left-deep chain, alpha node by alpha node. A node reached from more than one
   terminal is shared.
3. **Pattern text.** The rule's source comes from the `.dsc`'s `DsSource` atoms,
   located by its `SRCR` line. Its pattern lines are matched to the chain's
   positions in order. If the counts differ, the chain is shown with alpha test
   text only, and the header says the patterns could not be lined up.
4. **Rule counts.** Fired comes from the timeline's firings up to point. Pending
   is the terminal's count. Refracted comes from `refracted_activations()`.
5. **Changes.** The same reading at the previous settled point, from the
   checkpoint chain or a clone kept while stepping, subtracted node by node.
6. **Contents.** For a drilled node, the new accessor of §11.2.

### 8.8 Provenance

A derivation tree needs, for every firing, the facts it matched. A trace does
not record them (§10.2). The engine reports them as `rule_lhs_facts`,
immediately before each `rule_fire_begin`.

- **In a live session or a hypothesis** the timeline already keeps each
  firing's matched facts (§8.4).
- **In replay**, the first `why` runs a **provenance pass**: a program engine
  replays the trace's inputs from the start (§8.2) with a stream callback that
  records, for each firing `(rule, timetag)`, its matched fact ids in pattern
  order. Stage 0 check 5 established that this engine's fact ids and firing
  identities equal the trace's, so the index joins straight onto the
  timeline's firings. The pass runs once, to the end of the trace, and every
  later `why` at any point is a lookup. With `-f` it extends as records arrive.

Then, for a fact at point:

1. **Its firings.** For a `logical` fact, `get_justifiers(fact_id)` on an
   engine at point gives the activations supporting it: `(timetag, rule)`.
   That needs the program engine at point, which the checkpoints give (§8.2).
   For any other fact, the firing whose effects include its `FactEmit` (§7.6).
2. **Each firing's matched facts**, from the provenance index, joined to the
   timeline's fact table for slots and lives.
3. **Recurse** on each matched fact that a rule emitted. A fact the integrator
   asserted is a leaf, except a reply (§4.10), whose `corr` leads to its call
   and so to the firing that issued it.
4. **Source lines.** The emitting rule's source, from `DsSource` and the rule's
   `SRCR` line, gives the `emit` line for the fact's schema and any `let`
   lines. Negated patterns come from the same source: every line of the
   rule's left-hand side starting `no`.

**For an activation**, the root is the firing itself, and three more readings
are made:

5. **Trigger.** The cascade the firing sits in (§3.3) begins with one input
   record. Walking the timeline's firings inside that cascade back from this
   one, through each matched fact that was emitted in the same cascade, gives
   the chain from the input to this firing. A cascade begun by a `FactRetract`
   or `FactWithdraw`, feeding a rule with a `no` pattern, is reported as the
   absence it created. One begun by a `ClockAdvance` is reported as time.
6. **Rule conditions.** Cooldown windows come from the rule's
   metadata (`rule_meta_find`: `cool_window_ns`). The previous
   firing for the same facts comes from the provenance index. `then … within`
   timestamps are the matched facts' `ts` slots, shown beside the source's
   window, not re-evaluated. A `hold` lock is read from the rule's source.
7. **Refraction.** The previous firing of the same rule over the same matched
   fact ids, from the provenance index. None means first firing. A previous one
   with a matched fact since superseded means a re-firing on that change.

**Without the program engine** (a stripped or unreplayable trace, §6), `why`
still prints each fact's emitting firing from the trace alone, with "matched
facts not recorded" in place of the bindings. Recording bindings would
make the trace alone enough.

---

## 9. Code layout and tests

**Layout.** The Python `dstrace` kept its CLI and handed `-i` to its shell
package:

| Module | Contents | Stage |
|---|---|---|
| `records.py` | decode a trace to records, incrementally; later, build records from callback events | 1, 4 |
| `timeline.py` | anchors and names, settled points, clocks, facts and their versions, population, cascades, firings, calls | 1 |
| `commands.py` | the line grammar of §4.2 | 2 |
| `render.py` | listings, shared-scale bars, histograms, the inspectors | 2 |
| `shell.py` | the loop, prompt, bracket blocks, entry point and binding check | 2 |
| `program.py` | declarations and embedded source read from a `.dsc` (§7.1) | 3 |
| `query.py` | query compilation, query engines, answer timelines, the cache | 3 |
| `engines.py` | engine-backed timelines (live and hypotheses), the program engine, checkpoints, clones, callbacks | 4, 5 |
| `hypotheses.py` | a hypothesis's state: fork, reality cursor, fact-id map, skip list, changes; following reality | 5 |
| `rules.py` | rule hypotheses: staging, gating, recompiling (§8.6) | 6 |
| `rete.py` | reading and laying out the network (§8.7) | 7 |
| `provenance.py` | the provenance pass and derivation trees (§8.8) | 8 |

**Tests**, in the shell package's `tests/`, ran in the pyds lane. dstrace
targets the Mercury compiler, which is the compiler `pyds.compile` runs.

- **One shared recording** (`conftest.py`): integrator asserts, rule emits, a
  TTL expiry, a supersession, a justification ending, a call and its reply, and
  an integrator retract.
- **The recording is the reference.** Timeline counts must equal the live facts at
  every point. Query answers must equal the recorded facts that satisfy the
  query, at every settled point, for a filter, a join and an absence.
- **Codec.** The C recorder's `FactEmit`, `FactWithdraw` and `CallIssued`
  atoms must re-encode byte for byte in Python
  (`bindings/python/tests/test_rfcs_femt_fwth_call.py`).
- **Grammar.** Every §4.2 form parses as specified, hex versus duration both
  ways.
- **The shell** is driven line by line, and the entry point is run with a
  good `.dsc`, a wrong one, none, and a self-contained trace.
- **Declarations** round-trip: generated from a `.dsc`, compiled, and read
  back, they give the same schemas.
- **To come.** A hypothesis with no changes, stepped to the end, must
  reproduce `%0`'s derived records exactly (stage 5). Each stage's unverified
  claims (§10.11, §10.13) become tests the way stage 0's did.

---

## 10. Research: the questions and their answers

### 10.1 Which facts a trace records, and how

From the C recorder, `rfcs_trampoline` in `runtime/src/libds/rfcs/codec.c`:

| Event | Record |
|---|---|
| integrator assert | `FactAssert`, with seq, clock and TTL window |
| rule `emit` or `publish` | `FactEmit`, with rule name, seq, clock, TTL window and `published`; never also a `FactAssert` (RETRFLAG1) |
| integrator retract | `FactRetract`, fact id only |
| engine withdrawal | `FactWithdraw`, with cause, seq and clock |

`FactWithdraw.cause` is one of `JUSTIFIER_ENDED`, `TTL_EXPIRED`, `SUPERSEDED`,
`SYNTHETIC_DISCHARGED`, `AUTHOR_WITHDRAWN` and `ACTIVATION_COMPLETED`
(`proto/fact_withdraw.proto`).

**So expiries and supersessions are recorded,** with their cause. Population
counts can be exact from the trace alone.

### 10.2 What a trace does not record

- **Log lines, cache operations, cooldown timers and matched facts.** Events
  for all of these reach the stream callback
  (`DS_EV_ACTION_LOG`, `_CACHE_*`, `_RECORD`, `DS_EV_TIMER_*`,
  `DS_EV_RULE_LHS_FACTS` in `libds.h`). The recorder's `default:` arm drops them.
- **Slot roles.** The recorder's `Slot` atoms carry kind, fact-reference target,
  `sampled` and `retained` only (`rfcs_announce_schemas`). Key or mutable role,
  nullability and tolerance are left unset, although `slot.proto` has fields for
  them. That is why dstrace reads schemas from the `.dsc`.
- **Fact-reference slots.** `emit_fact_fields` in `rfcs/codec.c` refuses a
  `DS_SLOT_FACT_REF` value ("fact-ref slot does not cross tiers"), so a
  program with a schema-typed slot cannot be recorded. The recorder's first
  such fact sets its sticky error, and nothing after it reaches the file. This
  affects `save` (§4.9): a timeline of such a program is refused with that
  reason. dstrace's own hit schemas (§7.2) live only in query engines, which
  are never recorded.
- **Contiguous sequence numbers.** Each stream event takes a `seq`, and unrecorded
  kinds still take theirs, so a trace's sequence numbers have gaps.

### 10.3 What libds's replayer does

From `replay_apply_atom`:

| Record | Verify mode | Apply-only mode |
|---|---|---|
| `StreamHeader` | version check, `dsc_hash` check when both sides have one; adopts the session id | version and hash checks |
| `FactAssert` | assert | assert |
| `FactEmit` | byte-compare with the re-derived one | assert |
| `FactRetract` | retract if still live | retract if still live |
| `FactWithdraw` | skipped | **skipped** |
| `ClockAdvance` | switch to the mock clock at the first; set the monotonic clock, and the wall clock or unset it | the same |
| `PumpBoundary` | pump | pump |
| `RuleFireAnnotation`, `CallIssued` | byte-compare | skipped |

Two consequences:

- **The replayer pumps where the recording pumped**, since the trace
  carries every pump. §3.3's settled points and §8.2's program engine follow
  it exactly.
- **Apply-only mode cannot rebuild working memory over time.** It never applies
  `FactWithdraw`, so a derived fact whose justification ended stays forever.
  dstrace's query engine therefore drives the engine itself (§7.3). The
  apply-only gap is filed as a defect.

### 10.4 Matched facts and fact ids

- **Matched facts** reach the stream callback as `rule_lhs_facts`, a list of
  fact handles, immediately before `rule_fire_begin` (`_rete_before_fire`).
- **`Engine.fact_id(handle)`** gives the engine's id, and
  **`Engine.fact_inspect(handle)`** gives schema and slots, while the handle is
  live in a callback.
- **Verify replay reproduces fact ids,** because it byte-compares `FactEmit`
  bodies, which contain them. §8.2's program engine follows the same inputs and
  cadence, so its ids equal the trace's, and its self-check confirms it.
- **The query engine assigns its own ids.** dstrace maps them from the handle
  `assert_with_ttl` returns.

### 10.5 Forking

`Engine.clone()` copies facts, working memory, series, cache, truth maintenance,
agenda and every counter. The clone and its source produce byte-identical streams
under the same input ([LDET.2.2b]). A clone starts with no callbacks
(`pyds_engine_clone_doc`).

### 10.6 Memory

`ds_engine_mem()` returns a byte breakdown with a `total_bytes`
(`libds.h`). It excludes JSON trees and counts interned strings once, as
shared. pyds does not bind it.

### 10.7 Schema detail in pyds

`pyds.Schema` has `name`, `lifecycle` (`LOGICAL` or `TTL`), `ttl_ns`, `slots` as
`(name, kind)` pairs, source location and `proto_source`. It has no slot roles,
nullability, tolerance, fact-reference target, or ambient versus explicit scope.
That is why §7.1 reads the `.dsc`'s atoms instead, which carry all of it.

### 10.8 Fact-reference slots

A `logical` schema may have a fact-reference `key` slot. The conformance fixture
`IDAT.5.3` compiles `parent: Sensor key`. At runtime a fact-reference slot holds
a fact handle (`DS_SLOT_FACT_REF` in pyds's slot conversion).

§10.10 confirms that an `emit` can set such a slot from a binding, and that
distinct referenced facts give distinct hits, so no fallback is needed.

### 10.9 `Json` slots from Python

pyds converts a Python `dict`, `list`, `str`, number, `bool` or `None` into a
JSON tree for a `Json` slot (`pyds_py_to_json_tree`). `answer` passes
`json.loads(text)`.

### 10.10 Verified by running

Five claims could not be settled by reading. Each is a test in
`bindings/python/tests/test_dstrace_stage0.py`, and all pass in the
pyds lane under both the Python and Mercury compilers, at commit `59a277cb3`.

| Claim | Result |
|---|---|
| 1. An `emit` may set a fact-reference slot from a pattern binding (`emit QHit logical t: t d: d`) | holds on both compilers |
| 2. Distinct referenced facts give distinct hits, each withdrawn when its own match ends, even when two referenced `ttl` facts have identical values | holds |
| 3. The integrator may assert into an ambient schema and into a `logical` schema the program's rules also derive | holds |
| 4. A query engine driven record by record (§7.3) against a C recording removes each `TTL_EXPIRED` fact within the same cascade as the recording, and ends with the recording's working memory | holds, over a run with a TTL expiry, a supersession, a justification ending and an integrator retract |
| 5. A program engine fed only the recording's inputs (§8.2) reproduces its `FactEmit` ids and schemas, its firings' `(rule, timetag)`, and its withdrawals, in order | holds over the same run |

Writing the tests surfaced two things the spec must respect:

- **Ambient is written `scope logical ambient`**, with key and mutable markers,
  per [LSCP.2.5]. The author's reference syntax summary shows `scope ambient`,
  which both compilers refuse. §7.1's declarations use the clause's form.
- **The Mercury compiler reserves `value`** as a slot name ([LLEX.9.5]) and the
  Python compiler does not. Generated names in §7.2 avoid every reserved word
  in [LLEX.9.6]'s list.

### 10.11 A `.dsc` carries its source

The `DSRC` atom ([RDSC.14.2]) "carries the original DS source text for one
source file" (`proto/ds_source.proto`: `file`, `compression`, `data`,
`module_id`). The compiler writes one per file by default. `dsc --strip` drops
the source-preservation atoms (`docs/references/author/tools/dsc.md`), so a
stripped `.dsc` has none. For that case a `.ds` file and `-L` supply the source,
checked against the `.dsc` before use (§2).

**Verified in stage 6** (the shell's `tests/test_rules.py`):
- the gated program replayed to the fork is identical to reality on facts,
  rule names and withdrawals (§8.6 step 6);
- a gated-off rule's `logical` conclusions are withdrawn with
  `JUSTIFIER_ENDED` when the gate appears.

### 10.12 What `rete_network` reports

From `ds_engine_rete_network` (`libds.h`, `engine_rete_adapters.c`) and its
pyds binding:

- **Nodes** come as `id`, `kind` (`alpha`, `beta`, `terminal`), `label`,
  `filter`, `occupancy` and `is_negative`. **Edges** come as `from_id` and
  `to_id`.
- **Alpha nodes** are labelled with their schema, and their filter is the
  formatted single-fact test. Occupancy is the facts in their memory.
- **Join nodes** are labelled only `join`, with filter `join` or empty. The
  join test's text is not reported, which is why §8.7 takes pattern text from
  the source. Occupancy is the left memory's token count. `is_negative` marks a
  `no` pattern.
- **Terminals** are labelled with the rule name. Occupancy is the pending,
  unfired activations.
- **Counts are always available.** The header says occupancy is populated only
  while the engine is paused, but the implementation fixes "paused" to true.
- **`rule_filter` is incomplete.** An alpha node is kept only if a join it
  feeds leads directly to the rule's terminal, which drops a multi-pattern
  rule's upstream alphas. Joins are never filtered. dstrace reads the whole
  network instead.
- **No contents.** Nothing lists the facts in an alpha memory or the tokens in
  a join's memory, only their counts.

### 10.13 What a derivation tree stands on

- **Matched facts** arrive as `rule_lhs_facts` immediately before each
  `rule_fire_begin`, from the current token's facts (`_rete_before_fire` in
  `engine_rete_adapters.c`). A negated pattern contributes no fact.
- **Current support** is `Engine.get_justifiers(fact_id)`: `[{timetag,
  rule_name}]` for each activation logically supporting the fact, empty for a
  fact that is not truth-maintained (RDAP1b).
- **Identity** between the provenance pass and the trace rests on stage 0
  check 5.

**Checked in stage 8** as stage 0 checked §10.10, by running
(`dsdb/test/why.test.mjs`, fixture `dsdb_why.ds`):

1. **Holds.** `rule_lhs_facts` lists the matched facts in the rule's
   positive-pattern order, so bindings can be named from the source: a rule
   `Manual h, Sensor s` whose Sensor was asserted first lists the Manual
   first. A `no` pattern contributes nothing.
2. **Half holds.** A second activation that re-derives an identical `logical`
   fact, which coalesces with it, does appear in `get_justifiers`. It also
   produces a `FactEmit`, carrying the live fact's id. So §8.8 step 1 holds
   and the effects index gains a second entry, as this item allowed. The
   timeline had to change for it: a `FactEmit` of a live fact is one more
   emitter of that fact (`Fact.reemits`), not a new fact. Read as a new fact,
   it moved where the fact began and counted it twice in the population.
3. **Holds.** `get_justifiers` on a clone gives what it gives on the engine it
   was cloned from, fact by fact.

---

## 11. Changes outside dstrace

### 11.1 pyds

| Change | Why |
|---|---|
| **done, then gone:** `pyds.rfcs` decoders for `FactEmit`, `FactWithdraw`, `CallIssued` and `PumpBoundary`, and encoders for the first three. `pyds.rfcs` is gone; libds's reader decodes every atom | reading traces (§3.1); `save` (§4.9) |
| **done:** `Engine.mem() -> dict` over `ds_engine_mem` | `hyp` |
| **done:** `Engine.fact_handle(fact_id) -> int \| None`, over `ds_engine_for_each_fact` | a handle is the fact's address, so a clone's facts have their own; retracting in a hypothesis a fact asserted before the fork has only the id (§4.9) |
| **done, RECTEE1:** a stream callback runs alongside `record_to`, and `record_to(path, flush=True)` flushes per atom. `record_to` reads back the recorder's installed callback from the engine (`engine->recorder`, through libds's internal `engine.h`, already on pyds's include path) and installs a trampoline that calls it and then the Python callback. No libds change | live timelines are the engine's own recording, and `save` copies it (§4.9, §8.4) |
| ~~an emit callback, over libds's `emit_cb`~~ | would not serve: `emit_cb` runs after the assert (§8.5) |

### 11.2 libds

No new interface is required for stages 1 to 6. Stage 5 found two defects in
`ds_engine_clone` that break [NLFC.8.1], and fixed them, since pyds cannot:

| Fix | Why |
|---|---|
| `ds_rete_engine_clone` no longer copies `before_fire`, `after_fire` and `fire_hook_ctx` from the source | the context is the owning `ds_engine`, so every `rule_fire_begin`, `rule_lhs_facts` and `rule_fire_end` of a clone went to the SOURCE's recorder and stream callback, the clone's own stream had no `RuleFireAnnotation`, and the hook dangled once the source was freed. `ds_engine_new` already wires the clone's own, as it does `clock_fn` |
| `ds_engine_clone` copies `engine->clock` | a clone of a mock-clock engine started on a live clock at 0 and refused `clock_advance` |

Stage 7 needs:

| Change | Why |
|---|---|
| a node-contents accessor: the fact ids in an alpha memory, and the fact-id tuples of the tokens in a join's left memory, by node id | drilling into a node (§4.13); filed, in DS fact ids; @ds-lang/ds binds it as `engine.reteNodeContents(id)` for dsdb |
| the join test's formatted text on beta nodes, as alpha nodes already have | pattern text without relying on source order (§8.7 step 3); optional |

---

## 12. Build order

| Stage | Delivers | Needs | State |
|---|---|---|---|
| 0 | the five checks of §10.10, as pyds tests | nothing | merged |
| 1 | `pyds.rfcs` decoders and encoders; `dstrace.py` fixes; `records.py`; `timeline.py` | nothing | merged |
| 2 | the shell in replay: navigation, `list`, `#` without a query, `!`, `^`, the fact and firing inspectors, `calls`, histograms | stage 1 | merged |
| 3 | declarations, queries, `?`, `#` with a query, projection, joins, `watch`, `next change` | stage 0; no pyds change (§7.1) | merged |
| 4 | live sessions: the program engine, callbacks, `emit`, `withdraw`, clock moves, `answer`, `fail`, `save %0`; a `.ds` file and `-L` as program source, checked against the `.dsc` (§2) | stage 3 | merged |
| 5 | hypotheses: checkpoints, clones, the self-check, `hyp`, `fg`, `bg`, `stop`, `fork`, `kill`, `real`, cross-timeline queries, replacing replies, `save %N`, `match` | stage 4; `Engine.mem()`, `Engine.fact_handle()`; the two clone fixes (§11.2) | merged; firing changes (`skip`, `change`, `add`) deferred until after stage 8, §8.5 |
| 6 | rule hypotheses: `rule` blocks, `unrule`, `rules`, `show rule`; the two checks of §10.11 | stage 5 | built |
| 7 | the Rete network at point: `rete`, `rete @N`, `rete /regex/`, `rete schemas`, `rete dot FILE`, changes since the previous settled point, drilling into a node | stage 5 for replay (stage 4 is enough for a live session); the libds node-contents accessor for drilling (§11.2) | built in dsdb (`dsdb`, `lib/core/rete.js`), all but drilling, which waits for the accessor |
| 8 | derivation trees for facts and activations: `why #N`, `why !N`, `why RULE TT`, `depth D`, the provenance pass, justifiers at point, triggers, rule conditions, refraction, source lines, following a reply to its call; the three checks of §10.13 | stage 5 for replay (stage 4 for a live session); no change outside dstrace | built in dsdb (`lib/core/why.js`), all but a pending activation's tree (it needs the terminal's contents) and `<` in a tree |

Stages 7 and 8 do not depend on each other or on stage 6, so they can be built
in any order once stage 5 is in.

Stage 2 alone answers "what was in working memory, what fired, and when" for any
trace with its `.dsc`. Stage 3 adds "which facts satisfied this, and when".

---

## 13. Wishlist

Not yet specified, and not in the build order. Each item says what is missing,
sketches how it would read in the shell's existing grammar, and names what it
would build on. The sketches are starting points, not decisions.

### 13.1 Core debugger features

**Breakpoints: run until something happens.** `next change` runs to where one
watched query's answers change, and `n fire` or `n tick` step one event. There
is no way to run until a condition holds, in either direction. This is the main
thing people do in a debugger, and it generalises `next change`.

```
- until fire alert_high                 the next firing of a rule
- until ?.Reading r where r.level > 90.0     the next point where the query has an answer
- until call svc.foo                    the next call to a service
- until fault                           the next fault record (§13.1, faults)
- back until fire alert_high            the same, backwards
- break fire alert_high                 remembered: every `n`, `@+…` and `until` stops there too
```

Builds on: the timeline's firing and call tables (stage 1), answer timelines
(stage 3). Query conditions are free, because an answer timeline already knows
every point where its answers change.

**Why didn't it fire?** Derivation trees (§4.14) explain what happened. For
rules, the commoner question is why a rule did not fire, or why a fact is
missing. That needs the deepest partial match: which patterns had candidates,
which join test rejected them, and the facts involved.

```
- whynot entry_detected
  entry_detected at @00001aba 12.0s: no activation
     1  α DoorEvent d   d.action == "opened"          2 candidates   #101 #107
     2  ∧ Motion m      m.entity_id == d.entity_id    0 tokens       rejected: #120 (entity_id "hall" ≠ "front")
     stops here: no Motion with entity_id "front" at 12.0s
```

`whynot ?Q` would do the same for a query with no answer. Builds on: the Rete
view's chains (§8.7), `rete_match_trace` for alpha tests, and the node-contents
accessor (§11.2) for tokens. The join test's text (§11.2, optional) would let
it say which test rejected a pair without re-deriving it from source.

*Built in part, as `whynot RULE` at point (DSDB_MCP.md §10.6):*
each pattern's candidates are the live facts of its schema that
`rete_match_trace` passes, and those it turns away with the test that failed;
a beta's count is its left memory, the tokens that arrived from the patterns
before it ([RDBG.6.6.3]). So what gets through a stage is the next stage's
count, and the first stage nothing gets through is where the match stops: no
fact live, none passing, no pair joining, or a `no` blocking. What gets through
the last stage is counted only where it follows (a one-pattern rule's alpha, a
last `no` with nothing to block); the terminal counts only activations not yet
fired. Otherwise it says the match reaches the last pattern, with its tokens
and candidates, and that the rest needs the node contents. With complete
matches it says how often the rule fired and names refraction and cooldown.
Which join test rejected which pair, which fact blocks which token,
and the last stage's output wait for the node contents; `whynot ?Q` is
not built.

**Faults.** Error, type, bounds and engine-fault records are decoded (stage 1),
but nothing finds or explains them.

```
- faults                                every fault in the trace, numbered
- n fault / p fault                     step to the next or previous one
- why fault 2                           the activation, rule, slot and values involved
```

Builds on: the fault records' own fields (rule, `timetag`, schema, slot, node),
and derivation trees for the activation (§4.14).

**Diffing two points or two timelines.** The per-schema deltas and `watch` show
counts and one query. A diff would show which facts appeared, disappeared or
changed values between two points, or between two timelines at matching points
(§4.8).

```
- diff @1aba @1b40                      facts added, removed and changed between them
- diff %0 %1                            the two timelines at their aligned points
- diff @1aba @1b40 /^Sensor/            limited to matching schemas
```

Builds on: the fact table and versions (stage 1). Timelines are aligned as §4.8
already aligns them.

### 13.2 State the engine holds that the shell does not show

**What happens next if time moves.** At point, the pending `after` timers,
cooldown windows and the next TTL deadlines, each with when
it comes due. `pending` would list them, and `@+D` could preview which would
fire. Builds on: an engine at point (stages 4 and 5), the timer events the
stream callback carries, and rule metadata for windows.

**Series windows.** The value of each series companion (`mean`, `stdev`, `p95`,
…) at point, per entity. `series Thermometer.temperature` would list them.
Builds on: `Engine.series_value(schema, slot, agg, window_ns, at_ns)`, which
pyds already has, on an engine at point.

**The cache plane.** Keys, values and TTLs at point. Traces do not record cache
operations (§10.2), so this is available in live sessions and hypotheses only,
from dstrace's cache callbacks.

### 13.3 Practical limits

**Large traces.** The format's own sizing is 4 to 40 GB per day per tier
([LFST.12.4]). dstrace holds every record in memory, and the provenance pass and
query engines replay from the start. Real use needs:

- an on-disk index beside the trace: record offsets, settled points, clocks and
  the fact table;
- windowed loading: decode only the records around point and those a command
  needs;
- saved checkpoints, so an engine at point starts from the nearest one on disk
  rather than from the beginning.

**Multi-tier runs.** Each tier records its own trace. Following a published fact
from one tier to the next needs several traces loaded together and aligned by
`event_id` ([LFST.7.2]). A sketch: `dstrace -i sensor.dsc sensor.dstrace
analytics.dsc analytics.dstrace`, with facts named `sensor:#88`, and derivation
trees crossing from one tier's `publish` to the next tier's input.

### 13.4 Worth having

**Scripted, machine-readable use.** `-c 'cmd; cmd'` or `-x FILE` to run commands
without a prompt, and `--json` for output a program can read. Queries and counts
then serve as regression checks in CI: "at the end of this trace, `#.Alarm a` is
0".

**Hypotheses as tests.** `export %1 FILE.dstest` would write a hypothesis as a
`.dstest` case: its inputs up to the fork, its changes, and the answers or
facts observed after, as expectations. A what-if becomes a test.

**Bookmarks.** Named points: `mark a` at point, then `@'a` to return, and
`marks` to list them. Bookmarks would also name points in `diff` and `until`.

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `dsdb` — the DS debugger, in JavaScript

**Design · status: stages 1 to 5 built and held to the Python; the Python retired; the spec's stages 7 (`rete`) and 8 (`why`) built**

`dsdb` replaced the Python `dstrace` and its interactive shell with one
JavaScript implementation. It serves a command line now and a web page later,
from the same core. What it does is unchanged:
[`DSTRACE_INTERACTIVE.md`](DSTRACE_INTERACTIVE.md) stays the specification
of behaviour, and stages 7, 8 and the deferred firing changes are built here,
not in Python. This document says how dsdb is built.

## 1. Decisions

- **JavaScript, not Python.** The reason is one system for the CLI and the web,
  with a different UI on each. It is not that JavaScript is the better language.
- **The name is `dsdb`,** and its command line behaves identically to
  `dstrace`. Output is byte-identical, so the Python and JavaScript can be
  compared transcript against transcript.
- **The Python retires once dsdb matches it:** `dstrace`, its shell and their
  tests. `pyds.rfcs` stayed then, to cross-check the C codec, and went
  later. **Done**, once every stage's output and the
  whole-session transcripts matched (§6, §11). Byte-identity was the yardstick
  for the port; with `dstrace` gone, a later change to what dsdb prints is
  dsdb's own.
  - **How a fact body is typed:** by its schema in the program the trace was
    recorded with, given one (`ds PROG.dsc TRACE`); with none, by the
    stream's own `Slot` announcement ([RFCS.5.1]), which libds decodes by.
    A fact-ref slot is typed by the announcement either way,
    as the fact its record gave, `Motion#2`: libds gives its recorded handle,
    which is that record's `fact_id` ([RFCS.6.3]). It names nothing
    outside the recording ([RFCS.4]); a query's engine takes it as its own
    fact for that record.
  - **An `ExternalAssert`** (a host input whose fact holds a fact reference,
    [RFCS.24.1]) is replayed as libds's replayer delivers one: libds applies
    the record's body as framed (@ds-lang/ds's `applyExternalAssert`), with its
    `ttl_ns`, and its `fact_ids` bind to the facts it asserted, so a later
    retract of one finds it ([RFCS.24.2]). Replay, a hypothesis, `%0`
    again and a query all take it. A delivery that refuses, or asserts a
    different number of facts than the record lists, stops there and names
    the record.
- **Plain ES modules, no TypeScript.** The baggage and constraints were judged not
  worth it (§5).
- **No all-in-one wasm.** `@ds-lang/ds` (libds), `ds_dsc` (the compiler) and `dsdb`
  load independently. The single-module version needed a wasm64 libds and emnapi,
  a re-entrant compiler entry point, and bounded compiler memory without a
  collector, none of them measured. It was dropped as not worth that.
- **No compiler library entry point.** The compiler runs as @ds-lang/ds's shim already
  runs it: a spawned binary natively, and a fresh `ds_dsc` instance per compile
  under wasm (@ds-lang/ds's `lib/compile.js` and `lib/dsc-wasm.js`).
- **No codec in dsdb.** Every atom is decoded by libds, as @ds-lang/ds decodes none
  itself (its `readAtoms`).

## 2. Layers

```
dsdb/
  lib/core/     no I/O, no UI: the model and the session
  lib/text/     results -> lines, byte-identical to the Python
  lib/cli/      the dsdb command: argv, files, readline, -f, exit codes
  lib/web/      withdrawn: no web UI code in dsdb, ever;
                a page drives lib/api instead (DSDB_WEB.md)
  test/         node:test, both @ds-lang/ds targets
```

**`core/` touches nothing outside itself:** no `node:fs`, no `process`, no
`console`. Whatever a platform supplies arrives as an injected port (§3). So the
same core runs under Node for the CLI, and in a browser worker for the web.

| module | replaces | holds |
|---|---|---|
| `grammar.js` | `commands.py` | a line to a command: sigil, scope, timelines, body; navigation; words. Shell syntax only; a DS body is carried to the compiler as text |
| `trace.js` | `records.py` | atoms to records, incrementally, through @ds-lang/ds's binding of libds's reader |
| `timeline.js` | `timeline.py` | records plus the indexes: facts, firings, calls, settled points, point names |
| `program.js` | `program.py` | a `.dsc` read back as DS declarations (§7.1 of the spec), through the same reader |
| `query.js` | `query.py` | a query compiled to a one-rule program, and the query engine and answer timeline |
| `engine-timeline.js` | `engines.py` | an engine recording itself, read back as it runs |
| `program-engine.js` | `engines.py` | the replay program engine: checkpoints and the self-check |
| `hypotheses.js` | `hypotheses.py` | forks that follow reality |
| `rules.js` | `rules.py` | rule changes behind gates, recompiled |
| `session.js` and collaborators | `shell.py` | the state, and `execute(line)` returning results |

**`shell.py` is split, not ported.** It is one 1,800-line class that holds the
state, dispatches commands, runs hypotheses and prints through `say()`. In dsdb:

- `SessionState` holds the timelines, their points, the current one, the inspector
  stack and the last listing's rows.
- `Navigator`, `Queries`, `Hypotheses`, `RuleChanges` and `Inspector` each own
  their commands.
- `Session` parses a line, routes it, and returns what the collaborators
  produced.

Nothing in core prints.

## 3. Results and ports

**`await session.execute(line)` returns results,** a list of plain objects
discriminated by `type`: `where`, `note`, `error`, `listing`, `bars`,
`histogram`, `factView`, `firingView`, `calls`, `answers`, `compare`,
`timelines`, `rules`, `help`.

- **Results carry data, not layout.** Points are carried as their names
  (`{ seq, minus }`) and clocks as nanoseconds; the renderer formats both.
- **Drill-down rows are references** (`{ kind: "fact", id }`), numbered by the
  text renderer and clickable in a web one.
- **`execute` is async** because the wasm compiler is: instantiating `ds_dsc`
  is. Everything else in core is synchronous.

**Ports,** given to the session when it is made:

| port | CLI | web (later) |
|---|---|---|
| `@ds-lang/ds` | `open({ target })` | `open({ target: "wasm" })` |
| `compile` | @ds-lang/ds's `compile` (native runner) | the `ds_dsc` runner, with the program's source as a `{ path: text }` map |
| `files` | `node:fs` read, and polling for `-f` | a `File` or `fetch` source; save as a download |
| `terminal` | readline with history; `(` and `rule` block continuation | none: the page is the UI |

**Rule changes stage the program's source as a `{ path: text }` map,** not a
temporary directory. The compiler port turns it into files for `dsc -L`:
natively, files in a scratch directory; under wasm, MEMFS.

**A query or a typed `emit` stages the program's libraries the same way.** dsdb
compiles those from the `.dsc`'s declarations, and a library schema's own name
holds a `.` ([LIMP.13.1]) that a declaration cannot ([LGRA.5.1]), so
`Program.stage` writes each library back out and the generated program imports
it. A query names one by its own name, as a recording does:
`board_model.Soc s`.

## 4. What changes from the Python, and what does not

**Unchanged:** behaviour, commands and output, everything in the spec.
Transcripts from both implementations must match, byte for byte.

**Changed underneath:**

- **An engine's recording is kept in memory.** @ds-lang/ds's `recordTo(sink)` delivers
  each atom as it is framed, and dsdb decodes it as it arrives. There are no
  temporary files. `save` writes the collected bytes.
- **A fact id is resolved from the handles stream events already carry,** kept
  by the engine timeline as facts arrive, instead of pyds's `fact_handle` scan
  over working memory.
- **Numbers.**
  - `BigInt` for everything that is 64-bit in the format: `seq`, fact ids, clocks
    in nanoseconds, timetags.
  - `Number` for record indexes and points: record counts, which fit.
  - Mixing the two throws in JavaScript. Every module states which it takes, and
    tests pin it.
- **No temporary directory for rule changes** (§3).

## 5. Style

dsdb is written to `bindings/js/JS_STYLE.md`, the tree's JavaScript style,
type check included: its gate runs `tsc --checkJs` in strict mode. What is dsdb's own, beyond that style:

- **`Map` and `Set`, not objects used as maps.**
- **Small modules with one job each.** A function that computes returns data; one
  that formats returns strings; nothing does both.
- **Errors a user can cause are results** (`{ type: "error" }`), not exceptions.
  An exception is a defect.

## 6. Verification

- **Unit tests per module, ported from the Python suites** (the shell's 92
  tests, and `test_dstrace_stage0.py`'s 7),
  in `node:test`, on both @ds-lang/ds targets.
- **No golden snapshots.** The committed whole-output
  goldens (`test/golden/`) and every test that read them were deleted. With
  the Python retired, dsdb regenerated them itself, so they could not catch
  dsdb, and every language or format change moved all of them.

## 8. Fact files: input without a trace

A new mode, not in dstrace. It needs no trace and no hand-typed `emit`s:

```
ds PROG.dsc Reading.csv Alarm.tsv Door.jsonl …      one file per schema, any number
```

**The mode.** The session is **live** (DSTRACE_INTERACTIVE §2), started from the
files. Every row is an integrator assert, merged across files by time, with a
pump after each. Each row is then a step of its own, so each is a settled point
and every shell feature works on the result, hypotheses included. `save %0`
writes it as a trace.

**Files.**

- **Name.** A file is recognised by its extension: `.csv`, `.tsv` or `.jsonl`,
  any case. Its name without the extension is the schema, which the program must
  declare. Two files for one schema are refused.
- **CSV** follows RFC 4180: the first record is the header, fields are
  `"`-quoted with `""` for a quote, and line ends are CRLF or LF.
- **TSV** has one record per line and a header line. It has no quoting; the
  escapes are `\t`, `\n`, `\r` and `\\`.
- **JSONL** has one object per line, keyed by slot name; blank lines are skipped.
- **Columns.** A column or key must be a slot of the schema, or `@at`: the
  row's time from the start, as a duration (`12_s`, `1.5_s`) or whole
  nanoseconds. Absent means 0. `@` cannot start a DS identifier, so `@at` cannot
  collide with a slot. An `@at` longer than any `Duration` is refused as the
  file loads, and an advance the engine refuses for one ([NTST.3.1]) stops the
  run. Each names the file and the line.
  - A fact takes its schema's TTL. A file with an `@ttl` column is refused as
    it loads, naming the file and the column: no public entry point sets a
    per-fact TTL.
- **Order.** Rows are merged by `@at`. Equal times keep the files' order on the
  command line, then row order.

**Values, typed by the program's schema.**

| slot type | CSV / TSV cell | JSONL |
|---|---|---|
| `Int` | decimal, exact at any width (BigInt) | a number, or a string of digits (as JSON producers write 64-bit integers) |
| `Time`, `Date`, `Duration` | as `Int`: nanoseconds since the epoch (UTC), days since the epoch, nanoseconds | as `Int` |
| `Float` | a number; `inf`, `-inf` and `nan` | a number |
| `Bool` | `true` or `false` | `true` or `false` |
| `String` | the text | a string |
| `Json` | JSON text | JSON text in a string, or any JSON value, kept as its exact source text |
| `Bytes` | base64 | base64 in a string |
| a reference to another fact | refused | refused |

**Null.** A slot with no column or key is left out, so the engine makes a
nullable one null ([LNUL.4.1]). Written nulls:

- **CSV:** a bare empty field. A quoted `""` is the empty string, and so is a
  bare empty field in a `String` slot that cannot be null, since that is how a
  CSV export writes one.
- **TSV:** `\N`.
- **JSONL:** `null`.

A null in a slot that cannot be null is refused.

**`ts`.** A row of a schema declaring `ts` that gives none takes its `@at`, from
the Unix epoch, as a `.dstest` input takes its coordinate. A `ts` the row gives
is the host's source time ([LFAC.9.2]) and is kept as written, whatever its
`@at`.

**The wall clock.** Batch mode and a live session set it to the epoch beside the
monotonic clock, and each moves with the other, so `now()` and a `ts` a rule's
`emit` or `publish` fills ([LTIM.2.8.3]) read a row's `@at`. A typed `from here
emit` takes the session's clock as its `ts`. A replayed trace has the wall clock
its recording had.

**Errors name the file and the line:** a malformed record, an unknown column, a
value of the wrong type, a schema the program lacks. So does the engine's own
refusal of an assert.

**Built** in `core/facts.js`: parsing, typing, merging and feeding.

## 9. Batch mode: a program and fact files, no shell

Without `-i`, a program and fact files (§8) are run, not explored:

```
ds -b PROG.dsc FACTS… [--out DIR --format csv|tsv|jsonl] [-q]
```

- **The program** is a `.dsc`, or a `.ds` compiled on the fly:
  `ds -b PROG.ds -L LIBDIR… FACTS…`.
  - Imports are searched in the source's own directory, then each `-L` in
    order, as `dsc -L` and pyds's `compile_file` do.
  - A `realtime` source's `.dsrt` beside it is its contract ([RTCT.4.1]).
  - A refusal is exit 1, with the compiler's diagnostics.
  - Natively the compiler is the `dsc` binary (`DS_MERCURY_DSC`, or `dsc` on
    `PATH`); under wasm it is `ds_dsc` (`DS_JS_DSC`, else
    @ds-lang/ds's own `build/ds_dsc/`, and nothing else), given the source
    and every `.ds` and `.dsrt` under its import path.
  - The target is `DS_JS_TARGET` where it names one, else native where
    @ds-lang/ds's addon is installed, else wasm. `--version` says which,
    and with which compiler.
- **The run** feeds the facts exactly as §8 does: merged by time, a pump after each.
- **What the rules `log`** goes to stderr as `2.0s  WARNING  hot b`: the clock
  from the start, the level, the message.
- **What the rules `publish`** is written out, with its slot values as they were
  at the moment it was published, and an `@at` column holding that moment as an
  exact duration (`1500_ms`). Every schema of the program appears, including
  schemas nothing was published to, so the output's shape does not depend on the
  run:
  - `--out DIR --format csv|tsv|jsonl` (the two go together): one file per
    schema, `DIR/<Schema>.<format>`;
  - otherwise one JSON document on stdout:
    `{ "Reading": [ … ], "Alert": [] }`.

  Every format is one §8 reads, so a run's output feeds the next run.
- **The run ends at its last row, unless `--until D` says later.** A timer or a
  call's `timeout` due after that row does not fire, and a rule reading a series
  does not see the row's own sample, which absorbs after the pump that asserted
  it. `--until D`, a `Duration` from the start or whole nanoseconds, moves the
  clock to `D` after the rows and any reply cycles (§9.1) and pumps once. It is
  one move and one pump: a timer armed in that pump stays pending. A row past
  `D` is refused as the run starts, naming the file and the line.
- **A single `.json` document of that shape is input too,** alongside the
  per-schema files. A schema may come from one source only, whether a
  per-schema file or a document.
- **No call is made**, unless a calls socket is given (§9.1). dsdb is the
  integrator and answers nothing. Each call a rule attempts goes to stderr, as
  `call svc.foo as "c"  {"level":95}  by ask  (not made)`: its arguments as
  §9.1 writes them, less a fact argument's bytes.
- **`-v`** also writes every stream event to stderr as it happens: `seq`, clock,
  kind and detail. These are the engine's own events, not a decoded trace.
- **Exit status:**
  - `0`: done;
  - `1`: the input was refused (a fact file, the engine or the compiler), with
    the file and line;
  - `2`: a usage error;
  - `4`: a file that cannot be read.

**Values written** use §8's table in reverse:

- `Int`, `Time`, `Date`, `Duration`: exact digits.
- `Float`: the shortest round-trip digits, and `inf`, `-inf`, `nan`, which JSON
  formats write as strings.
- `Bytes`: base64.
- `Json`:
  - in CSV and TSV, its JSON text;
  - in JSON formats, an object or array as itself, anything else as a string of
    its JSON text, so a JSON `null` or string cannot be mistaken for a null slot
    or for plain text.
- A reference to another fact is written as its id (`#12`), which cannot be read
  back as input.

**Built** in `core/batch.js`, `core/facts-out.js`, `text/batch.js` and
`cli/main.js`.

### 9.1 The calls socket

```
ds -b PROG.dsc FACTS… (--calls SOCK | --listen SOCK) [--pumps N] [--call-timeout SECONDS]
```

A Unix domain socket carries the calls out and the replies back, so a stub
service or a real adapter can answer a batch run.

- **`--calls SOCK`** connects to a socket a responder already listens on.
  **`--listen SOCK`** makes the socket, says so on stderr, and waits for one
  responder to connect before anything is fed, so no call is sent to nobody.
  The socket file is removed at the end. Either way there is one peer.
- **One JSON object per line, both ways:**
  - out, one line per call as it is made:
    `{"call":1,"service":"svc.ask","corr":"q1","args":{"n":3,"doc":{"a":1},"raw":"AAE="},"rule":"ask","at":"2_s"}`.
    - `args` holds each argument the call supplies, by name, written as §9's
      JSON formats write a slot of its kind: `Int` exact, `Float` with `inf`,
      `-inf` and `nan` as strings, `Bytes` in base64, `Json` as itself.
    - A fact argument is `{"schema":"Reading","asserted_at":<ns>,"external":"<base64>"}`:
      its FactExternal bytes, which another tier's `ds_engine_assert_external`
      takes.
    - `corr` is `null` for a call with no `as`.
    - `at` is the clock from the start as a duration literal, as `@at` reads
      it.
  - in: `{"corr":"q1","response":{…}}` or
    `{"corr":"q1","error":{"code":"svc.down","message":"…"}}`.
    - `response` holds the slots of the service's response schema, read as
      one JSONL row of it (§8). dsdb gives it the call's `corr`; a `corr`
      inside `response` is refused.
- **What waits.** A call waits for a reply when its service declares a
  response and the call has a `corr` for the response to carry. Any other
  call, to a `no response` service or with no `corr`, is sent and not waited
  for. One with a `corr` can still fail, since a `no response` service may:
  an `error` naming it is delivered.
- **Pump cycles.** `--pumps N` allows N, and is 1 by default.
  - The first cycle is the run without a socket: the fact files, a pump after
    each row.
  - Each further cycle waits for replies, then asserts each one, a response as
    a fact of the call's response schema and an error as a `CallError`
    (`corr`, `code`, `message`, `ts`, with `ts` the engine clock), and pumps
    once. The mock clock does not move: replies are what move the run on.
  - A cycle waits until every waiting call has a reply, or `--call-timeout`
    passes (real time, 5 s by default). The replies are delivered together,
    so a deterministic responder gives the same run every time.
  - The run ends early when no call is waiting, or when a cycle's wait ends
    with no reply at all.
  - `--pumps` above 1 needs a socket: later cycles only deliver replies.
- **What cannot be delivered is said, not guessed:**
  - a line that is not a reply, names no call it can settle, or is not a row
    of the response schema: `reply dropped: …`;
  - an error to a program with no rule reading `CallError`, which therefore
    has no such schema, or a response the engine refuses: `not delivered`;
  - calls still waiting at the end: `call 2 svc.ask as "b"  by again: no reply`.
- **Calls and replies on stderr:** `… by ask  (call 1, sent)`, or
  `(call 1, sent; no response)` for a call that does not wait, then
  `reply to call 1 (svc.ask as "q1"): answered`, or `failed: code  message`.
- **A later call with the same `corr`** supersedes the waiting one, as the
  timeline reads calls (DSTRACE_INTERACTIVE §4.10).
- **Exit status:** a socket that cannot be opened is 4, as an unreadable file
  is. A peer that goes away ends the waiting, not the run.

**Built** in `core/calls.js` (the protocol and the book of waiting calls, no
I/O), `core/batch.js` (the cycles, against a port) and `cli/socket.js` (the
socket, the only I/O).

## 10. One command

The program is dsdb, the DS Debugger, and its one command is `ds`, the one name
in `package.json`'s `bin`. The defaults do not depend on the name it is run as,
or on whether stdin is a terminal.

| flag | default | what it does |
|---|---|---|
| `-i` / `--interactive`, `-b` / `--batch` | `-i` | `-i` runs the shell. `-b` runs batch (§9) or the listing, and reads nothing from stdin |
| `-v` / `--verbose`, `-q` / `--quiet` | `-v` | With `-b`, `-v` shows each stream event on stderr, and `-q` does not |

The last flag given wins. A script runs `ds -b -q`.

| form | does |
|---|---|
| `ds` | a live session on an empty program |
| `ds PROG.dsc [TRACE or FACTS...]` | the shell |
| `ds -b -q PROG.dsc FACTS...` | batch (§9) |
| `ds -b -q TRACE` | the listing |

With no `-b`, a script's `ds PROG.dsc FACTS...` reads shell lines from stdin. An
option only batch or the listing reads (`--out`, `--format`, `--from`, `--calls`,
`--listen`, `--pumps`, `--call-timeout`, `--until`) is refused without `-b`, since the shell
would ignore it. With `-b` the same holds of each: batch refuses `-f` and `--from`,
and `--call-timeout` without a socket, and the listing refuses `--out`, `--format`,
`--pumps`, `--call-timeout` and `--until`. `--from` is in hex, as the listing
prints a `seq`.

## 11. Order

1. Without libds's atom reader:
   - this document;
   - the package;
   - `grammar.js`;
   - the result types;
   - the text renderers.
2. With that reader and its @ds-lang/ds binding, in the spec's stage order:
   - `trace.js`, `timeline.js`;
   - listings and navigation;
   - `program.js`, `query.js`;
   - live sessions;
   - hypotheses;
   - rule changes.
3. Transcript parity, then the Python retires.
4. Stages 7 and 8, and the deferred firing changes, in dsdb.

**Where it stands:**

- **Done:**
  - `trace.js` and the plain listing;
  - `timeline.js` and every inspector;
  - the session in replay, stage 1;
  - `program.js`, `query.js` and the session's queries, stage 2.
- **Stage 1 is replay:**
  - navigation, steps, `list`, `calls`;
  - `#`, `!`, `^` without a query, with histograms and their options;
  - the inspector (`N`, `up`, `<`, `>`, `@[`, `@]`);
  - `-f`.
- **Stage 2 is queries:**
  - `?` and `#` with a query, at point, at a position and over time;
  - answers drilled into;
  - joins, absence and projections;
  - `watch`, `next change`, `prev change`;
  - the `source:` line at start-up (`pick_source`).
- **Stage 3 is live sessions:**
  - `ds PROG.dsc` or `ds PROG.ds -L DIR` with no trace starts one;
  - `engine-timeline.js` is the engine's own recording, kept in memory through
    `recordTo(sink)` and read back after every input;
  - each firing's matched facts and log lines come from the stream callback,
    and fact handles by id from the events that carry them;
  - `emit` (evaluated by the engine), `withdraw`, `answer` and `fail` for a
    waiting call, `n` to pump and `@+D` for the clock, all at the end of a
    live `%0`;
  - `save`, in replay and live.
- **Stage 4 is hypotheses:**
  - `program-engine.js`: replay's program engine, fed the trace's inputs,
    checkpointed every 256 and checked against the trace (`unreliable`);
  - `hypotheses.js`: forks that follow reality, skipping what §4.9 says;
  - `timelines.js`: forking, rebuilding behind the end, where a change
    applies, `hyp`, `fg`, `real`, `bg`, `stop`, `fork`, `kill`, `match`, and
    `save` (a hypothesis's stream as recorded, its description printed);
  - `compare.js`: queries over several timelines (§4.8);
  - queries are per timeline.
  - @ds-lang/ds grew two bindings for it (on `jsds-r1`): `engine.factById` (pyds's
    `fact_handle`, to retract in a clone a fact asserted before it) and
    `engine.mem`. A third, `encodeText`, went with the TextNote.
- **Stage 5 is rule changes:**
  - `rules.js`: the program's source staged as a `{ name: text }` map, each
    change behind its gate, compiled through the `compileFiles` port;
  - `rule NAME: …`, `unrule`, `rules`, `show rule`;
  - a change in replay or behind a live `%0`'s end opens (or rebuilds) a
    hypothesis; at a live `%0`'s end it replaces `%0`'s own engine, which is
    why the live engine lives in the session state (`liveRun`);
  - the CLI stages the files in one scratch directory per session, removed at
    the end. A refusal names a staged file by its own name, not its directory.
- **Every shell command is ported.**
- **The Python retired**, with its tests. The pyds lane runs
  pyds's own suite only.
- **The spec's stage 7 is the Rete network:**
  - `rete.js`: the network read from an engine at point (`Timelines.readEngine`,
    which `match` shares), walked into one chain per rule, pattern text from
    the embedded source, and a second reading at the settled point before for
    the changes; `rete`, `rete @N`, `rete /regex/`, `rete schemas`,
    `rete dot FILE`; `text/rete.js` lays it out;
  - §4.13's example is the reference, and `rete.test.mjs` holds dsdb to it, with the fixture
    `dsdb_rete.ds` (the example as a program) in replay, live and a
    hypothesis;
  - a join is drawn `∧`, not `⋈` (§4.13 says why);
  - drilling into a node waits for libds's node-contents accessor.
- **The spec's stage 8 is derivation trees:**
  - `why.js`: `why #N`, `why !N`, `why RULE TT`, `depth D`, and `why` in the
    inspectors; each firing's matched facts from the timeline (live, a
    hypothesis) or the provenance pass (replay: the program engine run to
    the end keeps them, as any engine timeline does); a logical fact's
    support from `justifiers` at point; source lines from the embedded
    source; `text/why.js` draws the tree;
  - §10.13's three checks are tests in `why.test.mjs`. Check 2 found the
    coalescing `FactEmit` §10.13 allowed for, and `timeline.js` now takes it
    as a second emitter of the live fact, not a new fact (a latent bug of the
    port and the Python both);
  - not built: a pending activation's tree and `<` in a tree.
- **The REPL and `ds mcp`:**
  - changes at a point are written `from here`, `from start` or `from @N`
    (DSTRACE_INTERACTIVE §4.16), leaving a bare `emit` to DS;
  - the program is edited for all time by its definitions (`program-text.js`,
    `edit.js`): a definition block, `del`, `mv`, `ls`, `save code`,
    `changes`; every timeline is run again under the edit, and it says what
    it did; `ds` with no program starts empty; rule hypotheses and their
    gates are gone;
  - `ds mcp` (`lib/mcp/`, DSDB_MCP.md) serves all of it to
    an agent over stdio, steps 1 to 4 of its build order.
- **Next:** `ds mcp` step 5 (resources, progress, cancellation, bounds);
  drilling into `rete` once the node-contents accessor lands; the deferred
  firing changes (§8.5).
- **An invalid `answer` JSON** is a message here; the Python raises.
- **A known possible difference:** when one move changes several watched
  answers, the Python prints the `+` and `-` lines in its set order, and dsdb
  in answer order.

**Results carry the timeline they are about** (a refinement of §3). A result
that names facts, firings, calls or points holds a reference to its
`Timeline` and the objects themselves, and the renderer resolves names and
clocks from it. That is still data, not layout. It is what lets `render.js`'s
functions be the text renderer's building blocks.

## 12. The DS tools package

dsdb ships as one portable npm tarball, `ds-tools-<version>.tgz`: dsdb on wasm
@ds-lang/ds, which runs wherever Node runs. `npm install ./ds-tools-<version>.tgz`
puts `ds` on PATH and needs nothing else. The release builds it, and
a checkout builds it with one command, from what the wasm lane builds (the
glue), the release's compiler, and `@emnapi/runtime` with its dependencies,
each an npm tarball:

```sh
node scripts/dsdb/pack.mjs --version <version> \
    --glue bindings/js/build/ds_wasm.mjs \
    --compiler ds_dsc-<version>.tgz \
    --bundle runtime-<v>.tgz --bundle tslib-<v>.tgz \
    --out <dir>
```

- **The layout:** dsdb at `package/`, @ds-lang/ds bundled under
  `node_modules/`, and in its `build/` the glue, the compiler
  (`build/ds_dsc/`) and the standard library (`build/share/ds/stdlib/`).
  Each is where @ds-lang/ds looks with no variable set.
- **The standard library:** ds_dsc finds it where the native `dsc`
  finds the tarball's, `<its directory>/../share/ds/stdlib` ([LIMP.3.3.1]),
  after every `-L` directory. The wasm runner names the compiler's program
  `<its directory>/dsc` and hands it that directory's files, and the compiler
  looks for itself.
- **Stamped:** both packages carry the version, and `ds --version` and
  `ds lsp`'s `serverInfo` report it.
- **One release:** `--compiler` must be that version's, since libds loads the
  `.dsc` of its own version only ([LDET.1.10]).
- **Deterministic:** entries sorted, every time `SOURCE_DATE_EPOCH`, owner 0.
  The same inputs give the same bytes.

`test/pack.test.mjs` packs fixtures and reads the archive back with `tar`.

## 13. Where a `.ds` file's imports are found

**One rule for every dsdb tool that takes a `.ds` file**: `ds`
(the shell, batch mode, a listing given its program), `ds test`, `ds dap` and
`ds lsp`. The search path is the file's own directory, then each `-L`
directory in order, then the standard library the compiler ships with
([LIMP.3.3.1]). `cli/open.js`'s `compileFile` is the rule, and `ds lsp` builds
the same path.

**A library found in two of them is two candidates,** and the compiler refuses
the import as ambiguous, naming both ([LIMP.3.1.3]). So a file's own copy
shadows nothing: remove one copy, or keep the two apart.

**`dsc compile` differs:** it searches its `-L` directories only
([RCLI.1.4]), then its standard library. So a program beside its library
needs `-L <its directory>` under `dsc`, and nothing under dsdb's tools.

Why dsdb adds the directory:
- these tools are handed one file, and the file's neighbours are what an
  author means by "my program";
- a test kept beside the rules it exercises needs no flag;
- an editor starts `ds lsp` once for every file it opens, so the `-L` it was
  started with cannot name each file's own directory.

`-L` naming that directory as well adds nothing: it is one file reached
twice, not two candidates. `dstest.test.mjs` holds both cases.

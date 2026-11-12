<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# dsdb

## The `ds` command

### Live session on an empty program

**`ds`**

`ds` with no argument opens the shell on a live session whose program is empty.

The program is built up with [definitions](#definitions).

*(Source: tools/dsdb/lib/cli/main.js)*

### Shell

```text
ds [PROG.dsc | PROG.ds -L DIR...] [TRACE | FACTS...] [-f]
```

This form opens the shell on the program and what it is given.

- A `.ds` is compiled with its own directory and then each `-L` on the [search path](../lang/imports.md#search-path).
- A trace that embeds its program needs no other.
- A `.ds` given with a `.dsc` is checked against it, and is its source if the `.dsc` embeds none.
- With a trace, the session replays it. Without one, the session is live, and its wall clock reads the Unix epoch at its clock's `0`.
- [Fact files](#fact-files) start a live session: each row is fed as in [batch](#batch), deadline stops included. Each row and each deadline stop is a step of its own on the session's timeline, and point opens at the end. Fact files and a trace together are a usage error.

*(Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/cli/open.js, tools/dsdb/lib/api/open.js, tools/dsdb/lib/core/engine-timeline.js, Spec: [LDEB.2.2], [LDEB.2.3])*

### Batch

```text
ds -b (PROG.dsc | PROG.ds -L DIR...) FACTS... [--out DIR --format csv|tsv|jsonl]
      [--calls SOCK | --listen SOCK] [--pumps N] [--call-timeout SECONDS] [--until D]
```

This form runs the facts through the program with no shell, and reads nothing from stdin.

The engine runs on a mock clock from `0`. Each merged row moves the clock forward to its `@at`, never back, then is asserted and pumped. Before the clock moves to a later row, it stops at each [engine deadline](inv:integrator:std:doc#engine/clock) earlier than that row, and the engine pumps there; a deadline a stop's pump arms is read before the clock moves on, and a deadline at the row's own `@at` takes no step of its own. The wall clock reads the Unix epoch at `0` and moves with the mock clock, so `now()`, and a `ts` a rule's `emit` or `publish` fills, read a row's `@at`.

With `--until D`, after the rows and the reply cycles, the clock moves to `D` through each engine deadline earlier than `D`, pumping at each, and the engine pumps once at `D`. A row past `D` is refused with exit `1`, naming the file and line. Without it, the run ends at the last row's time.

The output is what the rules `publish`, every schema keyed, each slot as it was when published. An emitted fact is not output. A run that emitted and published nothing says so on stderr.

- Without `--out`, the output is one JSON document on stdout, in the form of a `.json` fact file.
- With `--out DIR --format F`, each schema is written to `DIR/<own name>.F`, in the form of that format's fact file. `DIR` is created. `--out` and `--format` go together.

A `call` is reported on stderr, and is made only with `--calls` or `--listen`.

```text
ds -b -q rules.dsc Reading.csv --out out --format jsonl --until 10_s
```

*(Spec: [NLFC.2.5], Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/core/batch.js, tools/dsdb/lib/core/facts.js, tools/dsdb/lib/core/facts-out.js)*

### Listing

```text
ds -b [PROG.dsc | PROG.ds -L DIR...] TRACE [-f] [--from SEQ]
```

This form lists a trace as text, its facts typed by the program it was recorded with.

- A line starts with the atom's `seq` as 8 hex digits, blank for an atom with none, and its message name. A `StreamHeader` takes one line per field.
- A program given types the facts. Without one, the program the trace embeds does. With neither, a fact's line says its slots are not typed.
- An atom whose body is not decoded is named with its length.
- `--from SEQ` omits atoms before `SEQ`, a `seq` in hex, as a listing prints it. Anything but hex digits is a usage error, exit `2`. An atom with no `seq` is always listed.
- `-f` keeps reading as the file grows, until interrupted. A partial atom at the end is read when it is whole.
- Without `-f`, a trace that ends in a partial atom lists every complete atom, names the partial atom's offset on stderr, and exits `0`.

A program given is put to the [binding check](#binding-check) before any record is read. Bytes that cannot be read as an atom are named by offset on stderr, with exit `1`.

The format is [The fact stream](inv:internals:std:doc#artefacts/fact-stream).

*(Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/text/listing.js)*

### Binding check

The shell and the listing check a trace against the program they pair it with, and refuse a mismatch with exit `3`.

| The trace's `StreamHeader` | Outcome |
|---|---|
| `dsc_hash` and no `dialect_def_sha256`, or the reverse | refused with `DS_ERR_BND_INCOMPLETE`, whatever the program |
| neither | no check |
| both, the program stating no `dsc_hash` | no check |
| both | `dsc_hash`, `capabilities` and `dialect_def_sha256` compared with the program's, in that order |

A `dsc_hash` that differs is `DS_ERR_BND_DSC_MISMATCH`. `capabilities` that differ, in membership or in order, or a `dialect_def_sha256` that differs, is `DS_ERR_BND_DIALECT_MISMATCH`.

A refusal writes `ds: the trace was not recorded with this program (<code>)` to stderr, then a line naming the field that differs and each side's value, a hash as its first 16 hex digits. Where no check is made, stderr says the trace's program cannot be checked.

*(Spec: [RFCS.4.5], [RBND.2.1], Source: tools/dsdb/lib/core/binding.js, tools/dsdb/lib/api/open.js, tools/dsdb/lib/cli/main.js)*

### Subcommands

| Form | Page |
|---|---|
| `ds mcp [-L DIR]... [--root DIR]... [--out DIR] [--calls SOCK [--call-timeout SECONDS]]` | [`ds mcp`](mcp.md) |
| `ds lsp [-L DIR]...` | [`ds lsp`](lsp.md) |
| `ds dap [-L DIR]...` | [`ds dap`](dap.md) |
| `ds test [-L DIR]... [--program PROG.ds] FILE...` | [`ds test`](ds-test.md) |
| `ds serve [--host 127.0.0.1] [--port 7373] [--origin URL]... [--token T] [-L DIR]... [--root DIR]... [--out DIR] [--shell-lines]` | [`ds serve`](#ds-serve) |

A word one edit or one swap from a subcommand, naming no file, is a usage error that names the subcommand.

*(Source: tools/dsdb/lib/cli/main.js)*

### `--version`

**`ds --version`**

`--version` prints the version of `ds`, then the libds and the compiler it runs on.

The libds line names the target, `native` or `wasm`. A libds or a compiler that is absent is stated on its line, with exit `0`.

*(Source: tools/dsdb/lib/cli/main.js)*

### Options

| Option | Value | Effect |
|---|---|---|
| `-i`, `--interactive` | none | the shell; the default |
| `-b`, `--batch` | none | no shell |
| `-v`, `--verbose` | none | stream events on stderr; the default |
| `-q`, `--quiet` | none | with `-b`, no stream events on stderr |
| `-f`, `--follow` | none | take in what is appended to the trace |
| `-L`, `--search-path` | a directory | adds a library directory; accumulates |
| `--out` | a directory | [batch](#batch) output directory |
| `--format` | `csv`, `tsv` or `jsonl` | [batch](#batch) output format |
| `--from` | a `seq` in hex, as a listing prints it; anything but hex digits is exit `2` | [listing](#listing) start |
| `--calls` | a socket path | [calls socket](#calls-socket) to connect to |
| `--listen` | a socket path | [calls socket](#calls-socket) to make |
| `--pumps` | a whole number from `1` | pump cycles; default `1` |
| `--call-timeout` | seconds, `0` or more | how long a cycle waits for replies; default `5` |
| `--until` | a duration from the start, such as `10_s`, or whole nanoseconds, up to the longest `Duration` | [batch](#batch) end time |
| `-h`, `--help` | none | the usage on stdout, exit `0` |

`--out`, `--format`, `--from`, `--calls`, `--listen`, `--pumps`, `--call-timeout` and `--until` are refused without `-b`, exit `2`.

With `-b`, each form refuses the options it does not read, exit `2`:

| Form | Refused |
|---|---|
| [batch](#batch) | `-f`, `--follow`, `--from` |
| [batch](#batch) with neither `--calls` nor `--listen` | `--call-timeout` |
| [listing](#listing) | `--out`, `--format`, `--pumps`, `--call-timeout`, `--until` |

`-q` and `-L` are taken by every form with `-b`.

`-q` changes batch alone. `ds -b` with no `-q` writes each stream event to stderr. A rule's `log`, a call and a reply reach stderr under `-q` too.

`--pumps` above `1` needs `--calls` or `--listen`. `--calls` and `--listen` exclude each other, and need a program and fact files. After a subcommand, `-h` prints that subcommand's usage.

*(Source: tools/dsdb/lib/cli/main.js)*

### File kinds

`ds` recognises a file by its name.

| Name | Kind |
|---|---|
| ends `.csv`, `.tsv`, `.jsonl` or `.json`, in any case | [fact file](#fact-files) |
| ends `.dsc` | a program |
| ends `.ds` | a program's source |
| anything else | a trace |

*(Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/core/facts.js)*

### Exit statuses

| Status | Meaning |
|---|---|
| `0` | done, help or the version asked for, `quit` or the end of input in the shell, or `-f` interrupted |
| `1` | the input was refused: a fact file, the engine or the compiler; or a malformed trace |
| `2` | a usage error, or a `.ds` that does not compile where the shell has no other program |
| `3` | a trace the [binding check](#binding-check) refuses |
| `4` | a file that cannot be read or is not a trace, `.dsc` or `.ds`; a calls socket that cannot be opened; or `@ds-lang/ds` or its target not installed |

*(Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/cli/open.js, tools/dsdb/lib/api/open.js)*

## Fact files

### File names

**`<own name>.csv`, `<own name>.tsv`, `<own name>.jsonl`, `<name>.json`**

A `.csv`, `.tsv` or `.jsonl` file holds one schema's rows, and its name is that schema's [own name](../lang/imports.md#own-name). A `.json` file holds every schema it names.

A library schema's file is named for its own name: `board_model.Soc.csv`. One schema has one source across the files given.

*(Source: tools/dsdb/lib/core/facts.js)*

### `@at`

**`@at`**

`@at` is a row's time from the session's start: a duration literal (`12_s`) or whole nanoseconds.

Absent or null, it is `0`. A value past the longest `Duration` is refused. `@at` is the only column that is not a slot.

Rows merge by `@at`, then by the order the files were given, then by row.

A row of a schema that declares `ts` and gives none takes its `@at` as its `ts`, from the Unix epoch. A `ts` the row gives is kept as given, and a null one is refused.

*(Spec: [LFAC.9.1], Source: tools/dsdb/lib/core/facts.js)*

### CSV

**`<own name>.csv`**

RFC 4180, with the first record as the header.

A bare empty field is null, and in a `String` slot that is not nullable, the empty string. A quoted `""` is the empty string.

*(Source: tools/dsdb/lib/core/facts.js)*

### TSV

**`<own name>.tsv`**

Tab-separated, one record per line, no quoting, with the first record as the header.

A field of exactly `\N` is null. `\t`, `\n`, `\r` and `\\` are the escapes, and any other is refused. An empty field is the empty string.

*(Source: tools/dsdb/lib/core/facts.js)*

### JSONL

**`<own name>.jsonl`**

One JSON object per line, keyed by slot. A blank line is skipped.

*(Source: tools/dsdb/lib/core/facts.js)*

### JSON

**`<name>.json`**

One JSON object: each schema's own name, then an array of its rows as JSONL's objects.

```text
{ "Reading": [ { "@at": "1_s", "id": "a", "level": 85.0 } ] }
```

*(Source: tools/dsdb/lib/core/facts.js)*

### Cell types

A cell is read as its slot's type.

| Slot type | Cell |
|---|---|
| `Int`, `Time`, `Date`, `Duration` | an integer; in JSON, a number or a string of digits |
| `Float` | a number, or `inf` or `infinity`, signed and in any case |
| `Bool` | `true` or `false` |
| `String` | text; in JSON, a string |
| `Json` | JSON text; in JSONL and JSON, also the value itself |
| `Bytes` | base64 text |

A `nan` cell in a `Float` slot is refused with `DS_ERR_NAN_REJECTED`, exit `1`, naming the file and line ([NaN values](../expr/math.md#nan-values)). A reference to another fact is refused. A slot with no column or key is left to the engine. A column that names no slot is refused.

*(Spec: [LEXP.4.2], Source: tools/dsdb/lib/core/facts.js, tools/dsdb/lib/cli/main.js)*

## Calls socket

### Connecting

**`--calls SOCK`, `--listen SOCK`**

The calls socket is a Unix domain socket carrying one JSON object per line, each way.

`--calls` connects to a socket a responder listens on. `--listen` makes the socket, says so on stderr, takes the first peer that connects, and removes the file when done. Every file is read and the program compiled before either opens.

*(Source: tools/dsdb/lib/cli/socket.js, tools/dsdb/lib/cli/main.js)*

### Call line

**`{"call","service","corr","args","rule","at"}`**

A call line is one call, sent as it is issued.

`call` is its number from `1`. `corr` is null for a call with no `as`. `args` holds each argument supplied, written as batch writes a slot of its kind, and a fact argument as `{"schema","asserted_at","external"}`, `external` in base64. `at` is the clock from the run's start as a duration literal.

```text
{"call":1,"service":"svc.op","corr":"q1","args":{"level":3},"rule":"ask","at":"2_s"}
```

*(Source: tools/dsdb/lib/core/calls.js)*

### Reply line

**`{"corr","response"}`, `{"corr","error":{"code","message"}}`**

A reply line settles the call that names its `corr`.

`response` holds the slots of the service's response schema, typed as a JSONL row. It omits `corr`, and gives every slot that is not nullable. `error` is delivered as a [`CallError`](../calls/call.md#callerror). A program with no `CallError` schema does not receive it, and stderr says so.

A call to a [`no response`](../calls/call.md#no-response) service, or with no `corr`, does not wait. One with a `corr` takes an `error`. A later call with the same `corr` supersedes the earlier. A second reply to one call replaces the first.

A line that fits none of this is reported on stderr and dropped.

*(Source: tools/dsdb/lib/core/calls.js, tools/dsdb/lib/core/batch.js)*

### Pump cycles

**`--pumps N`**

`--pumps` is the number of pump cycles batch runs; the facts are the first.

Each later cycle waits up to `--call-timeout` for a reply to every waiting call, delivers those that came, and pumps once. A cycle with no reply ends the run. Each call no reply reached is named on stderr.

*(Source: tools/dsdb/lib/core/batch.js, tools/dsdb/lib/cli/main.js)*

## The shell

### Lines

The shell reads one line at a time at a prompt, until `quit`, `exit` or the end of input.

A line ending in `(` opens a block that a line of `)` closes. A definition runs to two blank lines. The prompt shows the calls waiting at point and, on a hypothesis, its number, fork and changes.

*(Source: tools/dsdb/lib/cli/shell.js, tools/dsdb/lib/core/session.js)*

### Point

Point is the position on the current timeline that commands read.

A position is a record's `seq` in hex. A trailing `-` is the unnamed point before it. A settled point is one where a pump has ended. A duration carries its `_`.

*(Source: tools/dsdb/lib/core/grammar.js)*

### Timelines

`%0` is the real run, and `%N` is a hypothesis: a fork of a timeline that runs forward under changed inputs.

*(Spec: [LDEB.6.3.1], Source: tools/dsdb/lib/core/session.js)*

### Help

**`help`**

`help` lists the commands.

*(Source: tools/dsdb/lib/text/session.js)*

### Quit

**`quit`, `exit`**

These end the session, exit `0`.

*(Source: tools/dsdb/lib/core/session.js)*

## Queries and counts

### Query

**`Q`**

A query is a rule's left-hand side: `Reading r where r.level > 80.0`.

A last part `-> a, b` shows those values for each answer in place of the facts. A library schema is named by its [own name](../lang/imports.md#own-name): `board_model.Soc s`.

The compiler is the only parser of `Q`, and a query it refuses is an error at the prompt.

*(Source: tools/dsdb/lib/text/session.js, tools/dsdb/lib/core/session.js, tools/dsdb/lib/core/program.js)*

### Population

**`#.  #:  #@N`**

These give the facts per schema: at point, over time, at `N`.

*(Source: tools/dsdb/lib/text/session.js)*

### Firings

**`!.  !:  !@N`**

These list rule firings: that led to point, all of them, that led to `N`.

*(Source: tools/dsdb/lib/text/session.js)*

### Firing counts

**`^.  ^:  ^@N`**

These give the firings per rule, the same three ways.

*(Source: tools/dsdb/lib/text/session.js)*

### Answers

**`?.Q  ?:Q  ?@N Q`**

These give the answers to `Q`: at point, over time, at `N`.

*(Source: tools/dsdb/lib/text/session.js)*

### Answer counts

**`#.Q  #:Q  #@N Q`**

These give how many answers: at point, population over time, at `N`.

*(Source: tools/dsdb/lib/text/session.js)*

### Join

**`?.(`**

This opens a join: one pattern per line, then a line of `)`.

*(Source: tools/dsdb/lib/text/session.js)*

### Filters

**`/regex/`, `tumbling 1_s`, `min|max|mean`**

After `#:` or `^:`, `/regex/` filters names, and a trailing `tumbling` or `min|max|mean` shapes the histogram.

*(Source: tools/dsdb/lib/text/session.js)*

### Comparison

**`?.%0 %1 Q`**

This compares timelines: `+` is only in the others, `-` only in the first.

Within a hypothesis, one named timeline is compared with `%0`.

*(Source: tools/dsdb/lib/text/session.js, tools/dsdb/lib/core/session.js)*

## Changes at point

### Where a change lands

**`from here`, `from start`, `from @N`**

A change at the end of a live `%0` applies to it, and anywhere else in `%0` it opens a hypothesis.

`from start` and `from @N` move point first, and `N` is a position, `<`, `>` or a clock.

*(Source: tools/dsdb/lib/text/session.js, tools/dsdb/lib/core/grammar.js)*

### `emit`

**`from here emit Schema slot: value …`**

This asserts an input and runs to quiescence.

A library schema is named by its [own name](../lang/imports.md#own-name). The fact takes the session's clock as its `ts`.

*(Source: tools/dsdb/lib/text/session.js, tools/dsdb/lib/core/program.js, tools/dsdb/lib/core/changes.js)*

### `withdraw`

**`from here withdraw #N`**

This retracts a live fact.

*(Source: tools/dsdb/lib/text/session.js)*

### `answer`

**`from here answer N JSON`**

This replies to call `N`.

*(Source: tools/dsdb/lib/text/session.js)*

### `fail`

**`from here fail N code: "…" message: "…"`**

This fails call `N`, as a [`CallError`](../calls/call.md#callerror).

*(Source: tools/dsdb/lib/text/session.js, tools/dsdb/lib/api/ops.js)*

### `silence`

**`from here silence N`**

This drops call `N`'s recorded reply.

*(Source: tools/dsdb/lib/text/session.js)*

### Advancing

**`@+5_s  n`**

At the end of a timeline, these advance the clock on a live session and feed reality on a hypothesis.

*(Source: tools/dsdb/lib/text/session.js)*

## Timeline commands

### `hyp`

**`hyp`**

This lists the timelines.

*(Source: tools/dsdb/lib/text/session.js)*

### Current timeline

**`%`**

This names the current timeline.

*(Source: tools/dsdb/lib/text/session.js)*

### `fg`

**`fg %N  real`**

These switch timeline; `real` is `fg %0`.

*(Source: tools/dsdb/lib/text/session.js)*

### `bg` and `stop`

**`bg %N  stop %N`**

With `bg`, `%N` follows `%0`'s point. With `stop`, it stays where it is.

*(Source: tools/dsdb/lib/text/session.js)*

### `fork`

**`fork`**

This opens a new hypothesis at point.

*(Source: tools/dsdb/lib/text/session.js)*

### `kill`

**`kill %N`**

This closes a hypothesis.

*(Source: tools/dsdb/lib/text/session.js)*

### `save trace`

**`save trace [%N] PATH`**

This writes a timeline as a trace.

*(Source: tools/dsdb/lib/text/session.js)*

### `changes`

**`changes`**

This lists the timeline's changes at a point, each where it was made.

*(Source: tools/dsdb/lib/text/session.js)*

## The program

### Definitions

**`schema …, rule NAME: …, service …`**

A definition at the prompt, up to two blank lines, is added, or replaces the one of its kind and name.

This and `del` and `mv` apply for all time, and every timeline runs again under the edit.

*(Source: tools/dsdb/lib/text/session.js, tools/dsdb/lib/cli/shell.js)*

### `del`

**`del NAME`, `del KIND NAME`, `del use`, `del import MODULE`**

This removes a definition.

*(Source: tools/dsdb/lib/text/session.js)*

### `mv`

**`mv RULE N`, `mv RULE before|after OTHER`**

This moves a rule in the rule order.

*(Source: tools/dsdb/lib/text/session.js)*

### `show`

**`show rule NAME`**

This prints the rule's text.

*(Source: tools/dsdb/lib/text/session.js)*

### `ls`

**`ls  ls rules`**

These list the program's definitions, and the rule order with firings.

*(Source: tools/dsdb/lib/text/session.js)*

### `save code`

**`save code PATH`**

This writes the program as one file.

*(Source: tools/dsdb/lib/text/session.js)*

## Watching

### `watch`

**`watch Q`**

This shows `Q`'s answers arriving (`+`) and leaving (`-`) on every move.

*(Source: tools/dsdb/lib/text/session.js)*

### `unwatch`

**`unwatch`**

This ends the watch.

*(Source: tools/dsdb/lib/text/session.js)*

### `next change`

**`next change`, `prev change`**

These move to where the watched answers change.

*(Source: tools/dsdb/lib/text/session.js)*

## Navigation

### Positions

**`@N  @N-`**

These move to a hex position; a trailing `-` is the unnamed point before it.

*(Source: tools/dsdb/lib/text/session.js)*

### Moves by records

**`@+10  @-3`**

These move by records, counted in decimal.

*(Source: tools/dsdb/lib/text/session.js)*

### Clock moves

**`@12_s  @+500_ms`**

These move to a clock time, or by a duration.

*(Source: tools/dsdb/lib/text/session.js)*

### Ends

**`@<  @>  @`**

These are the start, the end (`@$` too), and where point is.

*(Source: tools/dsdb/lib/text/session.js)*

### Buckets

**`@#N`**

This moves to the first position of histogram bucket `N`.

*(Source: tools/dsdb/lib/text/session.js)*

### Steps

**`n  p`**, **`n atom|fire|tick`**

`n` and `p` move to the following or preceding settled point. With a unit, they step one record, rule firing or clock advance.

*(Source: tools/dsdb/lib/text/session.js, tools/dsdb/lib/core/grammar.js)*

## Inspecting

### Rows

**`N`**

This drills into row `N` of the last listing.

*(Source: tools/dsdb/lib/text/session.js)*

### Back and versions

**`up  <  >  @[  @]`**

These go back; to the prior or following version; and to where the fact began or ended.

*(Source: tools/dsdb/lib/text/session.js)*

### `match`

**`match`**

This runs the inspected fact through the network's alpha tests.

*(Source: tools/dsdb/lib/text/session.js)*

### `why`

**`why`, `why #N`, `why !N`, `why RULE TT`, `depth D` after any**

This gives what led to the fact or firing shown.

*(Source: tools/dsdb/lib/text/session.js)*

### `calls`

**`calls  calls all`**

These list the waiting calls, and every call.

*(Source: tools/dsdb/lib/text/session.js)*

### `list`

**`list [K]`**

This lists `K` records either side of point; `K` defaults to `10`.

*(Source: tools/dsdb/lib/text/session.js)*

## The matching network

### `rete`

**`rete [@N] [/re/]`**

This gives each rule's chain at point: facts, tokens, activations.

*(Source: tools/dsdb/lib/text/session.js)*

### `rete schemas`

**`rete schemas`**

This gives the alpha nodes by schema.

*(Source: tools/dsdb/lib/text/session.js)*

### `rete dot`

**`rete dot FILE`**

This writes the graph as Graphviz.

*(Source: tools/dsdb/lib/text/session.js)*

### `whynot`

**`whynot RULE`**

This gives how far the rule matches at point, and where it stops.

*(Source: tools/dsdb/lib/text/session.js)*

## `ds serve`

### Command

```text
ds serve [--host 127.0.0.1] [--port 7373] [--origin URL]... [--token T] [-L DIR]...
         [--root DIR]... [--out DIR] [--shell-lines]
```

`ds serve` is a WebSocket a web page drives dsdb's API over, on this machine only.

It runs until `SIGINT` or `SIGTERM`, exit `0`. It says where to connect on stderr, the token included. `--root` and `--out` confine it as they do [`ds mcp`](mcp.md#confinement).

*(Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/serve/server.js)*

### Options

| Option | Value | Effect |
|---|---|---|
| `--host` | `127.0.0.1`, `::1` or `localhost` | the address; any other is a usage error |
| `--port` | `0` to `65535`, `0` for any free one | the port; default `7373` |
| `--origin` | a URL | a page origin let in; accumulates |
| `--token` | a token | the token; default 24 random bytes in hex |
| `-L`, `--search-path` | a directory | a library directory for every load |
| `--root` | a directory | a directory to read under |
| `--out` | a directory | the directory to write under |
| `--shell-lines` | none | turns on `ops/exec` |

*(Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/serve/server.js)*

### Access

**`ws://HOST:PORT/?token=TOKEN`**

A connection presents the token as `?token=`, at path `/`.

| Status | Refused when |
|---|---|
| `400` | an upgrade that is not to WebSocket, or carries no key |
| `401` | the token is wrong or absent |
| `403` | the `Origin` is not let in |
| `404` | the path is not `/` |
| `426` | the WebSocket version is not `13`, or the request is no upgrade at all |

Without `--origin`, a page from a loopback address is let in. With it, only the origins named are. A client that sends no `Origin` is let in by its token alone.

*(Source: tools/dsdb/lib/serve/server.js)*

### Protocol

JSON-RPC 2.0, one session per connection, requests answered in order.

| Method | Params | Result |
|---|---|---|
| `ping` | none | `{}` |
| `ops/list` | none | `ops`, the [tools](mcp.md#tools), and `shellLines` |
| `ops/call` | `name`, `args`, `progress` | `results`, `text`, `isError` |
| `ops/exec` | `line`, `progress` | as `ops/call`, for a shell line; refused without `--shell-lines` |
| `resources/list` | none | as [`ds mcp`](mcp.md#resources) |
| `resources/templates/list` | none | as [`ds mcp`](mcp.md#resources) |
| `resources/read` | `uri` | as [`ds mcp`](mcp.md#resources) |

A call with a `progress` token gets `progress` notifications with `token`, `progress`, `total` and `message`. `resources/list_changed` follows a change in the resources listed.

*(Source: tools/dsdb/lib/api/rpc.js, tools/dsdb/lib/serve/server.js)*

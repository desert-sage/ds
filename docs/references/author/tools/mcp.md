<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `ds mcp`

## Server

### Command

**`ds mcp [-L DIR]... [--root DIR]... [--out DIR] [--calls SOCK [--call-timeout SECONDS]]`**

`ds mcp` is an MCP server on stdin and stdout.

| Option | Value | Effect |
|---|---|---|
| `-L`, `--search-path` | a directory | a library directory for every load; accumulates |
| `--root` | a directory | a directory to read under; accumulates |
| `--out` | a directory | the directory to write under |
| `--calls` | a socket path | sends each call to a responder on this socket |
| `--call-timeout` | seconds, `0` or more | how long a round of calls waits for replies; default `5` |
| `-h`, `--help` | none | the usage on stdout, exit `0` |

The exit status is `0` once the input ends. A socket that cannot be opened is exit `4`.

*(Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/mcp/server.js)*

### Protocol

JSON-RPC 2.0, one message per line, one client and one session, handled in order. Batches are refused.

| Method | Result |
|---|---|
| `initialize` | capabilities `tools` and `resources.listChanged`, and `instructions` |
| `ping` | `{}` |
| `tools/list` | each tool, with its input and output schema |
| `tools/call` | `content`, `structuredContent.results` and `isError` |
| `resources/list`, `resources/templates/list`, `resources/read` | [resources](#resources) |

The protocol revision is the client's where it is `2025-11-25` or `2025-06-18`, else `2025-11-25`. An unknown method or tool, a malformed message and a resource that cannot be read are JSON-RPC errors.

*(Source: tools/dsdb/lib/mcp/server.js)*

### Refusals

A tool that refuses answers with `isError` true and the shell's message.

An argument a tool does not declare is refused. Every tool but `load` is refused until a session is loaded.

*(Source: tools/dsdb/lib/mcp/server.js, tools/dsdb/lib/api/ops.js)*

### Progress

A `tools/call` whose `_meta.progressToken` is a string or a number gets `notifications/progress` during long work, rising across the call.

*(Source: tools/dsdb/lib/mcp/server.js, tools/dsdb/lib/api/ops.js)*

## Confinement

### Reads and writes

**`--root DIR`, `--out DIR`**

A path a client names is read only under a `--root` or `--out`, and written only under `--out`.

Each is the working directory when not given. A path is taken through its symbolic links first. `load`'s `program`, `trace` and `search` are refused outside, and so is a save.

A directory that is not one is a usage error. What the command line names, `-L` and `--calls`, is not confined.

*(Source: tools/dsdb/lib/cli/fence.js, tools/dsdb/lib/cli/open.js)*

## Tools

### Points

Tools that read take `at`, a point, and leave point where it is. `move` alone moves it.

A point is a hex position as listings print it (`1aba`, `1aba-`), `start`, `end`, or a clock from the first record with its underscore (`12_s`). Facts are named by id, and firings by rule and timetag.

*(Source: tools/dsdb/lib/api/ops.js, tools/dsdb/lib/mcp/server.js)*

### Session

| Tool | Arguments | Result |
|---|---|---|
| `load` | `program`, `trace`, `search` | loads a `.dsc` or `.ds` and a trace to replay, replacing what was loaded; with no trace, a live session; with neither, a live session on an empty program |
| `where` | none | point's position and clock, and whether it is settled |
| `move` | one of `to`, `by`, `step`; `unit` | moves point; `unit` is `settled` (the default), `record`, `firing` or `tick`. At a live session's end, a duration advances the clock and `step` pumps |
| `advance` | `by` | lets time pass: at a live session's end, moves its clock and pumps; at a hypothesis's end, feeds it reality's inputs |

*(Source: tools/dsdb/lib/cli/open.js, tools/dsdb/lib/api/ops.js)*

### Looking

| Tool | Arguments | Result |
|---|---|---|
| `population` | `schema`, `at`, `over_time` | live facts per schema, with the change since the settled point before; or each schema's population over the timeline |
| `facts` | `schema`, `where`, `at`, `limit`, `cursor` | one schema's live facts, each bound to `f`; `where` is a DS condition over `f` |
| `query` | `body`, `at`, `over_time`, `count`, `limit`, `cursor` | answers to a query: one pattern per line, and a last line `-> a, b` projects |
| `fact` | `id` | one fact: slots, lifecycle, where it began and ended, versions |
| `firings` | `scope`, `rule`, `at`, `count`, `limit`, `cursor` | firings in the cascade that led to a point, or `scope: all`; `count` gives how many per rule |
| `firing` | `rule`, `timetag` | one firing: matched facts and effects |
| `calls` | `all`, `at`, `limit`, `cursor` | calls waiting at a point, or every call and its outcome |
| `why` | `fact`, or `rule` and `timetag`; `depth`, `nodes`, `at` | the derivation tree down to the inputs |
| `rete` | `rule`, `view`, `at`, `limit`, `cursor` | each rule's chain with what each node holds; or `view: schemas`, alpha-first |
| `whynot` | `rule`, `at` | how far a rule matches, and where it stops |
| `match` | `fact`, `at` | a fact through the network's alpha tests |
| `listing` | `around`, `at`, `limit`, `cursor` | the record listing, `around` records either side of a point; default `10` |

`schema` and `rule` in `population`, `firings` and `rete` are regular expressions over names. A library schema is named by its [own name](../lang/imports.md#own-name).

*(Source: tools/dsdb/lib/api/ops.js)*

### Timelines

| Tool | Arguments | Result |
|---|---|---|
| `timelines` | none | `%0` and each hypothesis, with fork, point, changes and memory |
| `switch` | `timeline` | makes a timeline current |
| `fork` | none | a new hypothesis at point, made current |
| `kill` | `timeline` | closes a hypothesis |
| `save_trace` | `path`, `timeline` | writes a timeline as a trace file |
| `changes` | none | the current timeline's changes at a point |

*(Source: tools/dsdb/lib/api/ops.js)*

### Changes at point

`from` is where the change is made: `here` (the default), `start`, `end`, or a point. Point moves there first. A change lands as [the shell's](dsdb.md#where-a-change-lands) does.

| Tool | Arguments | Result |
|---|---|---|
| `from_here_emit` | `text`, `from` | asserts an input and runs to quiescence; `text` is the fact as DS writes it after `emit` |
| `from_here_withdraw` | `fact`, `from` | retracts a live fact; from a point before its assert, its input never happens |
| `from_here_answer` | `call`, `response`, `from` | replies to a call; `response` holds the slots but `corr`, typed as fact files type them. An answered call's reply is replaced in a fork |
| `from_here_fail` | `call`, `code`, `message`, `from` | fails a call, as a [`CallError`](../calls/call.md#callerror) |
| `from_here_silence` | `call`, `from` | drops an answered call's recorded reply, in a fork |

*(Source: tools/dsdb/lib/api/ops.js)*

### Program

An edit applies as [the shell's](dsdb.md#definitions) does.

| Tool | Arguments | Result |
|---|---|---|
| `define` | `text` | adds one definition, or replaces the one of its kind and name; nothing changes if it does not compile. A new rule goes last in the rule order |
| `del` | `name`, `kind` | removes a definition; `kind` is `use`, `import`, `const`, `unit`, `schema`, `service`, `series`, `rule` or `test` |
| `mv` | `rule`; `to`, `before` or `after` | moves a rule in the rule order |
| `ls` | `kind`, `limit`, `cursor` | definitions by kind; `kind` is `rules`, `schemas`, `services`, `series`, `consts`, `units`, `imports` or `tests` |
| `source` | `kind`, `name` | one definition's text |
| `save_code` | `path` | writes the program to one file `load` reads again |

*(Source: tools/dsdb/lib/api/ops.js)*

### Calls responder

**`--calls SOCK`**

With `--calls`, each call at a live session's end goes to the responder when a tool ends.

Lines are the [calls socket](dsdb.md#calls-socket)'s. Replies within `--call-timeout` are made together, in call order, as `from_here_answer` and `from_here_fail`, and the same holds for the calls those make. A call to a `no response` service is sent and is not waited for. With no reply in time, the calls stay waiting, and a tool answers them. Anywhere but a live session's end, tools answer.

*(Source: tools/dsdb/lib/api/ops.js)*

## Result bounds

### Rows

**`limit`, `cursor`**

A tool with rows returns at most `limit`, default `50`, then a `more` result with how many are left and a `cursor` for them.

`facts`, `query`, `firings`, `calls`, `rete`, `listing` and `ls` are bounded so. The other arguments stay as before when a cursor is given.

*(Source: tools/dsdb/lib/api/bound.js, tools/dsdb/lib/api/ops.js)*

### Trees

**`depth`, `nodes`**

`why` stops after `depth` firing levels, or `nodes` numbered nodes, default `200`.

A fact or firing marked `…` has more below it, and `why` on it goes on.

*(Source: tools/dsdb/lib/api/bound.js, tools/dsdb/lib/api/ops.js)*

## Resources

### Listing

Nothing is listed until something is loaded. `notifications/resources/list_changed` follows a load, a fork or a kill. All are `text/plain`.

| URI | Contents |
|---|---|
| `dsdb://program` | the program's text, as `save_code` writes it |
| `dsdb://program/rules` | the rules in firing order, each with its first pattern and its firings up to point |
| `dsdb://timelines` | `%0` and each hypothesis |
| `dsdb://timeline/{n}/listing` | every record of timeline `n`, with its point marked |

A resource that cannot be read is JSON-RPC error `-32002`.

*(Source: tools/dsdb/lib/api/resources.js, tools/dsdb/lib/mcp/server.js)*

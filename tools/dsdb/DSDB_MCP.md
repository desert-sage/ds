<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `ds mcp` — dsdb as an MCP server

**Design · status: steps 1 to 4 of §9 built (`lib/mcp/`, `lib/cli/open.js`, `test/mcp.test.mjs`); of the finalization plan (§10), 10.1 to 10.8 built; cancellation deferred**

An agent writing DS debugs it the way a person does with `ds`: load a
program, run it, look at what happened and why, change it, run it again. This is
that shell as an MCP server, so an agent such as Claude Code can drive it with
tool calls and read structured results.

It is a fourth front end on dsdb's core, beside the interactive shell, batch
mode and the calls socket (DSDB.md §2, §9). Everything it does, the shell does:
the commands of DSTRACE_INTERACTIVE §4, including §4.16's program editing.

## 1. Decisions

| Question | Decision |
|---|---|
| Sessions | **One per server.** Each agent starts its own `ds mcp` over stdio and loads and unloads programs in it as often as it likes. A shared, long-running server is not a use case. |
| The loop it serves | write DS, run it, look, change it, run it again, save the program: §4.16's REPL |
| Protocol | **Hand-rolled** JSON-RPC 2.0 over stdio. dsdb and @ds-lang/ds have no npm dependencies, and this keeps it so. |
| Tools | **Typed tools only.** No tool that takes a shell line. |
| Where | **A subcommand**, `ds mcp`, in the `dsdb` package. |
| Permissions | not decided; §7 proposes defaults |

## 2. Layers

```
lib/mcp/server.js   JSON-RPC over stdio: framing, dispatch, progress, cancellation
lib/api/ops.js      the tool table: name, input schema, handler (was lib/mcp/tools.js)
lib/api/json.js     results as JSON (§5)
lib/cli/main.js     `ds mcp [--root DIR] [--out DIR] [--calls SOCKET]`
```

The tool table, the projections, `bound.js` and
`resources.js` are dsdb's API (`lib/api/`, DSDB_WEB.md §3), which every
transport shares; the MCP server is the stdio transport over it, and opens
sessions from paths through `cli/open.js`'s `nativeLoad`.

A handler calls the same core collaborators the shell's commands do and gets
the same result objects. It returns them twice: as JSON (§5), for the agent to
chain, and as the shell's text from `text/`, for the agent to read. Core does
not change for MCP. It changes for §4.16, which the shell needs as much.

## 3. The state an agent drives

One **program** (an ordered list of definitions, §4.16), and its **timelines**:
`%0`, a live session or a replayed trace, and hypotheses `%1` and up, each with
its own point. Exactly the shell's session state. `load` replaces all of it.

Two things differ from the shell, because an agent is not a person at a
prompt:

- **Looking never moves point.** Every read tool takes an optional `at` and
  answers there, as `?@N` and `rete @N` do. `move` exists for when point
  matters: a from-here change applies at point (§4.16).
- **Things are named by what they are, not by row numbers.** A fact by its id,
  a firing by `(rule, timetag)`, a call by its number, a point by its position.
  Every result carries those names, so one result's facts go straight into the
  next call.

## 4. Tools

Arguments are named as in the shell. `timeline` defaults to the current one;
`at` defaults to point. A position is the shell's (`"1aba"`, `"1aba-"`,
`"start"`, `"end"`) or a clock (`"12_s"`).

**The program (§4.16: all time, rebuilds every timeline).**

| Tool | Arguments | Result |
|---|---|---|
| `load` | `program` (a `.ds` or `.dsc` path) or none for an empty program; `trace` (a path) to replay, else a live session | the program's definitions, `%0`'s length and where point is |
| `define` | `text`: one definition, as in a `.ds` file | added or replaced; the behaviour diff (§4.16) |
| `del` | `name`, `kind` when both a schema and a rule have it; `use` and `import PATH` as names | removed; the behaviour diff |
| `mv` | `rule`, and `to` (a position in the rule order), `before` or `after` | the new order; the behaviour diff |
| `ls` | `kind` (`rules`, `schemas`, `services`, `series`), optional | the definitions; for rules, order, first pattern and firings on the timeline |
| `source` | `name` | the definition's text (`show rule`) |
| `save_code` | `path` | the program, as one file (§4.16) |

**Timelines (§4.9).**

| Tool | Arguments | Result |
|---|---|---|
| `timelines` | | each timeline: fork, point, changes, state, memory (`hyp`) |
| `switch` | `timeline` | where its point is (`fg`) |
| `fork` | | the new hypothesis, forked at point |
| `kill` | `timeline` | |
| `changes` | | the timeline's from-here changes, each at its point |
| `save_trace` | `path` | the timeline's record as a trace (`save trace`) |

**Time (§4.5).**

| Tool | Arguments | Result |
|---|---|---|
| `where` | | point: position, clock, settled or not |
| `move` | `to` (a position or clock), or `by` (records, or a duration), or `step` (`settled`, `record`, `firing`, `tick`, each `next` or `prev`) | where point now is, and a live `%0`'s new records if it pumped |

**Looking (§4.3–§4.14). None of these moves point.**

| Tool | Arguments | Result |
|---|---|---|
| `population` | `schema` (a regex over names), `at`, `over_time` | live facts per schema at `at`, with the change since the settled point before; or each schema's population over time (`#.`, `#:`) |
| `facts` | `schema`, `where` (a condition over `f`), `at` | the live facts of one schema, each bound to `f` (`?.Schema f where …`) |
| `fact` | `id` | the fact: slots, lifecycle, where it began and ended, versions (the inspector) |
| `query` | `body` (a rule's left-hand side, `-> projection` allowed), `at`, `over_time`, `count` | answers at `at`, or over time; or how many (`?`, `#` with a query) |
| `firings` | `scope` (`cascade` or `all`), `rule` (a regex), `at`, `count` | firings, or counts per rule (`!`, `^`) |
| `firing` | `rule`, `timetag` | the firing: matched facts, effects (the firing inspector) |
| `calls` | `all` | waiting calls, or every call with its outcome |
| `why` | `fact`, or `rule` and `timetag`; `depth` | the derivation tree (§4.14) |
| `rete` | `rule` (a regex), `view` (`rules` or `schemas`), `at` | the network by rule, or by schema (§4.13) |
| `whynot` | `rule`, `at` | how far the rule matches, and where it stops (§10.6) |
| `match` | `fact` | the fact through the alpha tests (§4.6) |
| `listing` | `around`, `at` | the plain listing (`list`) |

**From here (§4.16: at point, one timeline).**

| Tool | Arguments |
|---|---|
| `from_here_emit` | `schema`, `slots` |
| `from_here_withdraw` | `fact` |
| `from_here_answer` | `call`, `response` (an object: the response schema's slots, `corr` aside) |
| `from_here_fail` | `call`, `code`, `message` |
| `from_here_silence` | `call` |

Each takes an optional `from`: `here` (the default), `start`, or a point
(§4.16's `from @N`). A `withdraw` from a point before the fact was asserted
removes its input.
| `advance` | `by`: a duration. At a live `%0`'s end, moves the mock clock and pumps; at a hypothesis's end, feeds reality up to it (§4.5, §4.9) |

Each returns what the shell prints for it: the fork if one opened, and the new
records. A from-here change is always to inputs; the program changes only for
all time (§4.16).

## 5. Results as JSON

Results today hold `Timeline` objects and BigInts, which do not serialise.
`json.js` projects each result type once:

| In core | In JSON |
|---|---|
| a point `k` | `{ "k": 41, "position": "0000001a", "clock": "12.0s", "settled": true }` |
| a fact | `{ "id": "140", "schema": "Occupied", "slots": {…}, "lifecycle": "logical", "asserted": point, "ended": point \| null, "cause": … }` |
| a firing | `{ "rule": "hot", "timetag": "0x4f1", "fired": point, "matched": [fact ids] \| null }` |
| a call | `{ "number": 1, "service": "svc.foo", "corr": "b", "outcome": "waiting", "issued": point }` |
| a tree (`why`) | nested nodes, as the result has them; references as `{ "see": 2 }` |
| a BigInt | a decimal string |

A result type with no projection yet goes out as text alone, so a tool never
fails for want of one.

Each call's response carries both: `structuredContent` with the JSON, and one
`text` content block with the shell's lines. A refusal (mid-cascade, no such
fact, a compile error) is a tool result with `isError: true` and the shell's
message, not a protocol error; the agent reads it and adjusts.

## 6. Protocol

- **Framing.** Newline-delimited JSON-RPC 2.0 on stdin and stdout; logging on
  stderr, and as `notifications/message` when the client asks for it.
- **Methods.** `initialize` (the revision the client asks for when it is one of
  the two newest, 2025-11-25 and 2025-06-18, else 2025-11-25; capabilities `tools`, `resources` and `logging`), `tools/list` (each tool's
  JSON Schema from the table in `tools.js`), `tools/call`, `resources/list`,
  `resources/read`, `ping`.
- **Long work.** A replay (a rule change, an all-time edit, the provenance pass,
  a program engine built to a late point) sends `notifications/progress` when
  the call carries a progress token, and stops between inputs when the client
  sends `notifications/cancelled`, leaving the state as it was.
- **Bounded output.** Listings, answers and firings take `limit` and return a
  `cursor` for more. A tree is bounded by `depth` and a node count, and says
  where it stopped.

**Resources**, read without a tool call:

| URI | Contents |
|---|---|
| `dsdb://program` | the program's text, as `save_code` would write it |
| `dsdb://program/schemas` | the declarations (`program.js`) |
| `dsdb://program/rules` | `ls rules` |
| `dsdb://timelines` | `timelines` |
| `dsdb://timeline/{n}/listing` | the plain listing of timeline `n` |

## 7. Permissions

The directories are enforced, not left to the client's approval of each call.
*Built:* `lib/cli/fence.js`, for `ds mcp` and
`ds serve` alike.

The server is the agent's own local process, run with the agent's rights, and
the client asks the user before each tool call. The fence holds when a call is
approved without being read:

- **Reading** programs and traces, and a `load`'s own `search` directories,
  under each `--root DIR`, or the working directory when none is given, and
  under `--out`. Outside, `load` is a tool error naming the directories.
- **Writing** (`save_code`, `save_trace`, `rete` as Graphviz) under `--out
  DIR`, or the working directory. Outside, the save is a tool error.
- A path is taken through its symbolic links before it is checked, so a link
  inside a directory does not lead out of it. What the person running dsdb
  names on its command line (`-L`, `--calls`) is not fenced, and neither is a
  definition's `import`, which the compiler resolves on the search path.
- **Compiling** with the configured `dsc`: on, since the REPL needs it.
- **No real service calls.** In a live session dsdb is the integrator: a call
  waits until the agent answers it. `--calls SOCKET` wires calls to a socket
  (DSDB.md §9.1), explicitly.

## 8. Tests

`mcp.test.mjs` spawns `ds mcp` and speaks JSON-RPC to it: the handshake and tool list, each
tool over the fixtures `rete` and `why` use, a refusal as `isError`, progress
on a long replay, cancellation leaving the state unchanged, and the REPL loop
end to end (load empty, `define` three times, `from_here_emit`, `why`, `del`,
`save_code`, and `load` of what was saved behaving the same).

## 9. Build order

1. **Built.** `server.js` and the looking and time tools over
   today's core: an agent can debug a program and a trace. A read tool's `at`
   stands the timeline at that point for one command and puts point back. The
   shell's loading moved to `lib/cli/open.js`, which `load` shares. Protocol
   revisions spoken: the two newest (§6). Not yet: `load` with
   no program (it waits for §4.16), resources, progress, cancellation, bounds.
2. **Built.** The from-here tools, over today's input changes (§4.9, §4.10)
   under their new names, each with an optional `from` (§4.16's `from @N`);
   `fork`, `kill`, `save_trace`, `advance`.
3. **Built.** §4.16 in core and the shell: definitions, `del`, `mv`, `ls`,
   `save code`, `changes`, rebuilding every timeline, the behaviour diff,
   starting from no program; rule hypotheses and their gates gone.
4. **Built.** The program tools over it (`define`, `del`, `mv`, `ls`,
   `source`, `save_code`, `changes`), and `load` with no program: the REPL
   loop, tested end to end.
5. The finalization plan, §10.

## 10. Finalization plan

In this order. Each item is its own commit, held by `mcp.test.mjs` in the
js lane.

**10.1 Bounded output.** First, because an agent's context is the scarce thing:
one `firings` with `scope: all` on a large trace would fill it.

- `facts`, `query`, `firings`, `calls`, `listing` and `ls` take `limit`
  (default 50) and `cursor`. Past the limit the result says how many more
  there are and the cursor for them, in its text and its JSON:
  `… 1204 more; cursor "50"`.
- `why` takes a node cap (default 200) beside `depth`. A node cut there prints
  `…`, and `why` on it continues.
- `rete` is bounded by rules, with the same cursor.
- In the MCP layer: results are sliced before they are projected. Core does not
  change; the shell keeps printing everything, as a person scrolls.

*Built:* `lib/mcp/bound.js`, applied in `Tools.call` to each tool
marked `bound`. A cut result carries `offset` and `total` (in its JSON too), and
the text numbers its rows from the offset and counts them all; a
`{ type: "more", count, cursor }` result follows it. `ls` counts one row per
definition across the kinds; `listing` pages the records of its window. A
`why` tree is cut in numbering order, so every `(see N)` left points at a node
kept, and each fact or firing that lost children is marked `…`. A cursor is
the offset: it stays good while nothing changes between calls.

**10.2 Resources.** Cheap, and of middling use: an agent mostly calls tools,
and resources are what a user attaches.

- `dsdb://program` (what `save_code` would write), `dsdb://program/rules` (the
  rule order), `dsdb://timelines`, and the template
  `dsdb://timeline/{n}/listing`.
- `resources/list`, `resources/templates/list`, `resources/read`, and
  `notifications/resources/list_changed` after a `load` or an edit.

*Built:* `lib/mcp/resources.js`, read through `Session.resource`,
which looks without `execute`'s refreshing and following, and `Edit.code`, the
program as `save code` writes it, unwritten. Nothing is listed before a `load`;
then the three above and each timeline's listing, which is the whole timeline
with its point marked. `list_changed` goes out when the list does (a `load`, a
`fork`, a `kill`, a hypothesis opened by a change), not after an edit: an edit
changes what the resources hold, not which there are, and announcing that is
`resources/subscribe`, not built. A resource that cannot be read is error
-32002.

**10.3 Progress.** The long work on a large trace is the program engine's
replay, `why`'s provenance pass and an edit's rebuild. Each takes an optional
`progress(done, total)` hook, called every 256 inputs as the checkpoints are.
When a call carries a progress token, the MCP layer turns the hook into
`notifications/progress`. The work is synchronous, and that is fine: writes to
a pipe are synchronous on Linux, so the notifications go out as it runs.

*Built:* the hook is `SessionState.progress`, `(done, total,
what)`, which a front end sets for one command; the program engine's `to`
(so `why`'s provenance pass and any engine built at a late point) and
`Timelines.rebuild0` (an edit) call it every 256 inputs and at the end, when
there are 256 or more. `Tools.call` sets it when the call carries
`_meta.progressToken`, as one count that only rises across the call's replays,
each with its `message`. A hypothesis forked again after an edit gets its
engine from the program engine, so its replay is counted there.

**10.4 A reference page, and registering the server.** Without this nobody
finds it. `docs/references/author/tools/mcp.md`: what the server is for, the loop
(load or start empty, define, emit, look with `why` and `rete`, redefine, see
what changed, save the code), each tool in a line, and how to register it:
`claude mcp add dsdb -- ds mcp`, or an `.mcp.json` entry.

*Built:* `docs/references/author/tools/mcp.md`, in the
Author's Reference's tools part after DAP, and a paragraph in its index.

**10.5 A walkthrough for agents.** The loop taught by example, where an agent
meets it when it works on DS: a project skill, or a section of 10.4's page.
MCP prompts are not the place; they are user-invoked templates.

*Built, a skill:* `dsdb/skills/dsdb/SKILL.md`,
shipped in the package, since this repository ignores `.claude/`; 10.4's page
says where to copy it. The loop with each tool's arguments, a recorded trace's
debugging, and what trips agents up.

**10.6 `whynot`.** The §13 wishlist's "why didn't this rule fire", the question
an agent will ask most. The deepest partial match comes from `rete`'s chains
with the calls there are today: which pattern had candidates, which join held
tokens, where the chain stops. Which join test rejected which pair needs libds's
node contents, and waits for them. A shell command and a tool.

*Built:* `Rete.whynot` in `lib/core/rete.js`, `whynotLines` in
`lib/text/rete.js`, the shell's `whynot RULE` and the `whynot` tool; how it
reads the chain is in DSTRACE_INTERACTIVE §13. Where a join's rejection would
be named, it says that waits for them.

**10.7 `outputSchema` for each tool** (MCP 2025-06-18), from `json.js`'s
projections, now that they have settled, so a client can check what it gets.

*Built:* `json.js` holds each projection's schema beside it
(`SHAPES`, `resultSchema`, `outputSchema`), and `tools.js` names the result
types each tool gives (`RETURNS`), plus those any tool may (a note, an error,
a refusal) and `more` for a bounded one. An item is one of those, or any object
with a `type`: a result type a tool was not thought to give still validates, so
a client never refuses a result for a gap in the list. `tools/list` includes
`outputSchema` always: both revisions spoken (§6) have it.
`mcp.test.mjs` checks results from most tools against the types they name, not
the catch-all.

**10.8 Real calls, opt in.** `ds mcp --calls SOCK` wires a live session's
calls to a responder over the calls socket (DSDB.md §9.1), for an agent testing
against a real one. By default dsdb stays the integrator and the agent answers.

*Built:* `ds mcp --calls SOCK [--call-timeout SECONDS]`
connects at start (a socket nobody listens on is exit 4). After each tool
call, when the current timeline is a live `%0` and point is at its end, each
call not yet sent goes out as §9.1's line, and a call that does not wait
(§9.1, "What waits") is not waited for; the replies back within the timeout
(5 s) are made together, in call order, as `from here answer` and `fail` are,
and the calls those make go out in turn, until none is new or none is
answered. The tool's result says what was sent and holds what the replies
did. Anywhere else (a hypothesis, a point behind the end, a replay) the agent
answers, as without a responder. A reply that cannot be delivered is said, as
in batch mode.

**Deferred: cancellation.** The one part that costs more than it looks. The
engine work is synchronous, so the server cannot read `notifications/cancelled`
while a tool runs: stdin would move to a worker thread, setting a cancel flag in
shared memory that 10.3's progress hook checks, stopping the work. And
"cancelled leaves the state as it was" makes every edit build first and swap
after; `%0`'s rebuild does, the hypotheses' rebuild changes things as it goes
and would have to be restructured. Built when a trace is large enough that
someone wants to stop a call.

**`ds mcp` on the wasm target.** It runs on either target, as every tool in the
portable `ds-tools` package does. Under
wasm it compiles with ds_dsc. `main.js` still loads `lib/mcp/` only for
that subcommand, so nothing else that runs dsdb brings it along.

`move`'s `step` pumps a live `%0` at its end as `n` does (§4.5), since there the
next point exists only once pumped.

## 11. Open

Nothing for the server itself; cancellation is deferred (§10).

---
name: dsdb
description: Write, run and debug DS rule programs with the dsdb MCP server (tools named load, define, from_here_emit, why, rete, …). Use when writing or changing a .ds program, finding out why a rule fired or did not, or debugging a recorded .dstrace.
---

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Debugging DS with dsdb

The dsdb server holds one session: a program, and its timelines (`%0`, the
live session or the recorded trace, and hypotheses `%1` and up), each with a
point in time. Build the program a definition at a time and watch what each
change does, rather than writing a whole file and guessing.

## The loop

**Start.** `load` with no arguments is a live session on an empty program.
`load {program: "rules.ds"}` starts from a file; add `trace: "run.dstrace"` to
replay a recording instead.

**Define.** One definition per `define`, as it stands in a `.ds` file, starting
at column 0:

```
define {text: "schema Reading scope logical:\n    entity_id: String key\n    level: Float mutable\n"}
define {text: "rule hot:\n    Reading r where r.level > 80.0\n->\n    emit Hot logical entity_id: r.entity_id\n"}
```

The program is compiled. If it does not compile, nothing changed and the error
comes back, its line numbers those of the program as `save_code` writes it. If
it does, every timeline runs again under it, and the result's `editDiff` says
what that did at point: facts gained (`+`) and lost (`-`), and firings per rule
before and after. Read it: it is the test of the edit. Defining a name again
replaces that definition; a replaced rule keeps its place in the rule order.

**Drive.** `from_here_emit {text: "Reading entity_id: \"a\" level: 85.0"}`
asserts an input at point and runs to quiescence; the result lists the records
it made. `advance {by: "5_s"}` lets time pass, for TTLs, windows and timers. In
a live session dsdb is the integrator: a service call waits in `calls` until
you `from_here_answer`, `from_here_fail` or `from_here_silence` it.

**Look.** None of these moves point; each takes `at` to answer elsewhere.

- `population`: live facts per schema, and the change since the settled point
  before.
- `facts {schema: "Hot"}`, or with `where: "f.level > 90.0"`.
- `query {body: "Reading r where r.level > 80.0"}`; several lines join; a last
  line `-> r.entity_id` projects; `over_time: true` says when each answer held.
- `firings`: the cascade that led to point; `scope: "all"` for every firing.
- `why {fact: "140"}` or `why {rule: "hot", timetag: "0x4f1"}`: the derivation
  tree, down to the inputs.
- `whynot {rule: "hot"}`: a rule that did not fire. Each pattern with the
  facts its test passes and those it turns away (and the failed test), the
  tokens at each join, and where the match stops. Start here, not with `rete`.
- `rete {rule: "^hot$"}`: what each node of the rule's chain holds.

**Change and repeat.** `define` again, `del {name: "hot"}`, or
`mv {rule: "hot", to: 1}` (rule order is firing order).

**Save.** `save_code {path: "rules.ds"}` writes the program as one file, in
DS's order with the rules in the rule order. `load` reads it back.

## Debugging a recorded trace

1. `load {program, trace}`, then `population {over_time: true}` for the shape of
   the run, and `firings {scope: "all", rule: "^alarm$"}` for when a rule fired.
2. `why {rule, timetag}` on a firing to see what it matched and where each fact
   came from; `why {fact}` on a fact.
3. To try a different input, `move {to: "1aba"}` to a point and
   `from_here_emit` (or `from_here_withdraw {fact}`): this opens a hypothesis
   beside the recording. `timelines` lists them; `switch {timeline: 0}` goes
   back.
4. To try a different program, `define`: an edit is for all time, and the
   recording and every hypothesis run again under it.

## Things that trip agents up

- **Names, not rows.** Facts are named by id, firings by rule and timetag, calls
  by number, points by position (`1aba`, `1aba-`), `start`, `end`, or a clock
  from the first record (`12_s`). Take them from one result into the next call.
- **Fact ids can change after an edit**, since `%0` runs again. Look them up
  again (`facts`) rather than reusing an old id.
- **Mid-cascade.** `rete` needs a settled point, one where the engine has run
  to quiescence; asked between, the refusal names the settled points either
  side: use one as `at`. `why` answers mid-cascade but cannot see which
  firings still support a fact, and says so.
- **Long results are cut.** Rows stop at `limit` (50) with how many more and a
  `cursor`; call again with the same arguments and the cursor. `why` stops at
  `nodes` (200); a node marked `…` goes on with `why` on it.
- **Refusals are results**, marked `isError`, with the shell's message: read
  it and adjust, do not retry unchanged.
- **Positions keep their meaning across an edit**, but may name a different
  moment in the rebuilt timeline; a point at a timeline's end stays at its end.

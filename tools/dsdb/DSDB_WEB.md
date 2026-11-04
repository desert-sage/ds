<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# dsdb from a webpage: one API, three transports

**Design · status: steps 1 to 5 of §8 built; shell lines (§7.2) and the fence built**

A graphical interface to dsdb, written separately, drives the same functions
the command line drives. dsdb provides the connection and the API. It never
contains web UI code.

## 1. Decisions

| Question | Decision |
|---|---|
| UI code in dsdb | **None, ever.** dsdb's one UI is the command line. This replaces DSDB.md §2's planned `lib/web/` ("results -> DOM"). |
| What a page drives | The functions the CLI drives, through dsdb's API layer; shell lines as text only where the host turns them on (§7.2). |
| Deployments | **Both, in order:** first a page talking to a native dsdb over a WebSocket (§4), then dsdb running inside the page over @ds-lang/ds on wasm (§5), immediately after. Both stay supported. |
| The WebSocket server in the wasm build | **Under Node, on either target**, as the MCP server is (DSDB_MCP.md §10). A page runs no server. |

## 2. Layers

```
lib/core/    the model and the session; no I/O, no Node (DSDB.md §2)
lib/text/    results -> the shell's lines
lib/api/     NEW: the typed operations, results as JSON, their schemas; no Node
lib/cli/     the dsdb command                          Node, either target
lib/mcp/     MCP over stdio, on lib/api                Node, either target
lib/serve/   NEW: JSON-RPC over a WebSocket, on lib/api Node, either target
```

`lib/core` and `lib/text` import nothing from Node. `lib/api` keeps that rule, and a test enforces it for all three:
no `node:` import, no `process`, no `Buffer`, and nothing from `cli`, `mcp` or
`serve`.

## 3. The API (`lib/api/`)

What DSDB_MCP.md built for agents, less its MCP naming, becomes the API:

- **Operations:** today's tool table (`lib/mcp/tools.js`). Each has a name, a
  JSON Schema for its arguments, and a runner over one session. It covers
  loading, the program's definitions, timelines, time, the looking commands
  and from-here changes, bounded output (§10.1) and progress (§10.3).
- **Results as JSON:** `json.js`'s projections and their schemas (§10.7), the
  wire format every transport uses. Its one Node call (`Buffer` for base64)
  is replaced.
- **Opening a session from bytes,** not paths: `open({ program, trace })` takes
  `Uint8Array`s or text, and the ports (DSDB.md §3): the binding, the compiler,
  and a writer for what the session saves. `lib/cli/open.js` becomes the
  native caller that reads files first.

One protocol serves every transport: JSON-RPC 2.0, with the methods
`ops/list`, `ops/call` (an operation's name and arguments, answered as
`{ results, text }`), `ops/exec` where shell lines are on (§7.2),
`resources/list`, `resources/read`, and the notifications
`progress` and `resources/list_changed`. MCP maps `tools/list` and `tools/call`
onto the same calls.

A UI written against one transport works over another by changing only its
transport.

## 4. Path 1: a page talks to a native dsdb (first)

```
ds serve [--host 127.0.0.1] [--port 7373] [--origin URL]... [--token T] [-L DIR]...
           [--root DIR]... [--out DIR] [--shell-lines]
```

- **The WebSocket is hand-rolled,** as MCP's JSON-RPC is: the RFC 6455 opening
  handshake, text frames, ping and pong, close, no extensions. dsdb keeps its
  zero dependencies.
- **One session per connection.** A page reloading gets a new session.
- **Everything the CLI has:** compiling with the native `dsc`, real files,
  live sessions, and real calls with `--calls`.
- **Access:** see §7.
- **Files:** read and written only within `--root` and `--out`, the working
  directory by default, as `ds mcp`'s are (DSDB_MCP.md §7): a page's calls
  are not approved one by one at all.

## 5. Path 2: dsdb inside the page (immediately after)

The page imports `lib/api` and runs it in a worker, where the engine's
synchronous work cannot stall the page. It gets the result objects themselves
as well as their JSON: timelines, the network and derivation trees, with no
round trip. That is the richest source for graphics.

- **The same protocol over `postMessage`:** a small worker entry in `lib/api`
  speaks §3's JSON-RPC, so a UI written against the WebSocket runs in the page
  by changing its transport.
- **Ports from the page:** the binding is @ds-lang/ds on wasm; files come from a
  `File` or `fetch`; a save becomes a download the page offers.
- **Needed from @ds-lang/ds:** a browser entry. Its loader today is Node-only
  (`node:fs`, `node:module`, `node:path`, `createRequire`). A browser entry
  takes the `.wasm` as a URL or bytes and the emnapi runtime as an ES module.
- **Needed for compiling:** `ds_dsc`, the wasm compiler. A page that
  gives none gets an in-page dsdb that replays and inspects traces, but refuses
  what compiles (queries with conditions, `emit`, edits) and says so.

## 6. Kept out of the wasm build

- **`lib/cli`, `lib/mcp` and `lib/serve` are never imported from `lib/api` or
  `lib/core`.** The node-free test (§2) holds this.
- **The package's `exports`:** `dsdb/api` (node-free) is the entry for pages;
  `dsdb` (the CLI) and the transports are Node's.
- **The wasm lane runs `lib/api`'s tests and not the transports'**, as it
  already skips `mcp.test.mjs`.

## 7. Decided

1. **Access for `ds serve`:** a loopback address only; a token, printed at start or given with
   `--token`, that the page presents as `?token=` (a browser's WebSocket
   cannot set a header); and the page's `Origin`: a loopback page by
   default, otherwise only those `--origin` names. A client sending no
   `Origin` (a program, not a browser) is let in by its token. Wider access
   (another host, TLS) is not planned.
2. **Shell lines over the web.** A page offering a terminal needs "run this
   line; return the results and the text", which `Session.execute` is. MCP
   takes typed calls only (DSDB_MCP.md §1). It is an option for a web interface
   that wants to expose it. *Built:*
   `ops/exec { line, progress? }`, answered as `ops/call` is and unbounded, as
   the shell prints everything (`Api.line`). Off unless the host turns it on:
   `ds serve --shell-lines`, `startWorker({ shellLines: true })`; off, it is
   error -32601, saying how. `ops/list` says whether it is on (`shellLines`).
   A line's saves are fenced as a tool's are. MCP never offers it.

## 8. Build order

1. **`lib/api`:** move the tool table and the projections out of `lib/mcp`,
   add `open` from bytes, and add the node-free test. MCP runs on it,
   unchanged, and `mcp.test.mjs` holds that.
   *Built:* `lib/api/` holds `ops.js` (the operations; the class
   is `Api`, and `call` returns `{ results, text, isError, raw }`, where `raw`
   is the result objects), `json.js`, `bound.js`, `resources.js`, and
   `open.js`, which opens a session from bytes and ports. How a session is
   opened is the host's: `Api` takes a `load` (description, input schema,
   `open`). `cli/open.js` keeps what reads files and gives `nativeLoad`, by
   paths, to the MCP server. `test/api.test.mjs` holds the node-free rule for
   `lib/core`, `lib/text` and `lib/api`, and drives a session opened from
   bytes through the API on both targets.
2. **`ds serve`:** the WebSocket transport, tested in process by a
   hand-rolled client, as `mcp.test.mjs` drives stdio.
   *Built:* the protocol is `lib/api/rpc.js` (node-free, for the
   worker too); `lib/serve/ws.js` the WebSocket's server end (handshake,
   masked frames, fragments, ping and pong, close; a binary message refused,
   1003; past 16 MiB, 1009); `lib/serve/server.js` the access checks and a
   session per connection, requests answered in order. `--calls` is not
   offered: one calls socket cannot serve several sessions. Raw shell lines
   are offered with `--shell-lines` (§7.2). `test/serve.test.mjs`.
3. **@ds-lang/ds's browser entry.** This is @ds-lang/ds's work, filed against it.
   *Built:* the binding's API is
   `lib/bind.js`, node-free, taking a host (a file for `recordTo`, the
   compiler); `lib/index.js` is Node's loader, and `lib/browser.js` a page's:
   `open({ glue, runtime, wasmBinary? })`, with `recordTo` to a sink only and
   compiling refused until step 5. `package.json` gives `.` a `browser` condition,
   and `./browser`. `test/browser.test.mjs`.
4. **The worker entry** and an in-page test on the wasm target: `lib/api`
   over the browser entry, with the wasm and runtime handed in as bytes.
   There's no browser in the lanes, so Node stands in for one, with nothing
   from Node imported.
   *Built:* `lib/api/bytes.js` is `load` from base64 (a `.dsc`,
   or a trace embedding its program); `lib/api/worker.js` is `startWorker({ ds
   })`, the protocol as text on the worker's messages, and a save sent to
   the page as a `saved` notification (`{ path, data }`, base64);
   `lib/api/index.js` is `dsdb/api`, and `dsdb/api/worker` the worker's.
   `test/worker.test.mjs` drives it by messages, on the wasm lane over
   @ds-lang/ds's browser entry.
5. **Compiling in the page,** once the wasm compiler is built.
   *Built:* ds_dsc, the Mercury `dsc` for wasm, byte-identical to the native
   over the corpus through @ds-lang/ds's wasm runner. A page passes it to
   `open({ ..., compiler })` and to `startWorker({ ds, compile })`. dsdb's side:
   `emptyProgram` awaits the compiler; `load` from bytes takes a `.ds` when a
   compiler is given; an edit's program is staged in the compiler's own file
   system (`compileFiles`). `test/worker.test.mjs` drives the whole loop in a
   worker with an async compiler (a `.ds` loaded, an empty program built up,
   an emit, a firing). It is built for wasm32, so it asks no browser and no Node
   for memory64.

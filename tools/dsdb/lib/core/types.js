// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// dsdb's shared types: what it takes from @ds-lang/ds, and the results its
// commands give, named once. JSDoc typedefs only, for `tsc --checkJs` (JS.13);
// the module holds no value, and must not, since a page loads dsdb's core.

/** @import { EditResult } from "./edit.js" */
/** @import { CellValue } from "./facts.js" */
/** @import { Answer, CompiledQuery } from "./query.js" */
/** @import { ReteResult } from "./rete.js" */
/** @import { Call, Fact, Firing, Timeline } from "./timeline.js" */
/** @import { WhyRoot } from "./why.js" */

/**
 * The `@ds-lang/ds` API dsdb runs on, from `open()`: under Node or in a page.
 * @typedef {import("@ds-lang/ds").Api<import("@ds-lang/ds").Host>} Ds
 */

/**
 * The compiler a session has: DS source to a `.dsc`, synchronously natively
 * and asynchronously under wasm. `file` names the source in its messages;
 * `searchPath` is where its imports are found, and `files`, by path, what the
 * compiler's own file system holds there (a page's compiler has no other).
 * @typedef {(source: string, opts: { file: string, searchPath?: string[], files?: Record<string, string> })
 *     => Promise<Uint8Array> | Uint8Array} Compile
 */

/**
 * One result of a command: what a front end renders (text/session.js) or
 * projects (api/json.js). `type` names its shape. A `logs` result is the
 * `log` lines a move crossed: `firing` the firing's index in `tl.firings`,
 * `at` its first position, `line` as the engine logged it, `LEVEL: message`.
 * @typedef {{ type: "note" | "error", text: string }
 *   | { type: "where", tl: Timeline, k: number, timeline?: number }
 *   | { type: "issued", tl: Timeline, k: number, calls: Call[], more: number }
 *   | { type: "pastEnd", tl: Timeline }
 *   | { type: "noSeq", seq: bigint }
 *   | { type: "bars", head: "at" | "cascade", tl: Timeline, k: number, rows: Array<[string, number, number]>,
 *       width: number }
 *   | ({ type: "firings", tl: Timeline,
 *       head: { scope: ":", count: number } | { scope: "cascade", k: number, count: number }, firings: Firing[] }
 *       & Paged)
 *   | { type: "histogram", tl: Timeline, k: number, rows: Array<[string, number[], number, number | ""]>,
 *       edges: bigint[], t0: bigint, head: [string, string] }
 *   | { type: "answerCount", tl: Timeline, k: number, count: number, timeline?: number }
 *   | ({ type: "answers", tl: Timeline, k: number, answers: Answer[], compiled: CompiledQuery } & Paged)
 *   | ({ type: "answersOverTime", tl: Timeline, groups: Answer[][], compiled: CompiledQuery } & Paged)
 *   | { type: "watchDiff", tl: Timeline, compiled: CompiledQuery, added: Answer[], removed: Answer[] }
 *   | { type: "forked", num: number, from: number, tl: Timeline, k: number, unreliable: string | null }
 *   | { type: "discarded", num: number, tl: Timeline, k: number }
 *   | { type: "midCascade", word: string, tl: Timeline, lo: number, hi: number }
 *   | { type: "timelines", rows: TimelineRow[] }
 *   | { type: "matchTrace", steps: Array<Array<[string, string]>> }
 *   | { type: "changeList", tl: Timeline, changes: Array<{ n: number, text: string, at: number }> }
 *   | { type: "newRecords", tl: Timeline, from: number, k: number }
 *   | { type: "recomputed", tl: Timeline, k: number }
 *   | { type: "replyEmit", schema: string, fields: Array<[string, ReplyField]> }
 *   | { type: "compareAnswers", lines: CompareLine[],
 *       summary: Array<{ n: number, count: number, tl: Timeline, k: number }> }
 *   | { type: "populationTable", timelines: number[], rows: Array<[string, number[]]> }
 *   | { type: "factView", tl: Timeline, fact: Fact }
 *   | { type: "firingView", tl: Timeline, firing: Firing }
 *   | ({ type: "calls", tl: Timeline, k: number, calls: Call[] } & Paged)
 *   | { type: "answerView", tl: Timeline, answer: Answer, compiled: CompiledQuery }
 *   | ReteResult
 *   | { type: "why", tl: Timeline, k: number, root: WhyRoot }
 *   | EditResult
 *   | { type: "banner", tl: Timeline, k: number }
 *   | { type: "listing", tl: Timeline, k: number, around: number, offset?: number, limit?: number }
 *   | { type: "refresh", count: number }
 *   | { type: "logs", tl: Timeline, lines: Array<{ firing: number, at: number, line: string }> }
 *   | { type: "help" | "quit" }
 *   | { type: "more", count: number, cursor: string }
 * } Result
 */

/**
 * Where a bounded result starts in its rows, and how many it had: set by
 * api/bound.js when it cuts a result for an agent (DSDB_MCP.md §10.1), which
 * a `more` result then follows. A listing is paged by `offset` and `limit`.
 * @typedef {{ offset?: number, total?: number }} Paged
 */

/**
 * One answer of a query over several timelines (§4.8): `mark` is `+` for
 * an answer only the others have, `-` for one only the baseline has; `tn` is
 * the timeline it is shown from, `tags` the timelines that have it when
 * more than two are compared.
 * @typedef {{ mark: string, n: number, answer: Answer, compiled: CompiledQuery, tl: Timeline, tn: number,
 *     base: number, tags: number[] | null }} CompareLine
 */

/**
 * One field of a reply typed at the prompt, as the shell shows it: a
 * response's slot as its typed value, a CallError's by its kind.
 * @typedef {{ value: CellValue } | { str: string | null } | { int: bigint }} ReplyField
 */

/**
 * One timeline as `hyp` lists it: `%0`, or a hypothesis with its fork and
 * change counts. `mem` is its bytes; `extra` what else the listing says.
 * @typedef {{ n: number, reality: true, tl: Timeline, k: number, extra: string, mem: number, current: boolean }
 *   | { n: number, reality: false, tl: Timeline, k: number, forkK: number, counts: string, extra: string,
 *       mem: number, current: boolean }} TimelineRow
 */

export {};

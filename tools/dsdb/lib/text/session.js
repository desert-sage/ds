// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The session's results as the shell prints them (DSDB.md §3): each result
// to its lines, byte-identical to what tools/dstrace_shell/shell.py says for
// the same command. Formats only; every number and choice was made in core.

import { fixed, ljust, rjust, width } from "./py.js";
import { bars, callLine, clock, factRef, factView, firingLine, firingView, hex8, histogram, listing,
         pointLabel, recordLine, slotsText, value, where } from "./render.js";
import { reteDotLine, reteLines, reteSchemaLines, whynotLines } from "./rete.js";
import { whyLines } from "./why.js";
import { definitionLines, editDiffLines, editedLines, programLines, ruleListLines, savedCodeLine } from "./edit.js";

/** @import { Answer, CompiledQuery } from "../core/query.js" */
/** @import { Prompt } from "../core/session.js" */
/** @import { Timeline } from "../core/timeline.js" */
/** @import { Result } from "../core/types.js" */

/** The records that describe a session rather than happen in it. */
const SESSION_HEAD = new Set(["StreamHeader", "SchemaDef", "Slot"]);

/** shell.py's HELP, and stage 7's lines. */
export const HELP = `queries and counts: a sigil, then a scope
  #.  #:  #@N      facts per schema: at point, over time, at N
  !.  !:  !@N      rule firings: that led to point, all of them, that led to N
  ^.  ^:  ^@N      firings per rule, the same three ways
  ?.Q  ?:Q  ?@N Q  answers to query Q: at point, over time, at N
  #.Q  #:Q  #@N Q  how many answers: at point, population over time, at N
  Q is a rule's left-hand side: \`Reading r where r.level > 80.0\`
  Q -> a, b        show these values for each answer, not the facts
  ?.(              a join: one pattern per line, then a line of just )
  after \`#:\` or \`^:\`: /regex/ to filter names; trailing \`tumbling 1_s\`, \`min|max|mean\`
  ?.%0 %1 Q        compare timelines: + only in the others, - only in the first
changes at point: at the end of a live %0 they apply to it; anywhere else
in %0 they open a hypothesis
  from here emit Schema slot: value …   assert an input and run to quiescence
  from here withdraw #N                 retract a live fact
  from here answer N JSON               reply to call N
  from here fail N code: "…" message: "…"
  from here silence N                   drop call N's recorded reply
  @+5_s  n         at the end: advance the clock (live) or feed reality (a hypothesis)
timelines
  hyp              list them          %            the current one
  fg %N  real      switch; real is fg %0
  bg %N  stop %N   %N follows %0's point, or stays where it is
  fork             a new hypothesis at point      kill %N   close one
  save trace [%N] PATH   write a timeline as a trace
  changes          this timeline's changes at a point, each where it was made
  save code PATH   write the program as one file
  ls  ls rules     the program's definitions; the rule order, with firings
the program: edited for all time, every timeline run again
  schema …, rule NAME: …, service …   a definition, to two blank lines: added, or replacing
  del NAME         remove a definition; del KIND NAME, del use, del import MODULE
  mv RULE N        move a rule in the rule order; mv RULE before|after OTHER
  show rule NAME   the rule's text
watching
  watch Q          show Q's answers arriving (+) and leaving (-) on every move
  unwatch
  next change      move to where the watched answers next change; prev change
navigation
  @N  @N-          a hex position; a trailing - is the unnamed point before it
  @+10  @-3        move by records (decimal)
  @12_s  @+500_ms  a clock time, or a move by one (the _ is required)
  @<  @>  @        the start, the end (@$ too), where point is
  @#N              the first position of histogram bucket N
  n  p             the next or previous settled point
  n atom|fire|tick one record, rule firing or clock advance
inspecting
  N                drill into row N of the last listing
  up  <  >  @[  @] back; prior or next version; where the fact began or ended
  match            the inspected fact through the network's alpha tests
  why              what led to the fact or firing shown; also why #N, why !N,
                   why RULE TT, and \`depth D\` after any
  calls  calls all waiting calls; every call
  list [K]         K records either side of point (default 10)
the matching network
  rete [@N] [/re/] each rule's chain at point: facts, tokens, activations
  rete schemas     alpha nodes by schema; rete dot FILE, the graph as Graphviz
  whynot RULE      how far the rule matches at point, and where it stops
  quit`;

/**
 * `r = Reading#3  entity_id="b"  level=95.0`, or `r = #3` for a fact the
 * trace does not hold.
 * @param {Timeline} tl
 * @param {string} name
 * @param {bigint} id
 */
export function bindingText(tl, name, id) {
    const f = tl.facts.get(id);
    if (f === undefined) return `${name} = #${id}`;
    return `${name} = ${factRef(f)}  ${slotsText(f.slots, f.untyped)}`;
}

/**
 * One answer: its projected values, or each binding's fact.
 * @param {Timeline} tl
 * @param {number} n  its row number
 * @param {Answer} a
 * @param {CompiledQuery} compiled
 */
export function answerLine(tl, n, a, compiled) {
    if (compiled.projection.length && a.values !== null) return `  ${n}  ` + a.values.join("  ");
    const names = compiled.bindings.map(([, b]) => b);
    const parts = [];
    for (let i = 0; i < Math.min(names.length, a.bindings.length); i++) parts.push(bindingText(tl, names[i], a.bindings[i]));
    return `  ${n}  ` + (parts.length ? parts.join("   ") : "true");
}

// The prompt, as `%1 @12 +1 unreliable ~ ` on a hypothesis (§4.9).
/**
 * The prompt: `[1 call] - `, or `- ` with none waiting, and on a
 * hypothesis its number, fork, change counts and state.
 * @param {Prompt} p
 */
export function promptText({ waitingCalls, hyp }) {
    const calls = waitingCalls ? `[${waitingCalls} call${waitingCalls !== 1 ? "s" : ""}] ` : "";
    if (hyp === null) return calls + "- ";
    const bits = [`%${hyp.number}`, `@${hyp.forkSeq}`];
    if (hyp.counts) bits.push(hyp.counts);
    if (hyp.unreliable) bits.push("unreliable");
    if (hyp.halted) bits.push("halted");
    return calls + bits.join(" ") + " ~ ";
}

const MiB = 1024 * 1024;

/**
 * One result as lines.
 * @param {Result} r  a result from core/session.js
 * @returns {string[]}
 */
export function resultLines(r) {
    switch (r.type) {
    case "banner":
        return [`${r.tl.length} records · ${where(r.tl, r.k)}`];
    case "refresh":
        return [`+${r.count} records`];
    case "logs": {
        // As `ds -b` writes a log line, with the firing's row in `!:`.
        const t0 = r.tl.clockAt(0);
        return r.lines.map(({ firing, at, line }) => {
            const c = line.indexOf(": ");
            const [level, message] = c < 0 ? ["", line] : [line.slice(0, c), line.slice(c + 2)];
            return `  !${firing + 1}  ${clock(r.tl.clockAt(at), t0)}  ${level}  ${message}`;
        });
    }
    case "note":
    case "error":
        return [`  ${r.text}`];
    case "where":
        return [`  ${r.timeline !== undefined ? `%${r.timeline} ` : ""}${where(r.tl, r.k)}`];
    case "issued": {
        const out = r.calls.map((c) => `  call ${c.number}  ${c.service}  as ${value(c.corr)}  by ${c.rule}  `
                                       + (c.waitingAt(r.k) ? "waiting" : c.outcome));
        if (r.more) out.push(`  … ${r.more} more; \`calls all\``);
        return out;
    }
    case "pastEnd": {
        const top = r.tl.name(r.tl.length);
        return [`  past the last position ${top ? pointLabel(r.tl, r.tl.length) : ""}`];
    }
    case "noSeq":
        return [`  no record has seq ${hex8(r.seq)}; the nearest earlier point`];
    case "listing":
        return listing(r.tl, r.k, r.around, r.offset, r.limit);
    case "bars": {
        const head = r.head === "cascade" ? `  cascade to ${where(r.tl, r.k)}` : `  ${where(r.tl, r.k)}`;
        return [head, ...bars(r.rows.map(([label, n, d]) => [label, n, d ? `  ${d > 0 ? "+" : ""}${d}` : ""]), r.width)];
    }
    case "histogram":
        return histogram(r.rows, r.edges, r.t0, r.tl.clockAt(r.k), pointLabel(r.tl, r.k), r.head);
    case "firings": {
        const head = r.head.scope === ":" ? `  ${r.head.count} firings in the trace`
            : `  cascade to ${where(r.tl, r.head.k)}   ${r.head.count} firings`;
        return [head, ...r.firings.map((f, i) => firingLine(r.tl, (r.offset ?? 0) + i + 1, f))];
    }
    case "factView":
        return factView(r.tl, r.fact);
    case "firingView":
        return firingView(r.tl, r.firing);
    case "calls":
        return r.calls.map((c) => callLine(r.tl, c, r.k));
    case "answerCount":
        return [`  ${r.timeline !== undefined ? `%${r.timeline}  ` : ""}${r.count} at ${where(r.tl, r.k)}`];
    case "forked":
        return [`  %${r.num}: a hypothesis forked from %${r.from} at ${pointLabel(r.tl, r.k)}`
                + (r.unreliable ? `  (unreliable: ${r.unreliable})` : "")];
    case "discarded":
        return [`  %${r.num}: records after ${pointLabel(r.tl, r.k)} discarded; recomputing`];
    case "recomputed":
        return [`  recomputed to ${where(r.tl, r.k)}`];
    case "timelines": {
        let total = 0;
        const out = r.rows.map((row) => {
            total += row.mem;
            const desc = row.reality
                ? `${ljust("reality", 22)}   ${ljust(pointLabel(row.tl, row.k), 11)}`
                : `forked ${pointLabel(row.tl, row.forkK)}  ${ljust(row.counts, 6)} ${ljust(pointLabel(row.tl, row.k), 11)}`;
            return ` ${row.current ? "*" : " "}%${ljust(String(row.n), 3)} ${desc}  ${ljust(row.extra, 12)} `
                + `${rjust(fixed(row.mem / MiB, 1), 6)} MiB`;
        });
        return [...out, `  total ${fixed(total / MiB, 1)} MiB`];
    }
    case "changeList": {
        const w = Math.max(...r.changes.map((c) => width(c.text)));
        return r.changes.map((c) => `  ${c.n}  ${ljust(c.text, w)}  at ${pointLabel(r.tl, c.at)}`);
    }
    case "matchTrace":
        return r.steps.map((st) => "  " + st.map(([k, x]) => `${k}=${value(x)}`).join("  "));
    case "compareAnswers":
        return [...r.lines.map((ln) => {
            const text = answerLine(ln.tl, ln.n, ln.answer, ln.compiled);
            return ln.mark + text.slice(1) + (ln.tn === ln.base ? "" : `  (%${ln.tn})`)
                + (ln.tags ? "  [" + ln.tags.map((t) => `%${t}`).join(" ") + "]" : "");
        }), "  " + r.summary.map((x) => `%${x.n}: ${x.count} at ${pointLabel(x.tl, x.k)}`).join("   ")];
    case "populationTable": {
        const lw = Math.max(6, ...r.rows.map(([sch]) => width(sch)));
        return ["  " + " ".repeat(lw) + r.timelines.map((n) => "  " + rjust(`%${n}`, 6)).join(""),
                ...r.rows.map(([sch, counts]) => `  ${ljust(sch, lw)}` + counts.map((n) => "  " + rjust(String(n), 6)).join(""))];
    }
    case "answers": {
        // A bounded result (DSDB_MCP.md §10.1) numbers from its offset and
        // counts them all.
        const n = r.total ?? r.answers.length;
        return [...r.answers.map((a, i) => answerLine(r.tl, (r.offset ?? 0) + i + 1, a, r.compiled)),
                `  ${n} answer${n !== 1 ? "s" : ""} at ${where(r.tl, r.k)}`];
    }
    case "answersOverTime": {
        const tl = r.tl, t0 = tl.clockAt(0);
        const lines = r.groups.map((spans, i0) => {
            const i = (r.offset ?? 0) + i0;
            const held = spans.map((s) =>
                `${pointLabel(tl, s.start + 1)}..${s.end !== null ? pointLabel(tl, s.end + 1) : "now"}`
                + ` ${clock(tl.clockAt(s.start + 1), t0)}..${s.end !== null ? clock(tl.clockAt(s.end + 1), t0) : ""}`)
                .join(", ");
            return answerLine(tl, i + 1, spans[0], r.compiled) + `   held ${held}`;
        });
        return [...lines, `  ${r.total ?? r.groups.length} distinct answers over the trace`];
    }
    case "watchDiff":
        return [...r.added.map((a) => "  + " + answerLine(r.tl, 0, a, r.compiled).trim().slice(3)),
                ...r.removed.map((a) => "  - " + answerLine(r.tl, 0, a, r.compiled).trim().slice(3))];
    case "answerView": {
        const names = r.compiled.bindings.map(([, b]) => b);
        const n = Math.min(names.length, r.answer.bindings.length);
        const out = [];
        for (let i = 0; i < n; i++) out.push(`  ${i + 1}  ` + bindingText(r.tl, names[i], r.answer.bindings[i]));
        return out;
    }
    case "newRecords": {
        // A live session's first change also makes its header and schema
        // records, which are not what the change did; `list` shows them.
        const recs = r.tl.records.slice(r.from, r.k).filter((rec) => !SESSION_HEAD.has(rec.kind));
        const out = recs.slice(0, 20).map((rec) => "  " + recordLine(rec));
        if (recs.length > 20) out.push(`  … ${recs.length - 20} more; \`list\``);
        out.push(`  ${where(r.tl, r.k)}`);
        return out;
    }
    case "replyEmit":
        // A CallError's fields are named by kind; a response's are its typed
        // slots, shown as the shell shows any slot.
        return [`  emit ${r.schema} ` + r.fields.map(([k, v]) =>
            `${k}: ${"str" in v ? value(v.str) : "int" in v ? v.int.toString() : value(v.value)}`)
            .join(" ")];
    case "rete":
        return reteLines(r);
    case "reteSchemas":
        return reteSchemaLines(r);
    case "reteDot":
        return [reteDotLine(r)];
    case "whynot":
        return whynotLines(r);
    case "why":
        return whyLines(r);
    case "programList":
        return programLines(r);
    case "definitionList":
        return definitionLines(r);
    case "ruleList":
        return ruleListLines(r);
    case "savedCode":
        return [savedCodeLine(r)];
    case "edited":
        return editedLines(r);
    case "editDiff":
        return editDiffLines(r);
    case "midCascade":
        return [`  \`${r.word}\` mid-cascade is refused: the settled points either side are `
                + `${pointLabel(r.tl, r.lo)} and ${pointLabel(r.tl, r.hi)}`];
    case "code":
        return r.text.replace(/\n$/, "").split("\n");
    case "more":
        return [`  … ${r.count} more; cursor "${r.cursor}"`];
    case "help":
        return HELP.split("\n");
    case "quit":
        return [];
    default:
        throw new TypeError(`no text for a result of type ${/** @type {{ type: string }} */ (r).type}`);
    }
}

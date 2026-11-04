// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `why` as the shell prints it (DSTRACE_INTERACTIVE §4.14): a derivation tree,
// drawn with box characters, every fact and firing numbered the first time and
// referred to after. Formats only; core/why.js built the tree. Stage 8 has no
// Python to match: the section's examples are the reference.

import { duration } from "../core/program.js";
import { is } from "../core/trace.js";
import { hexAlt, rjust } from "./py.js";
import { clock, factRef, pointLabel, slotsText, value } from "./render.js";

/** @import { Firing } from "../core/timeline.js" */
/** @import { Result } from "../core/types.js" */
/** @import { Causes, EndHow, EndStep, FactPart, Trigger, WhyNode, WhyRoot } from "../core/why.js" */

/**
 * The largest node number in a tree.
 * @param {WhyRoot | WhyNode} node
 * @returns {number}
 */
function most(node) {
    let n = "n" in node ? node.n : 0;
    for (const c of "children" in node ? node.children : []) n = Math.max(n, most(c));
    return n;
}

/**
 * `no (Ack a where …)`, as §4.14 writes an absence.
 * @param {string} p
 */
const absence = (p) => (/^no \(/.test(p) ? p : p.replace(/^no /, "no (") + ")");

/**
 * @param {Extract<Result, { type: "why" }>} r
 * @returns {string[]}
 */
export function whyLines(r) {
    const tl = r.tl, t0 = tl.clockAt(0);
    const w = String(most(r.root)).length;
    /** @param {number} n */
    const num = (n) => `${rjust(String(n), w)}  `;
    const blank = " ".repeat(w + 2);
    /** @param {number} i  a record index */
    const at = (i) => `${pointLabel(tl, i + 1)} ${clock(tl.clockAt(i + 1), t0)}`;
    /** @param {bigint} ns */
    const secs = (ns) => clock(ns, 0n);
    /** @param {number} ref */
    const see = (ref) => (ref === 0 ? "(the root)" : `(see ${ref})`);
    /** @param {Firing} fr */
    const firingText = (fr) => `${fr.rule}  tt ${hexAlt(fr.timetag)}  fired ${at(fr.begin)}`;
    /** @param {FactPart} x */
    const factText = (x) => {
        const f = x.fact;
        let s = `${factRef(f)}  ${slotsText(f.slots, f.untyped)}   ${x.life ? `${x.life}, ` : ""}${at(f.asserted)}`;
        if (x.ended !== null) s += `, ended ${at(x.ended)}${f.cause ? ` ${f.cause}` : ""}`;
        return s;
    };

    /**
     * The lines a fact carries under it: where it came from.
     * @param {FactPart & Causes} x
     */
    const causeLines = (x) => {
        if (x.reply) return [`reply to call ${x.reply.number}: ${x.reply.service} as ${value(x.reply.corr)}`];
        if (x.input !== undefined) return [`input ${at(x.input)}`];
        if (x.emit === null) return [`emitted by: ${x.fact.rule} (its source is not available)`];
        return [`emitted by: ${x.emit.line}`, ...x.emit.lets.map((l) => `${" ".repeat(12)}${l}`)];
    };

    /**
     * @param {WhyNode} x
     * @returns {string}
     */
    const head = (x) => {
        switch (x.kind) {
        case "firing":
            return num(x.n) + (x.support ? "supported by " : "") + firingText(x.firing) + (x.cut ? "  …" : "");
        case "binding":
            return num(x.n) + (x.name ? `${x.name} = ` : "") + factText(x) + (x.cut ? "  …" : "");
        case "ref":
            return blank + ("firing" in x ? `${x.firing.rule}  tt ${hexAlt(x.firing.timetag)}`
                                          : (x.name ? `${x.name} = ` : "") + factRef(x.fact)) + `   ${see(x.ref)}`;
        case "absence":
            return `${blank}${absence(x.text)}   held at ${clock(x.clock, t0)}`;
        case "unrecorded":
            return `${blank}matched facts not recorded: a trace does not hold them, and no program engine replayed it`;
        case "missing":
            return `${blank}${x.name ? `${x.name} = ` : ""}#${x.id}   (not in this timeline)`;
        case "condition":
            return blank + condition(x);
        default:
            throw new TypeError(`no text for a tree node of kind ${/** @type {{ kind: string }} */ (x).kind}`);
        }
    };

    /** @param {Extract<WhyNode, { kind: "condition" }>} x */
    const condition = (x) => {
        if (x.what === "cooldown") {
            if (x.previous === null) return `cooldown ${duration(x.window)}: no earlier firing of the rule`;
            const gap = x.at - x.previous;
            return `cooldown ${duration(x.window)}: the rule last fired at ${clock(x.previous, t0)}, `
                + `${secs(gap)} before, ${gap >= x.window ? "past" : "within"} the window`;
        }
        return x.text + (x.ts.length ? "   " + x.ts.map(([nm, v]) => `${nm}.ts ${value(v)}`).join(", ") : "");
    };

    /** @type {string[]} */
    const out = [];
    /**
     * @param {string} prefix
     * @param {WhyNode} x
     * @param {boolean} kids
     */
    const under = (prefix, x, kids) => {
        const bar = kids ? "│  " : "   ";
        return (x.kind === "binding" ? causeLines(x) : []).map((l) => prefix + bar + l);
    };
    /**
     * @param {WhyNode} x
     * @param {string} prefix
     * @param {boolean} last
     */
    const walk = (x, prefix, last) => {
        const kids = "children" in x ? x.children : [];
        out.push(prefix + (last ? "└─ " : "├─ ") + head(x));
        const inner = prefix + (last ? "   " : "│  ");
        out.push(...under(inner, x, kids.length > 0));
        kids.forEach((c, i) => walk(c, inner, i === kids.length - 1));
    };

    const root = r.root, kids = root.children;
    const bar = kids.length ? "  │  " : "     ";
    if (root.kind === "fact") {
        const f = root.fact;
        // A root fact not live at point has ended: `why` refuses one not yet asserted.
        const state = root.live ? `live at ${pointLabel(tl, r.k)} ${clock(tl.clockAt(r.k), t0)}`
            : `ended ${at(/** @type {number} */ (f.ended))}${f.cause ? ` ${f.cause}` : ""}, not live at point`;
        out.push(`  ${factRef(f)}  ${slotsText(f.slots, f.untyped)}   ${root.life ? `${root.life}, ` : ""}${state}`);
        out.push(...causeLines(root).map((l) => bar + l));
        out.push(...endLines(root.end).map((l) => bar + l));
    } else {
        const fr = root.firing, rf = root.refraction;
        const ord = rf === null ? "" : rf.kind === "first" ? "   (1st firing for these facts)"
            : rf.kind === "again" ? "   (again, for the same facts)"
            : `   (re-firing: ${rf.changed.map(([a, b]) => `#${a} became #${b}`).join(", ")})`;
        out.push(`  ${firingText(fr)}${ord}`);
        out.push(...trigger(root.trigger).map((l) => bar + l));
    }
    kids.forEach((c, i) => walk(c, "  ", i === kids.length - 1));
    return out;

    /**
     * §4.14 "why it ended": how the root ended, then each fact whose end
     * ended the one above it.
     * @param {EndStep[] | null} steps
     * @returns {string[]}
     */
    function endLines(steps) {
        if (steps === null) return [];
        return steps.map((st, i) => {
            if (i === 0) return `ended: ${howText(st.how)}`;
            const f = st.fact;
            return `${" ".repeat(7)}→ ${factRef(f)} ended ${at(/** @type {number} */ (f.ended))}`
                + `${f.cause ? ` ${f.cause}` : ""}: ${howText(st.how)}`;
        });
    }

    /**
     * @param {EndHow} h
     * @returns {string}
     */
    function howText(h) {
        /** @param {Firing} fr */
        const by = (fr) => `${fr.rule}  tt ${hexAlt(fr.timetag)}`;
        switch (h.kind) {
        case "retracted":
            return "retracted by the integrator";
        case "ttl":
            return "its ttl ran out";
        case "replaced":
            return h.by === null ? "replaced, by a fact this timeline does not hold" : `replaced by ${factRef(h.by)}`;
        case "withdrawn":
            return h.firing === null ? "withdrawn by a firing this timeline does not hold" : `withdrawn by ${by(h.firing)}`;
        case "completed":
            return h.firing === null ? "the activation that emitted it completed" : `its activation, ${by(h.firing)}, completed`;
        case "lost":
            return `its support ${by(h.firing)} lost ${h.name ? `${h.name} = ` : ""}${factRef(h.lost)}`;
        case "absence":
            return `its support ${by(h.firing)} lost its absence: ${absence(h.pattern)} began to match `
                + (h.appeared.length === 1 ? factRef(h.appeared[0]) : `one of ${h.appeared.map(factRef).join(", ")}`);
        case "unknown":
            return "its support ended in this cascade, and the trace does not say how";
        default:
            throw new TypeError(`no text for an end of kind ${/** @type {{ kind: string }} */ (h).kind}`);
        }
    }

    /**
     * The input a cascade began with, and its chain to the firing: a clock
     * sample, a retract or an assert (core/why.js's #trigger).
     * @param {Trigger | null} t
     * @returns {string[]}
     */
    function trigger(t) {
        if (t === null) return [];
        const r0 = t.input;
        if (is(r0, "ClockAdvance"))
            return [`triggered by: time, the clock moving to ${clock(r0.body.clock_ns, t0)} ${at(r0.index)}`];
        if (is(r0, "FactRetract"))
            return [`triggered by: #${r0.body.fact_id} retracted ${at(r0.index)}${t.negated ? ", and the absence that made" : ""}`];
        if (!is(r0, "FactAssert")) return [];
        const lines = [`triggered by: input ${r0.body.schema_name}#${r0.body.fact_id} ${at(r0.index)}`
                       + (t.reached || !t.chain.length ? "" : ", not among what it matched")];
        for (const step of t.chain) {
            if (step.firing === null) continue;
            lines.push(`${" ".repeat(14)}→ ${factRef(step.fact)}, emitted by ${step.firing.rule} in this cascade`);
        }
        return lines;
    }
}

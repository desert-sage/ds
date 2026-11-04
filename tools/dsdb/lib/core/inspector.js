// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The inspector (DSTRACE_INTERACTIVE §4.6, §4.11) and calls (§4.10): drilling
// into a listing's rows, `up`, a fact's versions, `calls`. The port of
// shell.py's show, do_row, version and calls. Returns results; prints nothing.
//
// A row and a stack entry are `[kind, object]` (state.js's Row): kind `fact`
// (a Fact), `firing` (a Firing), `call` (a Call), `answer` (`[Answer,
// compiled query]`), `record` (a record), `node` (a row of `rete`, §4.13) or
// `why` (a node of a derivation tree, `["fact" | "firing", object]`, §4.14).

import { CONTENTS } from "./rete.js";
import { is } from "./trace.js";

/** @import { Row, SessionState, TreeItem } from "./state.js" */
/** @import { Fact } from "./timeline.js" */
/** @import { Result } from "./types.js" */

export class Inspector {
    /** @type {SessionState} */
    #s;
    /** @type {(item: TreeItem) => Result[]} */
    #expand;

    /**
     * @param {SessionState} state
     * @param {(item: TreeItem) => Result[]} [expand]  a tree node's own tree
     */
    constructor(state, expand = () => []) {
        this.#s = state;
        this.#expand = expand;
    }

    /**
     * Show an item and put it on the stack. Results: `factView`,
     * `firingView` or `calls`; a record shows nothing.
     * @param {Row} item
     * @returns {Result[]}
     */
    show(item) {
        const s = this.#s;
        const [kind, obj] = item;
        // Until libds lists a node's contents (§11.2), a node opens to nothing.
        if (kind === "node") return [error(CONTENTS)];
        // A tree node is expanded, and what it stands for is on the stack,
        // so `why` and `up` go on from it.
        if (kind === "why") {
            s.stack.push(obj);
            return this.#expand(obj);
        }
        s.stack.push(item);
        if (kind === "fact") {
            s.rows = [];
            return [{ type: "factView", tl: s.tl, fact: obj }];
        }
        if (kind === "firing") {
            s.rows = obj.effects.map((i) => this.#effectItem(i));
            return [{ type: "firingView", tl: s.tl, firing: obj }];
        }
        if (kind === "call") {
            s.rows = [];
            return [{ type: "calls", tl: s.tl, k: s.k, calls: [obj] }];
        }
        if (kind === "answer") {
            const [a, compiled] = obj;
            /** @type {Row[]} */
            const rows = [];
            for (const id of a.bindings) {
                const f = s.tl.facts.get(id);
                if (f !== undefined) rows.push(["fact", f]);
            }
            s.rows = rows;
            return [{ type: "answerView", tl: s.tl, answer: a, compiled }];
        }
        return [];
    }

    /**
     * `N`: row N of the last listing.
     * @param {number} n
     * @returns {Result[]}
     */
    row(n) {
        const s = this.#s;
        if (!(n >= 1 && n <= s.rows.length)) return [error(`no row ${n} in the last listing`)];
        return this.show(s.rows[n - 1]);
    }

    /**
     * `up`: back to what was shown before.
     * @returns {Result[]}
     */
    up() {
        const s = this.#s;
        if (s.stack.length <= 1) return [error("nothing to go up to")];
        s.stack.pop();
        return this.show(/** @type {Row} */ (s.stack.pop()));     // two or more were there
    }

    /**
     * The fact nearest the top of the stack, or null.
     * @returns {Fact | null}
     */
    currentFact() {
        const s = this.#s;
        for (let i = s.stack.length - 1; i >= 0; i--) {
            const [kind, obj] = s.stack[i];
            if (kind === "fact") return obj;
        }
        return null;
    }

    /**
     * `<` and `>`: the fact's prior or next version (§4.6).
     * @param {string} which
     * @returns {Result[]}
     */
    version(which) {
        const s = this.#s;
        const f = this.currentFact();
        if (f === null) return [error("`<` and `>` need a fact in the inspector")];
        const other = which === "<" ? f.prior : f.successor;
        const g = other === null ? undefined : s.tl.facts.get(other);
        if (g === undefined) return [error(`no ${which === "<" ? "prior" : "next"} version`)];
        return this.show(["fact", g]);
    }

    /**
     * `calls` (waiting at point) and `calls all`.
     * @param {boolean} showAll
     * @returns {Result[]}
     */
    calls(showAll) {
        const s = this.#s, tl = s.tl;
        const cs = showAll ? tl.calls : tl.waitingCalls(s.k);
        if (!cs.length) return [error("no calls" + (showAll ? "" : " waiting at point"))];
        s.rows = cs.map((c) => ["call", c]);
        return [{ type: "calls", tl, k: s.k, calls: cs }];
    }

    /**
     * A firing's effect, record `i`, as a row: the fact it emitted or
     * withdrew, the call it made, or the record itself.
     * @param {number} i
     * @returns {Row}
     */
    #effectItem(i) {
        const tl = this.#s.tl;
        const r = tl.records[i];
        if (is(r, "FactEmit", "FactWithdraw")) {
            const f = tl.facts.get(r.body.fact_id);
            if (f !== undefined) return ["fact", f];
        }
        const c = tl.calls.find((x) => x.issued === i);
        return c ? ["call", c] : ["record", r];
    }
}

/**
 * @param {string} text
 * @returns {Result}
 */
const error = (text) => ({ type: "error", text });

// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Where `ds mcp` and `ds serve` may read and write (DSDB_MCP.md §7): a
// path a client names is read only under a `--root` (the
// working directory when none is given) or `--out`, and written only under
// `--out` (the working directory when not given). The client's approval of a
// call does not widen it. A path is taken through its symbolic links first, so
// a link inside a directory does not lead out of it. What the person running
// dsdb names on its command line (-L, --calls) is theirs, and not fenced.

import { realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

/** A path outside the directories: the caller's to correct. */
export class Fenced extends Error {}

export class Fence {
    /** @type {string[]} the directories read under, through their links */
    #roots;
    /** @type {string} the directory written under, through its links */
    #out;
    /** @type {string} */
    #cwd;

    /**
     * Throws Fenced when a directory is not one.
     * @param {object} [o]
     * @param {string[]} [o.roots]  the directories to read under; none: the working directory
     * @param {string | null} [o.out]  the directory to write under; null: the working directory
     * @param {string} [o.cwd]  what a relative path is relative to
     */
    constructor({ roots = [], out = null, cwd = process.cwd() } = {}) {
        this.#cwd = cwd;
        /**
         * @param {string} d
         * @param {string} flag  the option that named it, for the refusal
         */
        const dir = (d, flag) => {
            try {
                return realpathSync(resolve(cwd, d));
            } catch (err) {
                throw new Fenced(`${flag} ${d}: ${err instanceof Error ? err.message : String(err)}`);
            }
        };
        this.#roots = (roots.length ? roots : [cwd]).map((d) => dir(d, "--root"));
        this.#out = dir(out ?? cwd, "--out");
    }

    /** The directories read under, and the one written under. */
    get roots() {
        return [...this.#roots];
    }

    get out() {
        return this.#out;
    }

    /**
     * `path` when it may be read: under a root or `--out`. Throws Fenced.
     * @param {string} path
     */
    readable(path) {
        const p = this.#real(path);
        if ([...this.#roots, this.#out].some((d) => within(d, p))) return path;
        throw new Fenced(`${path}: outside the directories dsdb may read (${[...new Set([...this.#roots, this.#out])].join(", ")}); `
                         + "--root adds one");
    }

    /**
     * `path` when it may be written: under `--out`. Throws Fenced, whose
     * message leaves the path to the caller, as a save's error names it.
     * @param {string} path
     */
    writable(path) {
        if (within(this.#out, this.#real(path))) return path;
        throw new Fenced(`outside the directory dsdb may write (${this.#out}); --out sets it`);
    }

    /**
     * Through its links; a part that does not exist yet is taken as named.
     * @param {string} path
     * @returns {string}
     */
    #real(path) {
        const abs = resolve(this.#cwd, String(path));
        try {
            return realpathSync(abs);
        } catch {
            const up = dirname(abs);
            return up === abs ? abs : join(this.#real(up), basename(abs));
        }
    }
}

/**
 * Whether path `p` is `dir` or under it.
 * @param {string} dir
 * @param {string} p
 */
function within(dir, p) {
    const r = relative(dir, p);
    return r === "" || !(r === ".." || r.startsWith(`..${sep}`) || isAbsolute(r));
}

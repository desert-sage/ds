// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The MCP server's resources (dsdb/DSDB_MCP.md §10.2): what a user
// attaches, read without a tool call. The program's text, the rule order, the
// timelines, and each timeline's whole listing, as the shell prints them.
// Nothing is listed until something is loaded.

import { resultLines } from "../text/session.js";

/** @import { Session } from "../core/session.js" */

/**
 * A resource as `resources/list` gives it (MCP).
 * @typedef {{ uri: string, name: string, title: string, description: string, mimeType: string }} Resource
 */

const TEXT = "text/plain";

/**
 * The fixed resources, by URI: what `Session.resource` is asked for each.
 * @type {Array<{ uri: string, what: "program" | "rules" | "timelines", name: string, title: string,
 *     description: string }>}
 */
const FIXED = [
    { uri: "dsdb://program", what: "program", name: "program", title: "The program",
      description: "the program's text, as save_code would write it: DS's order, rules in the rule order" },
    { uri: "dsdb://program/rules", what: "rules", name: "rules", title: "The rule order",
      description: "the rules in firing order, each with its first pattern and its firings up to point (ls rules)" },
    { uri: "dsdb://timelines", what: "timelines", name: "timelines", title: "The timelines",
      description: "%0 and each hypothesis: its fork, point, changes and memory" },
];

const LISTING = /^dsdb:\/\/timeline\/(\d+)\/listing$/;

export const TEMPLATES = [
    { uriTemplate: "dsdb://timeline/{n}/listing", name: "listing", title: "A timeline's listing",
      description: "every record of timeline n, with its point marked", mimeType: TEXT },
];

/** A resource that cannot be read: its JSON-RPC error. */
export class ResourceError extends Error {
    code = -32002;
}

/**
 * The resources of `session` (null: nothing loaded), for `resources/list`.
 * @param {Session | null} session
 * @returns {Resource[]}
 */
export function list(session) {
    if (session === null) return [];
    const fixed = FIXED.map(({ what, ...r }) => ({ ...r, mimeType: TEXT }));
    const listings = [...session.state.views.keys()].sort((a, b) => a - b).map((n) => ({
        uri: `dsdb://timeline/${n}/listing`, name: `listing %${n}`, title: `%${n}'s listing`,
        description: `every record of %${n}, with its point marked`, mimeType: TEXT }));
    return [...fixed, ...listings];
}

/**
 * `resources/read`: the contents of `uri`.
 * @param {Session | null} session
 * @param {string} uri
 * @returns {Array<{ uri: string, mimeType: string, text: string }>}
 * @throws {ResourceError}
 */
export function read(session, uri) {
    const fixed = FIXED.find((r) => r.uri === uri);
    const m = LISTING.exec(uri);
    const what = fixed !== undefined ? fixed.what : m !== null ? Number(m[1]) : null;
    if (what === null) throw new ResourceError(`no resource ${uri}`);
    if (session === null) throw new ResourceError(`${uri}: nothing is loaded; \`load\` a program first`);
    const results = session.resource(what);
    for (const r of results) if (r.type === "error") throw new ResourceError(`${uri}: ${r.text}`);
    const only = results.length === 1 ? results[0] : null;
    const text = only !== null && only.type === "code" ? only.text : results.flatMap(resultLines).join("\n") + "\n";
    return [{ uri, mimeType: TEXT, text }];
}

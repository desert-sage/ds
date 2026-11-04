// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The author book's tables of what `ds mcp` and `ds dap` answer, held to the
// code that answers it (R2.4). The pages keep their own prose and their
// grouping, which no source has, so they are checked and not generated: every
// tool with exactly its arguments, every capability with its value, and every
// exception filter with its label and default. CI selects this suite for the two
// pages.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { Api } from "../lib/api/ops.js";
import { nativeLoad } from "../lib/cli/open.js";
import { CAPABILITIES } from "../lib/dap/server.js";
import { EXCEPTION_FILTERS } from "../lib/dap/adapter.js";

/** @param {string} name */
const page = (name) => readFileSync(new URL(`../../../docs/references/author/tools/${name}`, import.meta.url), "utf8");

/**
 * The text of a page from the heading `from` up to the next heading of its level
 * or above.
 * @param {string} md @param {string} from
 */
function section(md, from) {
    const lines = md.split("\n");
    const start = lines.indexOf(from);
    if (start < 0) return "";
    const level = from.indexOf(" ");
    const end = lines.findIndex((l, i) => i > start && /^#+ /.test(l) && l.indexOf(" ") <= level);
    return lines.slice(start + 1, end < 0 ? undefined : end).join("\n");
}

/**
 * A table's body rows whose first cell is one code span, as that name and the
 * cells after it. A header row, the one above a `|---`, is no entry.
 * @param {string} md
 * @returns {Map<string, string[]>}
 */
function rows(md) {
    const out = new Map();
    const lines = md.split("\n");
    lines.forEach((line, i) => {
        const m = /^\| `([^`]+)` \|(.*)\|$/.exec(line);
        if (m && !lines[i + 1]?.startsWith("|---")) out.set(m[1], m[2].split("|").map((c) => c.trim()));
    });
    return out;
}

/** @param {string} cell */
const spans = (cell) => [...cell.matchAll(/`([^`]+)`/g)].map((m) => m[1]);

/**
 * How `ds mcp`'s page and its tools differ: nothing when they agree.
 * @param {string} md  the page
 * @param {Array<{ name: string, inputSchema: { properties?: object } }>} tools
 * @returns {string[]}
 */
function toolDrift(md, tools) {
    const table = rows(section(md, "## Tools"));
    const drift = [];
    for (const { name, inputSchema } of tools) {
        const cells = table.get(name);
        if (cells === undefined) {
            drift.push(`${name}: a tool the page has no row for`);
            continue;
        }
        const on = [...spans(cells[0])].sort().join(" ");
        const code = Object.keys(inputSchema.properties ?? {}).sort().join(" ");
        if (on !== code) drift.push(`${name}: the page says [${on}], the tool takes [${code}]`);
    }
    const known = new Set(tools.map((t) => t.name));
    for (const name of table.keys()) if (!known.has(name)) drift.push(`${name}: a row for no tool`);
    return drift;
}

/**
 * How `ds dap`'s page and its capabilities and filters differ.
 * @param {string} md  the page
 * @param {Record<string, unknown>} capabilities
 * @param {ReadonlyArray<{ filter: string, label: string, default: boolean }>} filters
 * @returns {string[]}
 */
function capabilityDrift(md, capabilities, filters) {
    const table = rows(section(md, "### Capabilities"));
    const drift = [];
    for (const [name, value] of Object.entries(capabilities)) {
        const cells = table.get(name);
        if (cells === undefined) drift.push(`${name}: a capability the page has no row for`);
        // The filters' own table states them, and its row only links there.
        else if (name !== "exceptionBreakpointFilters" && spans(cells[0])[0] !== JSON.stringify(value))
            drift.push(`${name}: the page says ${cells[0]}, the adapter ${JSON.stringify(value)}`);
    }
    for (const name of table.keys())
        if (!Object.hasOwn(capabilities, name)) drift.push(`${name}: a row for no capability`);
    const declared = rows(section(md, "### Exception breakpoints"));
    for (const { filter, label, default: on } of filters) {
        const cells = declared.get(filter);
        if (cells === undefined) drift.push(`${filter}: a filter the page has no row for`);
        else if (cells[0] !== label || cells[cells.length - 1] !== `\`${on}\``)
            drift.push(`${filter}: the page says ${cells[0]}, ${cells[cells.length - 1]}; the adapter ${label}, ${on}`);
    }
    for (const name of declared.keys())
        if (!filters.some((f) => f.filter === name)) drift.push(`${name}: a row for no filter`);
    return drift;
}

// `load` is the host's, and its schema is all this reads, so no fence is needed.
const TOOLS = new Api({ load: nativeLoad([], /** @type {never} */ (null)) }).list({ outputSchemas: false });

test("tools/mcp.md lists every tool, with exactly its arguments", () => {
    assert.ok(TOOLS.length > 30, "the tools were read");
    assert.deepEqual(toolDrift(page("mcp.md"), TOOLS), []);
});

test("tools/dap.md states every capability and exception filter as the adapter declares it", () => {
    assert.deepEqual(capabilityDrift(page("dap.md"), CAPABILITIES, EXCEPTION_FILTERS), []);
});

const MCP = `## Tools

| Tool | Arguments | Result |
|---|---|---|
| \`one\` | none | r |
| \`two\` | \`a\`; \`b\` | r |

## Result bounds

| \`three\` | \`c\` | outside the section |
`;
const one = { name: "one", inputSchema: { properties: {} } };
const two = { name: "two", inputSchema: { properties: { a: {}, b: {} } } };

test("toolDrift holds what it reads, and refuses each way a page parts from the tools", () => {
    assert.deepEqual(toolDrift(MCP, [one, two]), []);
    assert.match(toolDrift(MCP, [one, two, { name: "three", inputSchema: {} }])[0], /^three: a tool the page has no row/);
    assert.match(toolDrift(MCP, [one])[0], /^two: a row for no tool/);
    assert.match(toolDrift(MCP, [one, { name: "two", inputSchema: { properties: { a: {} } } }])[0],
                 /^two: the page says \[a b\], the tool takes \[a\]/);
    assert.match(toolDrift(MCP, [one, { name: "two", inputSchema: { properties: { a: {}, b: {}, c: {} } } }])[0],
                 /^two: the page says \[a b\], the tool takes \[a b c\]/);
    assert.match(toolDrift("# no such section\n", [one])[0], /^one: a tool the page has no row/);
});

const DAP = `### Capabilities

| Capability | Value |
|---|---|
| \`supportsX\` | \`true\` |
| \`columns\` | \`[]\` |
| \`exceptionBreakpointFilters\` | [the filters](#f) |

## Next

### Exception breakpoints

| \`filter\` | \`label\` | Stops when | \`default\` |
|---|---|---|---|
| \`fault\` | Fault | a fault | \`false\` |
`;
const capabilities = { supportsX: true, columns: [], exceptionBreakpointFilters: [] };
const fault = { filter: "fault", label: "Fault", default: false };

test("capabilityDrift holds what it reads, and refuses each way a page parts from the adapter", () => {
    assert.deepEqual(capabilityDrift(DAP, capabilities, [fault]), []);
    assert.match(capabilityDrift(DAP, { ...capabilities, supportsX: false }, [fault])[0], /^supportsX: the page says/);
    assert.match(capabilityDrift(DAP, { ...capabilities, supportsY: true }, [fault])[0], /^supportsY: a capability the page has no row/);
    const { columns: _gone, ...fewer } = capabilities;
    assert.match(capabilityDrift(DAP, fewer, [fault])[0], /^columns: a row for no capability/);
    assert.match(capabilityDrift(DAP, capabilities, [{ ...fault, label: "Other" }])[0], /^fault: the page says Fault/);
    assert.match(capabilityDrift(DAP, capabilities, [{ ...fault, default: true }])[0], /^fault: the page says Fault, `false`/);
    assert.match(capabilityDrift(DAP, capabilities, [fault, { filter: "new", label: "New", default: false }])[0], /^new: a filter the page has no row/);
    assert.match(capabilityDrift(DAP, capabilities, [])[0], /^fault: a row for no filter/);
});

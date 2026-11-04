// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The shell's terminal (DSDB.md §3, the `terminal` port): a prompt, a line,
// the session's results printed as text, until `quit` or the end of input.
// A line ending in `(` opens a block that a line of just `)` closes
// (DSTRACE_INTERACTIVE §4.2); a DS definition runs to two blank lines (§4.16).
// The port of shell.py's run().

import readline from "node:readline";

import { header } from "../core/program-text.js";
import { promptText, resultLines } from "../text/session.js";

/** @import { Session } from "../core/session.js" */
/** @import { Result } from "../core/types.js" */

/**
 * A terminal: `read` shows the prompt and gives the next line, or null at
 * the end of input; `write` prints one line.
 * @typedef {{ read: (prompt: string) => Promise<string | null>, write: (line: string) => void }} Terminal
 */

/**
 * Run a session at a terminal.
 * @param {Session} session
 * @param {Terminal} term
 * @returns {Promise<number>} the exit status: 0
 */
export async function runShell(session, term) {
    /** @param {Result[]} results */
    const say = (results) => { for (const r of results) for (const ln of resultLines(r)) term.write(ln); };
    say(session.banner());
    for (;;) {
        let line = await term.read(promptText(session.prompt()));
        if (line !== null && line.trimEnd().endsWith("(")) {
            const block = [line];
            for (;;) {
                const more = await term.read("... ");
                if (more === null) { line = null; break; }
                block.push(more);
                if (more.trim() === ")") break;
            }
            if (line !== null) line = block.join("\n");
        } else if (line !== null && header(line) !== null) {
            // A definition (§4.16) runs to two blank lines, so a single one
            // inside it is part of it.
            const block = [line];
            for (;;) {
                const more = await term.read("... ");
                if (more === null) break;
                if (!more.trim() && block.length && !block[block.length - 1].trim()) {
                    block.pop();
                    break;
                }
                block.push(more);
            }
            line = block.join("\n");
        }
        // The end of input, or an interrupt: a newline, and done, as the
        // Python's EOFError and KeyboardInterrupt are.
        if (line === null) {
            term.write("");
            return 0;
        }
        const results = await session.execute(line);
        say(results);
        if (results.some((r) => r.type === "quit")) return 0;
    }
}

/**
 * A terminal on stdin and stdout: readline with line editing and history
 * when both are a TTY; otherwise lines as they come, with the prompt written
 * as Python's input() writes it, so a piped session prints what the Python's
 * does.
 * @param {{ stdout: (s: string) => void }} io
 * @returns {Terminal & { close: () => void }}
 */
export function stdTerminal(io) {
    const tty = Boolean(process.stdin.isTTY && process.stdout.isTTY);
    const rl = readline.createInterface({ input: process.stdin, output: tty ? process.stdout : undefined,
                                          terminal: tty, historySize: 1000 });
    /** @type {string[]} lines typed, not yet read */
    const lines = [];
    let closed = false;
    /** @type {(() => void) | null} what a waiting `read` is woken by */
    let wake = null;
    const notify = () => { const w = wake; wake = null; w?.(); };
    rl.on("line", (l) => { lines.push(l); notify(); });
    rl.on("close", () => { closed = true; notify(); });
    rl.on("SIGINT", () => rl.close());
    return {
        async read(prompt) {
            if (tty) {
                rl.setPrompt(prompt);
                rl.prompt();
            } else io.stdout(prompt);
            while (!lines.length && !closed) await /** @type {Promise<void>} */ (new Promise((r) => { wake = r; }));
            return lines.shift() ?? null;
        },
        write: (line) => io.stdout(line + "\n"),
        close: () => rl.close(),
    };
}

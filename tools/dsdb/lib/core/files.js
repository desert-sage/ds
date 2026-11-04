// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Why a file could not be read or written, as a sentence, not Node's
// `ENOENT: … open 'x'`.

/** @type {Map<unknown, string>} */
const WHY = new Map([
    ["ENOENT", "no such file or directory"],
    ["EACCES", "permission denied"],
    ["EPERM", "permission denied"],
    ["EISDIR", "it is a directory"],
    ["ENOTDIR", "a part of the path is not a directory"],
    ["ENOSPC", "no space left on the device"],
]);

/**
 * @param {unknown} err  what a file operation threw
 * @returns {string}
 */
export function fileProblem(err) {
    const code = err instanceof Error && "code" in err ? err.code : null;
    return WHY.get(code) ?? (err instanceof Error ? err.message : String(err));
}

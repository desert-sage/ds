// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `dsdb/api` (dsdb/DSDB_WEB.md §3): what a page imports to drive dsdb
// directly, with the result objects themselves; `dsdb/api/worker` runs it in
// a worker. Nothing from Node.

export { Api, OpError, OPS } from "./ops.js";
export { openSession, sniff, emptyProgram, EMPTY_PROGRAM } from "./open.js";
export { bytesLoad, fromBase64 } from "./bytes.js";
export { Rpc } from "./rpc.js";
export { project, replacer, resultSchema, outputSchema } from "./json.js";
export { startWorker } from "./worker.js";

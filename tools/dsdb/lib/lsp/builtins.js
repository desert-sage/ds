// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The builtin functions as `ds lsp` shows them: which one a name
// written in a program calls, and its hover. Everything shown is
// [LEXP.17.2]'s, through the generated registries.js: the signature, the
// summary and the clauses that define it. The hover adds no text of its own.
//
// A defining clause is a link when the client names where the rendered
// documentation is (`initializationOptions.docs`: the site a release's docs
// tarball unpacks to, or its URL), and its id alone when it does not: the
// release publishes the documentation as that tarball, at no address of its
// own.

import { pathToFileURL } from "node:url";

import { wordAt } from "./analysis.js";
import { imported } from "./complete.js";
import { BUILTINS } from "./registries.js";

/** @import { Module } from "../ast/nodes.js" */
/** @import { Builtin } from "./registries.js" */

/** What a call may name, by name: every row of [LEXP.17.2]. */
const CALLABLE = new Map(BUILTINS.map((b) => [b.name, b]));

/**
 * The builtin a callee names, as written: `abs`; `math.sqrt` through `import
 * math` (or `m.sqrt` through `import math as m`); `sqrt` through `from math
 * import sqrt`. A module's members are reached only through an import
 * ([LIMP.3.3.4]).
 * @param {Module | null} mod
 * @param {string} callee
 * @returns {Builtin | null}
 */
export function builtinNamed(mod, callee) {
    const { modules, bare } = imported(mod);
    const dot = callee.indexOf(".");
    if (dot < 0) return CALLABLE.get(bare.get(callee) ?? callee) ?? null;
    const m = modules.get(callee.slice(0, dot));
    return m === undefined ? null : CALLABLE.get(`${m}${callee.slice(dot)}`) ?? null;
}

/**
 * The builtin called at a position: the name under it, with any qualifier,
 * followed by `(`. A name not called is not a builtin's here: `count` is also
 * a clause word ([LLEX.9.6]).
 * @param {Module | null} mod
 * @param {string} text  the line
 * @param {number} col  a code-point column
 * @returns {Builtin | null}
 */
export function builtinAt(mod, text, col) {
    const w = wordAt(text, col);
    if (w === null) return null;
    if (!/^\s*\(/u.test([...text].slice(w.end).join(""))) return null;
    return builtinNamed(mod, w.qualifier === null ? w.word : `${w.qualifier}.${w.word}`);
}

/**
 * Where the client says the rendered documentation is, as a base URL: a URL
 * as given, a path as a `file:` URL; null for none.
 * @param {unknown} given
 * @returns {string | null}
 */
export function docsBase(given) {
    if (typeof given !== "string" || given === "") return null;
    const base = /^[a-z][a-z0-9+.-]*:/i.test(given) ? given : pathToFileURL(given).href;
    return base.endsWith("/") ? base : base + "/";
}

/**
 * A builtin's hover: each overload's signature under its name, its summary,
 * and the clauses that define it.
 * @param {Builtin} b
 * @param {string | null} docs  the documentation's base URL
 * @returns {string}
 */
export function builtinHover(b, docs) {
    const clauses = b.defined.map((c) => (docs === null ? `[${c.id}]` : `[[${c.id}]](${docs}specs/${c.page})`));
    return ["```ds\n" + b.signatures.map((s) => b.name + s).join("\n") + "\n```", b.summary, clauses.join(", ")].join("\n\n");
}

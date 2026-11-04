// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// `ds lsp`'s signature help for the builtins (lib/lsp/signature.js): the
// call found in the text before the cursor, the overloads and
// their parameters from [LEXP.17.2]'s Signature column. A tree is needed only
// for the imports, so the tests give one by hand.

import { test } from "node:test";
import assert from "node:assert/strict";

import { signatureHelp } from "../lib/lsp/signature.js";

/** A tree holding only these imports. @param {object[]} body */
const mod = (...body) => /** @type {any} */ ({ _type: "Module", body });

/**
 * Help at the end of the text's last line.
 * @param {string} text
 * @param {any} [tree]
 */
const at = (text, tree = null) => {
    const ls = text.split("\n");
    return signatureHelp(tree, ls, ls.length, [...ls[ls.length - 1]].length);
};

/** Each signature's parameters, as the text their offsets select. @param {any} h */
const params = (h) => h.signatures.map((/** @type {any} */ s) => s.parameters.map((/** @type {any} */ p) => s.label.slice(...p.label)));

test("a bare builtin: each overload, the parameter the cursor is on, its summary", () => {
    const h = at("    Reading r where abs(");
    assert.deepEqual(h?.signatures.map((s) => s.label), ["abs(x: Int) → Int", "abs(x: Float) → Float"]);
    assert.deepEqual(params(h), [["x: Int"], ["x: Float"]]);
    assert.equal(h?.activeParameter, 0);
    assert.equal(h?.signatures[0].documentation, "Absolute value, of the argument's type.");
});

test("the first overload the arguments fit is active", () => {
    const tree = mod({ _type: "Import", path: ["distance"], asname: null });
    const h = at("let d = distance.euclidean(a, b, c, d, e", tree);
    assert.deepEqual(params(h), [["x1", "y1", "x2", "y2: Float"], ["x1", "y1", "z1", "x2", "y2", "z2: Float"]]);
    assert.equal(h?.activeSignature, 1, "five arguments fit only the 3D form");
    assert.equal(h?.activeParameter, 4);
    assert.equal(at("let d = distance.euclidean(a, ", tree)?.activeSignature, 0);
});

test("a module's member only through its import ([LIMP.3.3.4]), under the name it is imported as", () => {
    assert.equal(at("let x = math.sqrt("), null);
    assert.deepEqual(at("let x = m.sqrt(", mod({ _type: "Import", path: ["math"], asname: "m" }))?.signatures.map((s) => s.label),
                     ["m.sqrt(x: Float) → Float"]);
    const from = mod({ _type: "ImportFrom", path: ["math"], names: [{ name: "sqrt", asname: null }] });
    assert.deepEqual(at("let x = sqrt(", from)?.signatures.map((s) => s.label), ["sqrt(x: Float) → Float"]);
});

test("a call continued over lines; a bracket in a string or a comment is none", () => {
    assert.equal(at("let x = max(\n    a,  # (\n    ")?.activeParameter, 1);
    assert.equal(at('let x = max("(,", ')?.activeParameter, 1);
    assert.equal(at("let x = max(abs(a), ")?.signatures[0].label, "max(a, b: Int | Float) → Int | Float", "the inner call is closed");
});

test("no help outside a builtin's call", () => {
    assert.equal(at("let x = abs(a) "), null, "the call is closed");
    assert.equal(at("emit Alert(", null), null, "not a builtin");
    assert.deepEqual(at("let x = [abs(")?.signatures.map((s) => s.label)[0], "abs(x: Int) → Int", "a call inside a list: the call");
    assert.equal(at("let x = abs([a, "), null, "inside a list inside a call: the list's comma is not the call's");
});

test("a builtin of no arguments has an overload with none", () => {
    const h = at("let t = now(");
    assert.deepEqual(h?.signatures.map((s) => s.label), ["now() → Time"]);
    assert.deepEqual(params(h), [[]]);
});

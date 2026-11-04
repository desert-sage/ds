// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Editing the program (DSTRACE_INTERACTIVE §4.16), part 1: the program as its
// definitions. The splitting and the edits need no engine.

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { ProgramError, ProgramText, header } from "../lib/core/program-text.js";

const labels = (p) => p.defs.map((d) => d.label);

describe("the program as its definitions", () => {
    test("headers: every top-level form, at column 0 only", () => {
        assert.deepEqual(header("rule hot:"), { kind: "rule", name: "hot" });
        assert.deepEqual(header("schema Reading scope logical:"), { kind: "schema", name: "Reading" });
        assert.deepEqual(header("service svc.foo:"), { kind: "service", name: "svc.foo" });
        assert.deepEqual(header("series Gauge.level (by: entity_id):"), { kind: "series", name: "Gauge.level" });
        assert.deepEqual(header("from facility import RoomFeed"), { kind: "import", name: "facility" });
        assert.deepEqual(header("const WARN_C = 35.0"), { kind: "const", name: "WARN_C" });
        assert.deepEqual(header('test "a thing holds":'), { kind: "test", name: '"a thing holds"' });
        assert.deepEqual(header("use default (json)"), { kind: "use", name: "use" });
        assert.equal(header("    rule hot:"), null);
        assert.equal(header("->"), null);
        assert.equal(header("ruler x"), null);
    });

    test("a rule's own column-0 lines stay in it: `->`, a bracket closed at column 0", () => {
        const p = ProgramText.parse("rule r:\n    A a where (\n        a.x > 1\n)\n->\n    log info \"x\"\n\nrule s:\n    B b\n->\n    log info \"y\"\n");
        assert.deepEqual(labels(p), ["rule r", "rule s"]);
        assert.ok(p.find("rule", "r").text.endsWith('log info "x"'));
    });

    test("a block is one definition", () => {
        const d = ProgramText.definition("# why\nrule r:\n    A a\n->\n    log info \"x\"\n\n");
        assert.deepEqual([d.kind, d.name], ["rule", "r"]);
        assert.ok(d.text.startsWith("# why\n"));
        assert.throws(() => ProgramText.definition("rule a:\n    A a\n->\n    log info \"a\"\nrule b:\n    B b\n->\n    log info \"b\""),
                      (e) => e instanceof ProgramError && /this one has 2: rule a, rule b/.test(e.message));
        assert.throws(() => ProgramText.definition("    A a"), /starts at column 0/);
        assert.throws(() => ProgramText.definition("# only a comment"), /nothing to define/);
    });

    test("del: by name; by kind where a name is two kinds'; use; an import", () => {
        const p = ProgramText.parse("use default\n\nfrom facility import RoomFeed\n\nschema X:\n    a: Int\n\n"
                                    + "rule X:\n    X x\n->\n    log info \"x\"\n\nrule y:\n    X x\n->\n    log info \"y\"\n");
        assert.equal(p.del("y").label, "rule y");
        assert.throws(() => p.del("X"), /`X` is a schema and a rule: `del schema X` or `del rule X`/);
        assert.equal(p.del("rule X").label, "rule X");
        assert.equal(p.del("use").label, "use");
        assert.equal(p.del("import facility").label, "import facility");
        assert.throws(() => p.del("nope"), /no definition called `nope`/);
        assert.deepEqual(labels(p), ["schema X"]);
    });
});

// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A `.dsc` read back as DS declarations (DSTRACE_INTERACTIVE §7.1). The port
// of tools/dstrace_shell/program.py.
//
// A query or an `emit` typed at the prompt compiles against the program's
// schemas. The `.dsc` states every one of them: `SchemaDef` and `Slot` atoms
// for the shape (each slot's key or mutable role, nullability, tolerance,
// fact-reference target and storage markers), `SchemaLogical` for logical and
// ambient, `SchemaTtl` for ttl and its duration, `DialectInfo` and
// `CapabilityInfo` for the `use` line. libds reads those atoms (@ds-lang/ds's
// readAtoms); this writes the declarations back out. It is not a DS parser:
// nothing here reads DS text.
//
// One limit comes from the artefact: a unit-typed slot is stored as its
// storage kind.

import { floatRepr } from "../text/py.js";

/** @import { Ds } from "./types.js" */

/** Engine-provided schemas, which an artefact may carry and a program never
    declares: the compiler refuses a declaration of any of them. The two fault
    schemas are in every artefact, and `TimeZoneOffset` is too
    ([LIMP.12.2]). There is no `CallResponse`: a response is a fact of the
    service's own schema. */
export const BUILTIN = new Set(["CallError", "HydrationComplete", "HydratedSample",
                                "ComputationError", "TypeError", "TimeZoneOffset"]);

/** Whether a schema name is the engine's rather than the program's: a
    built-in, or a synthetic `$name` the compiler generates ([LLEX.10.6.1]).
    An author's `__Foo__` is the program's.
    @param {string} name */
export function reservedName(name) {
    return BUILTIN.has(name) || name.startsWith("$");
}

/** Where `Program.stage` says the libraries it writes are: a name for the
    compiler port, which puts them wherever its compiler reads files from. */
const STAGE = "/.dsdb/libraries";

/** A library schema's dotted path and its `NAME`, from its own name
    ([LIMP.13.1]); null for any other schema, whose own name holds no `.`.
    @param {string} name
    @returns {[string, string] | null} */
export function libraryOf(name) {
    const dot = name.lastIndexOf(".");
    return dot < 0 || reservedName(name) ? null : [name.slice(0, dot), name.slice(dot + 1)];
}

/**
 * @typedef {object} Service
 * @property {string} response  its response schema's name; "" for `no response`
 * @property {Map<string, string>} kwargs  each kwarg's declared type, by name
 */

const KIND = new Map([["INT", "Int"], ["FLOAT", "Float"], ["STRING", "String"], ["BOOL", "Bool"],
                      ["JSON", "Json"], ["BYTES", "Bytes"], ["TIME", "Time"], ["DATE", "Date"],
                      ["DURATION", "Duration"]]);
/** @type {Array<[string, bigint]>} */
const UNITS = [["d", 86_400_000_000_000n], ["h", 3_600_000_000_000n], ["min", 60_000_000_000n],
               ["s", 1_000_000_000n], ["ms", 1_000_000n], ["us", 1_000n], ["ns", 1n]];

/**
 * @typedef {object} Slot
 * @property {string} name
 * @property {string} kind      INT, FLOAT, … or SCHEMA
 * @property {string} schemaRef
 * @property {number} role      IdentityRole: 1 key, 2 mutable
 * @property {boolean} nullable
 * @property {number} tolerance
 * @property {boolean} sampled
 * @property {boolean} retained
 */

/** A schema: its slots in order, and its lifecycle. */
export class Schema {
    /** @param {string} name */
    constructor(name) {
        this.name = name;
        /** @type {Slot[]} */
        this.slots = [];
        this.logical = false;
        this.ambient = false;
        this.ttlNs = 0n;
    }

    get reserved() {
        return reservedName(this.name);
    }

    /**
     * Whether two schemas declare the same thing (Python's dataclass ==).
     * @param {Schema} o
     */
    equals(o) {
        return this.name === o.name && this.logical === o.logical && this.ambient === o.ambient
            && this.ttlNs === o.ttlNs && this.slots.length === o.slots.length
            && this.slots.every((s, i) => /** @type {Array<keyof Slot>} */ (Object.keys(s))
                .every((k) => s[k] === o.slots[i][k]));
    }
}

export class Program {
    /** @type {Map<string, Schema>} in the order the `.dsc` declares them */
    schemas = new Map();
    /** @type {Map<string, Service>} by name */
    services = new Map();
    /** @type {Array<[string, string]>} `[file, text]` of the source the `.dsc` embeds (DSRC) */
    sources = [];

    /** @param {Uint8Array} dsc  the artefact read, for program engines */
    constructor(dsc) {
        this.dsc = dsc;
    }

    names() {
        return new Set(this.schemas.keys());
    }

    /**
     * How a program's source writes a schema as a slot's type: a library
     * schema's own name holds a `.` ([LIMP.13.1]) and a type is one symbol
     * ([LGRA.5.1]), so `declarations` imports it under this alias.
     * @param {string} name  a schema's own name
     * @returns {string}
     */
    spelling(name) {
        if (libraryOf(name) === null || !this.schemas.has(name)) return name;
        let alias = `Lib_${name.replace(/\./g, "_")}`;
        while (this.schemas.has(alias)) alias += "_";
        return alias;
    }

    /**
     * What a compile of `declarations` also needs: a library schema can only be
     * declared in its library, so each library the artefact's names give is
     * written back out as one (DSDB.md §3). None for a program with no library
     * schema, which compiles as it is.
     * @param {boolean} [scratch]  as `declarations`
     * @param {{ ttl?: boolean }} [o]  as `declarations`
     * @returns {{ searchPath?: string[], files?: Record<string, string> }}
     */
    stage(scratch = false, { ttl = true } = {}) {
        /** @type {Map<string, string[]>} */
        const libraries = new Map();
        for (const s of this.schemas.values()) {
            const lib = libraryOf(s.name);
            if (lib === null) continue;
            const body = libraries.get(lib[0]) ?? [];
            libraries.set(lib[0], body);
            const typed = (/** @type {string} */ ref) => {
                const other = libraryOf(ref);
                if (other === null || !this.schemas.has(ref)) return ref;
                return other[0] === lib[0] ? other[1] : this.spelling(ref);
            };
            body.push(...declaration(scratch ? bareOf(s) : s, { ttl, name: lib[1], type: typed }), "");
        }
        if (libraries.size === 0) return {};
        /** @type {Record<string, string>} */
        const files = {};
        for (const [path, body] of libraries) {
            const refs = [...this.schemas.values()].filter((s) => libraryOf(s.name)?.[0] === path)
                .flatMap((s) => s.slots.map((sl) => sl.schemaRef))
                .filter((ref) => ref !== "" && this.schemas.has(ref) && libraryOf(ref) !== null && libraryOf(ref)?.[0] !== path);
            const imports = [...new Set(refs)].map((ref) => this.#importOf(ref));
            files[`${STAGE}/${path.replace(/\./g, "/")}.ds`] = [...imports, "", ...body].join("\n");
        }
        return { searchPath: [STAGE], files };
    }

    /**
     * The import that gives a library schema its `spelling`.
     * @param {string} name  a library schema's own name
     */
    #importOf(name) {
        const [path, bare] = /** @type {[string, string]} */ (libraryOf(name));
        return `from ${path} import ${bare} as ${this.spelling(name)}`;
    }

    /**
     * `use default` and one declaration per program schema.
     *
     * The line is `use default` whatever the program's own dialect: what
     * dsdb compiles from these runs in dsdb's own engines,
     * never under the program's contract, and an integrator dialect is a YAML
     * file dsdb does not have.
     *
     * `scratch` declares every schema with no scope and no slot markers,
     * keeping only names, types and nullability. That is the program an
     * `emit` typed at the prompt is evaluated in (§7.2): the value is what
     * matters there, and an explicit schema accepts a plain `emit` whatever
     * the real schema's lifecycle, including an ambient one, which no rule
     * could emit into.
     *
     * `ttl: false` declares a `ttl` schema with no scope, so an engine of the
     * program expires nothing by itself. A query's is that: a fact
     * leaves it when its recorded withdrawal is applied ([RFCS.7.4]), at the
     * record the recording says, whatever TTL it had ([LDTL.4.1]).
     * @param {boolean} [scratch]
     * @param {{ ttl?: boolean }} [o]
     * @returns {string}
     */
    declarations(scratch = false, { ttl = true } = {}) {
        const out = ["use default", ""];
        // A library schema is declared in its library (`stage`), and reached
        // here as an author reaches one: `lib.NAME` through the `import`, which
        // is how a query or an `emit` writes it, and its alias as a slot's type.
        const held = [...this.schemas.keys()].filter((name) => libraryOf(name) !== null);
        const paths = [...new Set(held.map((name) => /** @type {[string, string]} */ (libraryOf(name))[0]))];
        if (held.length) out.push(...paths.map((path) => `import ${path}`), ...held.map((name) => this.#importOf(name)), "");
        for (const s of this.schemas.values()) {
            if (s.reserved || libraryOf(s.name) !== null) continue;
            out.push(...declaration(scratch ? bareOf(s) : s, { ttl, type: (ref) => this.spelling(ref) }), "");
        }
        return out.join("\n");
    }

    /**
     * null when both declare the same schemas with the same slots, roles and
     * lifecycles; otherwise the first difference, for a message (§2).
     * @param {Program} other
     * @returns {string | null}
     */
    sameShape(other) {
        /** @param {Program} p */
        const own = (p) => new Map([...p.schemas].filter(([, s]) => !s.reserved));
        const mine = own(this), theirs = own(other);
        for (const name of [...new Set([...mine.keys(), ...theirs.keys()])].sort()) {
            const a = mine.get(name), b = theirs.get(name);
            if (b === undefined) return `schema ${name} is only in the .dsc`;
            if (a === undefined) return `schema ${name} is only in the source`;
            if (!a.equals(b)) return `schema ${name} differs`;
        }
        return null;
    }
}

/**
 * @param {string} name
 * @param {string} kind
 * @param {string} [schemaRef]
 * @returns {Slot}
 */
function slot(name, kind, schemaRef = "") {
    return { name, kind, schemaRef, role: 0, nullable: false, tolerance: 0, sampled: false, retained: false };
}

/**
 * Every rule in an artefact, by its terminal node. A stripped `.dsc` keeps its
 * network but loses its rule metadata, so the terminals are the one list both
 * a stripped and an unstripped build still carry.
 * @param {Ds} ds  a `@ds-lang/ds` API
 * @param {Uint8Array} dsc
 * @returns {Set<string>}
 */
export function ruleNames(ds, dsc) {
    const e = new ds.Engine();
    try {
        e.loadDsc(dsc);
        return new Set(e.reteNetwork().nodes.filter((n) => n.kind === "terminal").map((n) => n.label));
    } finally {
        e.close();
    }
}

/**
 * The exact DS literal for a nanosecond count: `5_s`, `24_h`.
 * @param {bigint} ns
 */
export function duration(ns) {
    for (const [unit, size] of UNITS) if (ns % size === 0n) return `${ns / size}_${unit}`;
    return `${ns}_ns`;
}

/**
 * A schema written with no `scope`. The compiler records one with the same
 * SchemaLogical atom a logical schema gets, so the atom alone does not tell
 * them apart. The slots do: a logical schema marks every slot key or mutable,
 * mandatorily ([LFAC]), so a "logical" schema whose slots carry no role at
 * all was never written `scope logical`.
 * @param {Schema} s
 */
export function isExplicit(s) {
    return s.logical && !s.ambient && s.slots.length > 0 && s.slots.every((sl) => sl.role === 0);
}

/**
 * A schema with no scope and no slot markers: `Program.declarations`'s `scratch`.
 * @param {Schema} s
 * @returns {Schema}
 */
function bareOf(s) {
    const bare = new Schema(s.name);
    bare.slots = s.slots.map((sl) => ({ ...slot(sl.name, sl.kind, sl.schemaRef), nullable: sl.nullable }));
    return bare;
}

/**
 * A schema's declaration, as lines; with `ttl: false`, a `ttl` schema's
 * without its scope (`Program.declarations`). `name` is the `NAME` to declare,
 * and `type` how to write a slot's referenced schema, where they differ from
 * its own names (`Program.stage`).
 * @param {Schema} s
 * @param {{ ttl?: boolean, name?: string, type?: (ref: string) => string }} [o]
 * @returns {string[]}
 */
export function declaration(s, { ttl = true, name = s.name, type = (ref) => ref } = {}) {
    const explicit = isExplicit(s);
    let scope = "";
    if (explicit) scope = "";
    else if (s.logical) scope = s.ambient ? "logical ambient" : "logical";
    else if (s.ttlNs && ttl) scope = `ttl ${duration(s.ttlNs)}`;
    const lines = [`schema ${name}` + (scope ? ` scope ${scope}` : "") + ":"];
    for (const sl of s.slots) {
        const typ = sl.kind === "SCHEMA" ? type(sl.schemaRef) : (KIND.get(sl.kind) ?? sl.kind);
        const parts = [`    ${sl.name}: ${typ}${sl.nullable ? "?" : ""}`];
        if (s.logical && !explicit && sl.role !== 3) {
            // [LFAC] every logical slot is marked; an unmarked one would be
            // refused, so an artefact that lost the role says mutable. `ts`
            // (role 3, ENGINE) is the exception: it carries no marker, and the
            // compiler refuses one on it ([LFAC.9.1]).
            parts.push(sl.role === 1 ? "key" : "mutable");
            if (sl.tolerance && sl.role !== 1) parts.push(`tolerance ${floatRepr(sl.tolerance)}`);
        }
        if (sl.sampled) parts.push("sampled");
        if (sl.retained) parts.push("retained");
        lines.push(parts.join(" "));
    }
    return lines;
}

const utf8 = new TextDecoder("utf-8");      // replaces, as Python's "replace"
/**
 * @param {{ name: string | null } | null | undefined} e  an enum field
 * @param {RegExp} prefix
 */
const enumName = (e, prefix) => (e?.name ?? "").replace(prefix, "");
/** @param {{ number: number } | null | undefined} e  an enum field */
const enumNumber = (e) => (e === undefined || e === null ? 0 : Number(e.number));

/**
 * Every schema a `.dsc` declares, with its lifecycle, and its `use` line.
 * A self-contained trace's front ends at its StreamHeader.
 * @param {Ds} ds  a `@ds-lang/ds` API
 * @param {Uint8Array} dsc
 * @returns {Program}
 */
export function read(ds, dsc) {
    const prog = new Program(dsc);
    /** @param {string} name */
    const schema = (name) => {
        const s = prog.schemas.get(name) ?? new Schema(name);
        prog.schemas.set(name, s);
        return s;
    };
    for (const a of ds.readAtoms(dsc, { incremental: true }).atoms) {
        // An atom's fields are its message's in proto/, as libds decodes them.
        /** @type {Record<string, any>} */
        const m = a.body ?? {};
        if (a.message === "StreamHeader") break;
        switch (a.message) {
        case "SchemaDef":
            schema(m.schema_name ?? "");
            break;
        case "Slot":
            schema(m.schema_name ?? "").slots.push({
                name: m.slot_name ?? "", kind: enumName(m.kind, /^SLOT_KIND_/),
                schemaRef: m.schema_ref ?? "", role: enumNumber(m.identity_role),
                nullable: Boolean(m.nullable), tolerance: m.tolerance ?? 0,
                sampled: Boolean(m.sampled), retained: Boolean(m.retained),
            });
            break;
        case "SchemaLogical": {
            const s = schema(m.schema_name ?? "");
            s.logical = true;
            s.ambient = Boolean(m.ambient);
            break;
        }
        case "SchemaTtl":
            schema(m.schema_name ?? "").ttlNs = m.ttl_ns ?? 0n;
            break;
        case "ServiceDef":
            prog.services.set(m.name ?? "", {
                response: m.response ?? "",
                kwargs: new Map((m.kwargs ?? []).map((/** @type {Record<string, any>} */ k) =>
                    [k.name ?? "", k.ds_type ?? ""])),
            });
            break;
        case "DsSource":
            prog.sources.push([m.file ?? "", utf8.decode(m.data ?? new Uint8Array())]);
            break;
        }
    }
    return prog;
}

#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# spec_registry.py — the registry-sync gate (STYL.5.9). Reconcile what the spec
# clauses census against what the code/proto actually allocates, so no reserved
# identifier drifts silently between the two sides (STYL.2.8.7: one defining clause
# per identifier, matching its allocation, append-only).
#
# ROLLOUT (STYL.5.9.5): additive and advisory-first; each row promotes to enforcing once
# its census is ruled clean. FOUR rows land here, ENFORCING: atom magics, error codes
# (C libds.h <-> NERR census), builtin op enum (proto <-> C mirror), and proto field
# numbers (append-only: no live field reuses a reserved number/name). The fifth was DSC
# format_minor, retired with the ladder itself ([LDET.1.10]).
#
# ATOMS (STYL.5.9.2 row 1). An atom is named by its body message ([RDSC.1.2]).
#   * SPEC side — the census: the union of the DSC atom registry table in [RDSC.7.1]
#     and the fact-stream table in [RFCS.3.1], read from their `data`. A row's `Atom`
#     cell is the message; a struck-through (~~…~~) cell is a RESERVED-RETIRED atom,
#     whose `Field #` cell names the numbers atom.proto reserves for it. The census
#     clauses also carry `defines.atoms` (seeded by --write).
#   * CODE side — `Atom.oneof body` in proto/atom.proto, one line per atom,
#     `<Message> <message_snake_case> = <n>;`. The atom is the field's TYPE.
#
# The enforcing reconciliation is the SQL gate `styl_5_9_2_atom_registry`; this
# script stays for --write and prints an advisory reading. Pure stdlib.
#
# Usage: spec_registry.py            (reconcile + report, advisory)
#        spec_registry.py --write    (seed defines.atoms on the census clauses)

import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spec_tree  # noqa: E402  (the clause tree; specs/conformance/ holds no clause)

SPECS = os.path.join(ROOT, "specs")
ATOM_PROTO = os.path.join(ROOT, "proto", "atom.proto")

# The atom census is the union of these two clause tables. An atom named by an
# earlier census clause is not re-defined by a later one that merely re-lists it
# (RFCS.3.1 re-lists SchemaDef / Slot as "from DSC format").
ATOM_CENSUS_CLAUSES = ["RDSC.7.1", "RFCS.3.1"]
MESSAGE_RE = re.compile(r"^[A-Z][A-Za-z0-9]*$")


# --- error-code registry (STYL.5.9.2 row 2): C `#define DS_ERR_*` <-> the NERR census
# tables, keyed by NAME, the identifier `defines.errors` carries. The source is
# proto/status.proto; the value tie (libds.h <-> the proto) is the
# styl_5_9_2_status_registry gate's, and each binding's rendering is generated from the
# proto and checked in its own lane (STYL.2.15.6.1), so neither is this check's. ---
LIBDS_H = os.path.join(ROOT, "runtime", "include", "libds.h")
ERR_RE = re.compile(r"^#define\s+(DS_ERR_[A-Z0-9_]+)\s+(-?\d+)")
# a census-row code: backtick-wrapped, complete (does not end in `_`, so a
# `DS_ERR_BACKEND_*` family wildcard or a line-wrap fragment does not match).
CODE_IN_CELL = re.compile(r"`(DS_ERR_[A-Z0-9_]*[A-Z0-9])`")
# error codes kept as reserved #defines in libds.h but retired from v1 (never produced),
# so — like a retired atom — they are excluded from the live code<->census comparison.
#
# DS_ERR_PIR_FAMILY left this dict with the flag day: its #define is
# gone, so there is nothing live to exclude. It is worth recording why it was here
# alone. All six of -508..-513 were the same abandoned portable-IR spelling, and
# this register carried the head of the family and not the family — so the gate
# that reads it hid one member and reported the other five. A retirement register
# in two places drifts; proto/status.proto's `reserved` block is the one now.
RETIRED_ERRORS = {
    "DS_ERR_FX_RATE_UNAVAILABLE": "-215; [LUNI.4.6.1] now converts at 1:1 when an "
                                  "fx_pair selector matches no live FxRate fact instead "
                                  "of faulting, so the code lost its only specified "
                                  "producer. It was returned nowhere in-tree, so nothing "
                                  "regresses; reserved and never reused (CURRMETH2)",
}

# --- builtin-op enum registry (STYL.5.9.2 row 3): proto `enum BuiltinFn` <-> the C
# mirror `enum ds_builtin_fn`. The proto keeps the 14 transcendental tombstones (kept as
# declared members, no runtime handler) that the C header drops, so proto ⊋ C by exactly
# those; every shared name must agree by value. ---
BUILTIN_PROTO = os.path.join(ROOT, "proto", "builtin_fn.proto")
BUILTIN_H = os.path.join(ROOT, "runtime", "src", "libds", "builtin_fn.h")

# --- `defines` seeding homes (STYL.5.3.5.1) for registries with no per-identifier clause.
# The builtin catalogue clause owns all FN_* symbols (no finer per-op tie exists in proto
# or spec); RDSC.7.1 anchors the current DSC format version. ---
SYMBOL_CATALOGUE_CLAUSE = "LEXP.3.1"

# --- proto field-number append-only registry (STYL.5.9.2 row 5): within each proto
# message/enum, no live field/member may reuse a `reserved` number or name (protobuf's
# deletion discipline — a retired allocation is reserved forever), and a `reserved` that
# cites a clause must cite a real one. ---
PROTO_GLOB = os.path.join(ROOT, "proto", "*.proto")

# Enforcing toggles for the follow-on rows. Builtin proto<->C is clean (proto keeps the
# 14 transcendental tombstones the C drops; all shared values agree), so it enforces:
# a C-only builtin or a value mismatch is a real bug. Error codes reconcile 1:1 with the
# NERR census (1 retired-reserved). Proto append-only is protoc-guaranteed clean.
ERROR_ENFORCING = True
BUILTIN_ENFORCING = True
PROTO_ENFORCING = True

# Enforcing toggles (STYL.5.9.5): a registry row is advisory until its census is ruled
# clean, then promoted to enforcing (a discrepancy fails the gate). The atom + format
# rows were promoted once the census discrepancies were settled (STYL.5.9.6);
# error-codes / builtin-enum are still advisory follow-on rows.
ATOM_ENFORCING = True


def clause_files():
    """id -> clause JSON path across the structured tree (filename stem is the id)."""
    return {p.stem: str(p) for p in spec_tree.clause_files(SPECS)}


def _table_rows(text):
    """Yield each Markdown table row of a clause `text` as its list of cell strings,
    skipping the header and the |---| separator."""
    for line in text.splitlines():
        s = line.strip()
        if not s.startswith("|"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if not cells or not cells[0]:
            continue
        if set(cells[0]) <= set("-: ") or cells[0].lower() == "magic":
            continue
        yield cells


def census_atoms(clauses):
    """(live, deferred, retired) — each a {atom -> defining census id} — from the
    census clauses' `data`. A row is RETIRED if its `Atom` cell is struck through;
    DEFERRED (reserved for a future edition, not yet wired) if any cell carries the
    `(v2)` marker; else LIVE. The first census clause to name an atom owns it."""
    live, deferred, retired = {}, {}, {}
    for cid in ATOM_CENSUS_CLAUSES:
        path = clauses.get(cid)
        if not path:
            continue
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh).get("data") or {}
        cols = data.get("columns", [])
        if "Atom" not in cols:
            sys.exit(f"{cid}: no `Atom` column in {cols}")
        i_atom = cols.index("Atom")
        for cells in data.get("rows", []):
            first = cells[i_atom]
            struck = "~~" in first
            is_deferred = any("(v2)" in c for c in cells)
            name = first.replace("~~", "").replace("`", "").replace("(v2)", "").strip()
            if name in live or name in deferred or name in retired:
                continue
            if not struck and not MESSAGE_RE.match(name):
                sys.exit(f"{cid}: live row names {name!r}, which is not a message name")
            (retired if struck else deferred if is_deferred else live)[name] = cid
    return live, deferred, retired


def code_atoms():
    """{atom -> field number} from the `oneof body` of proto/atom.proto: each field's
    TYPE is its atom. Returns (mapping, [unparsed lines]) — an unparsed allocation is a
    parser gap, itself reportable."""
    out, unmatched = {}, []
    inside, depth = False, 0
    with open(ATOM_PROTO, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            if not inside:
                if "oneof body" in line:
                    inside = True
                    depth = line.count("{") - line.count("}")
                continue
            m = re.match(r"\s*([A-Z]\w*)\s+[a-z][a-z0-9_]*\s*=\s*(\d+)\s*;", line)
            if m:
                out[m.group(1)] = int(m.group(2))
            elif re.search(r"=\s*\d+\s*;", line):
                unmatched.append((lineno, line.strip()))
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                inside = False
    return out, unmatched


def defines_atoms(clauses):
    """{magic -> defining clause id} from the `defines.atoms` markers across the tree —
    the machine-readable spec side (seeded by --write). {} until backfilled."""
    out = {}
    for cid, path in clauses.items():
        with open(path, encoding="utf-8") as fh:
            defs = json.load(fh).get("defines", {}).get("atoms", [])
        for magic in defs:
            out.setdefault(magic, cid)
    return out


def mentioned_atoms(clauses):
    """Every magic named in some clause's `atoms` field — 'known to the spec somewhere',
    used to classify a code allocation that is absent from the two census tables."""
    out = set()
    for path in clauses.values():
        with open(path, encoding="utf-8") as fh:
            out.update(json.load(fh).get("atoms", []))
    return out
def code_errors():
    """{DS_ERR_* name -> value} from every `#define DS_ERR_* N` in libds.h. DS_OK is a
    success sentinel, not a census'd error, so it is excluded."""
    out = {}
    with open(LIBDS_H, encoding="utf-8") as fh:
        for line in fh:
            m = ERR_RE.match(line)
            if m:
                out[m.group(1)] = int(m.group(2))
    return out


def spec_errors(clauses):
    """{DS_ERR_* name -> defining NERR clause id}. The census is the NERR range-TABLE
    rows: each row names its code as a backtick-wrapped, complete `DS_ERR_*` identifier
    (not a `DS_ERR_FAMILY_*` wildcard, and not a prose line-wrap fragment), so only such
    tokens in table rows count — the first one in each row is the row's code."""
    out = {}
    for cid, path in sorted(clauses.items()):
        if not cid.startswith("NERR."):
            continue
        with open(path, encoding="utf-8") as fh:
            text = json.load(fh)["text"]
        for cells in _table_rows(text):
            for m in CODE_IN_CELL.finditer(" | ".join(cells)):
                out.setdefault(m.group(1), cid)   # a cell may list several codes
    return out


def _enum_members(path, prefix):
    """{name -> value} for `<PREFIX><NAME> = <n>` lines (proto FN_ / C DS_FN_), prefix
    stripped so the two enums share a name space. A stripped name starting with `_`
    (e.g. DS_FN__MAX) is a C enum-bound sentinel, not a builtin — skipped."""
    out = {}
    pat = re.compile(r"\b" + prefix + r"([A-Z0-9_]+)\s*=\s*(\d+)")
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = pat.search(line)
            if m and not m.group(1).startswith("_"):
                out[m.group(1)] = int(m.group(2))
    return out


_PROTO_ID_RE = re.compile(r"\[([A-Z]{3,5}\.[0-9][0-9.]*)\]")
_PROTO_OPEN = re.compile(r"\b(message|enum|oneof)\s+(\w+)\b")
_PROTO_FIELD = re.compile(r"(?:^|[\s{])([A-Za-z_]\w*)\s*=\s*(\d+)\s*;")
_PROTO_RESV = re.compile(r"\breserved\s+([^;]+);")


def proto_field_check(clause_ids):
    """Per message/enum in every proto/*.proto, the append-only violations: a live field
    or enum member that reuses a `reserved` number or name (protobuf's deletion
    discipline — a retired allocation is reserved forever), plus any `reserved` comment
    citing a clause id that is not real. `oneof` is transparent: its fields share the
    enclosing message's number space. Returns (reuse_violations, broken_clause_refs)."""
    known_prefixes = {cid.split(".")[0] for cid in clause_ids}
    reuse, broken = [], []
    for path in sorted(glob.glob(PROTO_GLOB)):
        rel = os.path.relpath(path, ROOT)
        frames, kinds = [], []
        with open(path, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                mo = _PROTO_OPEN.search(line)
                opened = mo.group(1) if (mo and "{" in line) else None
                if opened:                       # push before content, so a single-line
                    kinds.append(opened)         # `message X { f = 1; }` lands in X
                    if opened in ("message", "enum"):
                        frames.append({"name": mo.group(2), "nums": set(), "names": set(),
                                       "rnums": set(), "rnames": set()})
                elif "{" in line:
                    kinds.append("other")
                if frames:
                    fr = frames[-1]
                    mr = _PROTO_RESV.search(line)
                    if mr:
                        for tok in (t.strip() for t in mr.group(1).split(",")):
                            if tok.isdigit():
                                fr["rnums"].add(int(tok))
                            elif tok.startswith('"'):
                                fr["rnames"].add(tok.strip('"'))
                            elif " to " in tok:
                                a, b = (t.strip() for t in tok.split(" to ", 1))
                                if a.isdigit() and b.isdigit():
                                    fr["rnums"].update(range(int(a), int(b) + 1))
                        for cid in _PROTO_ID_RE.findall(line):
                            if cid not in clause_ids and cid.split(".")[0] in known_prefixes:
                                broken.append(f"{rel}:{lineno}: reserved cites [{cid}] — not a clause")
                    else:
                        mnn = _PROTO_FIELD.search(line)
                        if mnn and mnn.group(1) not in ("message", "enum", "oneof"):
                            fr["nums"].add(int(mnn.group(2)))
                            fr["names"].add(mnn.group(1))
                for _ in range(line.count("}")):
                    if not kinds:
                        continue
                    if kinds.pop() in ("message", "enum") and frames:
                        fr = frames.pop()
                        for n in sorted(fr["nums"] & fr["rnums"]):
                            reuse.append(f"{rel}: {fr['name']} field #{n} reuses a reserved number")
                        for nm in sorted(fr["names"] & fr["rnames"]):
                            reuse.append(f"{rel}: {fr['name']} field '{nm}' reuses a reserved name")
    return reuse, broken


def seed_defines_key(clauses, key, ident_to_clause):
    """--write: seed `defines.<key>` on each owning clause from an {identifier -> clause
    id} map (grouping identifiers by their defining clause). Idempotent. Returns
    (files_changed, owning_clause_count)."""
    by_clause = {}
    for ident, cid in ident_to_clause.items():
        by_clause.setdefault(cid, set()).add(ident)
    touched = 0
    for cid, idents in by_clause.items():
        path = clauses.get(cid)
        if not path:
            continue
        with open(path, encoding="utf-8") as fh:
            obj = json.load(fh)
        defines = obj.get("defines", {})
        want = sorted(idents)
        if defines.get(key) != want:
            defines[key] = want
            obj["defines"] = defines
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(obj, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
            touched += 1
    return touched, len(by_clause)


def main():
    write = "--write" in sys.argv
    clauses = clause_files()
    live, deferred, retired = census_atoms(clauses)

    if write:
        # STYL.5.3.5.1 `defines` — the machine-readable spec side of each registry.
        # atoms: per census clause (RDSC.7.1 / RFCS.3.1). errors: per NERR census clause.
        # symbols: the builtin FN_* enum, on the catalogue clause LEXP.3.1 ("all callable
        # directly in expressions") — no finer per-op clause tie exists. format: the
        # current DSC format version, on RDSC.7.1 which anchors it. All idempotent.
        c_fn = _enum_members(BUILTIN_H, "DS_FN_")
        symbols = {f"FN_{n}": SYMBOL_CATALOGUE_CLAUSE for n in c_fn if n != "UNSPECIFIED"}
        results = {
            "atoms": seed_defines_key(clauses, "atoms", live),
            "errors": seed_defines_key(clauses, "errors", spec_errors(clauses)),
            "symbols": seed_defines_key(clauses, "symbols", symbols),
        }
        changed = sum(t for t, _ in results.values())
        summary = ", ".join(f"{k} ({n} clause{'s' if n != 1 else ''})"
                            for k, (_, n) in results.items())
        print(f"spec-registry --write: seeded defines — {summary}; "
              f"{changed} file(s) changed")
        return

    code, unmatched = code_atoms()
    defines = defines_atoms(clauses)
    mentioned = mentioned_atoms(clauses)
    live_set, deferred_set, retired_set = set(live), set(deferred), set(retired)
    code_set, defines_set = set(code), set(defines)

    # --- code <-> census reconciliation. Enforcing invariant: code == live; a
    # deferred-future or retired-reserved atom must NOT be allocated (STYL.2.8.7);
    # the gate checks the retired NUMBERS, which this advisory reading does not. ---
    reused_retired = sorted(code_set & retired_set)           # allocated a RETIRED atom
    deferred_allocated = sorted(code_set & deferred_set)      # allocated a v2-DEFERRED atom
    code_no_census = sorted(code_set - live_set - deferred_set - retired_set)
    census_no_code = sorted(live_set - code_set)              # live census row, unallocated
    # spec-side backfill completeness: defines should mirror the live census.
    defines_not_census = sorted(defines_set - live_set)
    census_not_defined = sorted(live_set - defines_set)

    label = "ENFORCING" if ATOM_ENFORCING else "ADVISORY"
    print(f"=== registry-sync (STYL.5.9) — atoms [{label}] ===")
    print(f"  code (proto/atom.proto oneof body): {len(code_set)} atoms")
    print(f"  census (RDSC.7.1 ∪ RFCS.3.1): {len(live_set)} live, {len(deferred_set)} "
          f"deferred (v2), {len(retired_set)} retired")
    print(f"  spec defines.atoms markers: {len(defines_set)}")

    if reused_retired:
        print("\n  ‼ ALLOCATION REUSES A RETIRED ATOM (reserved-allocation violation, "
              "STYL.2.8.7):")
        for m in reused_retired:
            print(f"      {m}  — code allocates #{code[m]}, but census retired it ({retired[m]})")
    if deferred_allocated:
        print("\n  ‼ ALLOCATION OF A v2-DEFERRED ATOM (not yet in this edition):")
        for m in deferred_allocated:
            print(f"      {m}  — code allocates #{code[m]}, but census defers it ({deferred[m]})")
    if code_no_census:
        print("\n  code allocates an atom with NO census row:")
        for m in code_no_census:
            where = "mentioned elsewhere in spec" if m in mentioned else "UNKNOWN to the spec"
            print(f"      {m}  (proto #{code[m]}; {where}) — add an RDSC.7.1/RFCS.3.1 row?")
    if census_no_code:
        print("\n  live census atom with NO proto allocation:")
        for m in census_no_code:
            print(f"      {m}  (census {live[m]})")
    if deferred_set:
        print(f"\n  {len(deferred_set)} v2-deferred atom(s) reserved, correctly unallocated: "
              f"{', '.join(sorted(deferred_set))}")
    if defines_not_census:
        print("\n  defines.atoms marker not backed by a live census row:")
        for m in defines_not_census:
            print(f"      {m}  (defined by {defines[m]})")
    if census_not_defined:
        print(f"\n  {len(census_not_defined)} live census atom(s) carry no defines.atoms "
              "marker yet (run spec_registry.py --write to seed)")
    if unmatched:
        print("\n  proto/atom.proto allocation line(s) the parser could not read an atom from:")
        for lineno, line in unmatched:
            print(f"      atom.proto:{lineno}: {line}")

    atom_fail = bool(reused_retired or deferred_allocated or code_no_census or census_no_code
                     or (defines_set and (defines_not_census or census_not_defined)))

    # --- error-code registry (STYL.5.9.2 row 2): C #define DS_ERR_* <-> NERR census,
    # keyed by name; values are styl_5_9_2_status_registry's. ---
    code_err, spec_err = code_errors(), spec_errors(clauses)
    code_err_set = set(code_err) - set(RETIRED_ERRORS)    # live C codes only
    spec_err_set = set(spec_err)
    err_code_only = sorted(code_err_set - spec_err_set)   # live C code, no census row
    err_spec_only = sorted(spec_err_set - code_err_set)   # census row, no live C #define
    err_fail = bool(err_code_only or err_spec_only)
    elabel = "ENFORCING" if ERROR_ENFORCING else "ADVISORY"
    print(f"\n=== registry-sync (STYL.5.9) — error codes [{elabel}] ===")
    print(f"  code (libds.h #define DS_ERR_*): {len(code_err_set)} live, "
          f"{len(RETIRED_ERRORS)} retired-reserved   spec (NERR census rows): {len(spec_err_set)}")
    if err_code_only:
        print("\n  DS_ERR_* defined in libds.h with NO NERR census row:")
        for n in err_code_only:
            print(f"      {n}  (= {code_err[n]})")
    if err_spec_only:
        print("\n  DS_ERR_* in an NERR census row with NO libds.h #define:")
        for n in err_spec_only:
            print(f"      {n}  ({spec_err[n]})")

    # --- builtin-op enum (STYL.5.9.2 row 3): proto enum BuiltinFn <-> C mirror
    # ds_builtin_fn. proto keeps the transcendental tombstones the C header drops. ---
    proto_fn = _enum_members(BUILTIN_PROTO, "FN_")
    c_fn = _enum_members(BUILTIN_H, "DS_FN_")
    proto_set, c_set = set(proto_fn), set(c_fn)
    fn_proto_only = sorted(proto_set - c_set)     # expected: transcendental tombstones
    fn_c_only = sorted(c_set - proto_set)         # a C builtin absent from proto — a bug
    fn_mismatch = sorted(n for n in proto_set & c_set if proto_fn[n] != c_fn[n])
    builtin_fail = bool(fn_c_only or fn_mismatch)
    blabel = "ENFORCING" if BUILTIN_ENFORCING else "ADVISORY"
    print(f"\n=== registry-sync (STYL.5.9) — builtin op enum [{blabel}] ===")
    print(f"  proto (builtin_fn.proto FN_*): {len(proto_set)}   "
          f"C mirror (builtin_fn.h DS_FN_*): {len(c_set)}   "
          f"proto-only tombstones: {len(fn_proto_only)}")
    if fn_c_only:
        print("\n  ‼ builtin in the C mirror but NOT in the proto enum:")
        for n in fn_c_only:
            print(f"      DS_FN_{n} (= {c_fn[n]})")
    if fn_mismatch:
        print("\n  ‼ builtin value disagrees proto vs C:")
        for n in fn_mismatch:
            print(f"      {n}: proto FN_{n}={proto_fn[n]} vs C DS_FN_{n}={c_fn[n]}")

    # --- proto field-number append-only (STYL.5.9.2 row 5): no live field/member reuses
    # a reserved number/name; a reserved's cited clause must be real. ---
    proto_reuse, proto_broken = proto_field_check(set(clauses))
    proto_fail = bool(proto_reuse or proto_broken)
    plabel = "ENFORCING" if PROTO_ENFORCING else "ADVISORY"
    nres = sum(1 for _ in glob.glob(PROTO_GLOB))
    print(f"\n=== registry-sync (STYL.5.9) — proto field numbers [{plabel}] ===")
    print(f"  {nres} proto file(s) scanned for reserved/live append-only integrity")
    if proto_reuse:
        print("\n  ‼ live field/member reuses a RESERVED number or name (append-only "
              "violation):")
        for v in proto_reuse:
            print(f"      {v}")
    if proto_broken:
        print("\n  ‼ a `reserved` comment cites a clause that does not exist:")
        for v in proto_broken:
            print(f"      {v}")
    if not proto_fail:
        print("  clean — every reserved number/name stays retired, no reuse")

    fail = ((atom_fail and ATOM_ENFORCING)
            or (err_fail and ERROR_ENFORCING) or (builtin_fail and BUILTIN_ENFORCING)
            or (proto_fail and PROTO_ENFORCING))
    print(f"\nspec-registry: atoms {'FAIL' if atom_fail else 'ok'}({label}), "
          f"error-codes {'DRIFT' if err_fail else 'ok'}({elabel}), "
          f"builtin-enum {'DRIFT' if builtin_fail else 'ok'}({blabel}), "
          f"proto-fields {'FAIL' if proto_fail else 'ok'}({plabel}) "
          f"-> {'FAIL' if fail else 'ok'}")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()

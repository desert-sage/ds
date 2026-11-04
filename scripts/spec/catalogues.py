#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""catalogues -- the reference books' catalogue tables, generated from their sources.

    python3 scripts/spec/catalogues.py      write every catalogue

A catalogue whose rows exist in a machine-readable source is generated from
that source, never copied into a page by hand. Each
one below is written as a Markdown table, alone in its own file under its
book's `_generated/`, and a page pulls it in with MyST's include directive:

    ```{include} ../_generated/builtins.md
    ```

`_generated/` is git-ignored, so nothing generated is committed and nothing can
go stale in the tree. `ds_docs.build`'s `catalogues` step runs this before the
books render.

A source this cannot read, or reads into a shape it does not know, stops it
with the source's name and what was wrong. It never writes an empty or partial
table. Before it writes anything it feeds its readers the defects they must
refuse (`NEGATIVE`) and the rows they must keep and drop (`BEHAVES`), and stops
if any goes the other way, so every run shows both still hold.

Each source is read through the module the spec gate reads it with, so a
catalogue cannot hold a row the gate did not see: the clause tree through
`spec_tree`, the NERR census and the stream event kinds through
`spec_registry`'s patterns and `spec_render.parse_md_table`, the validate registry
through `gen_ebnf_registry.parse`. No gate reads the standard library's unit
declarations, so `units` reads them by [LUNI.4]'s line forms and stops at a
`unit` line that is none of them. Standard library only.
"""
from __future__ import annotations

import json
import os
import re
import sys
from typing import Any, Callable, Iterator

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "scripts", "spec"))
import gen_ebnf_registry  # noqa: E402  (the validate registry's one parser)
import spec_render  # noqa: E402  (the census's one Markdown-table parser)
import spec_registry  # noqa: E402  (libds.h's #define pattern, the census code pattern)
import spec_tree  # noqa: E402  (the clause tree)

SPECS = os.path.join(ROOT, "specs")
VALIDATE_EBNF = os.path.join(SPECS, "registry", "validate.ebnf")
UNITS_DIR = os.path.join(ROOT, "stdlib", "units")

Rows = list[list[str]]


class CatalogueError(Exception):
    """A source that cannot be read, or does not have the shape it is read as."""


# -- reading ------------------------------------------------------------------


def read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise CatalogueError(f"{os.path.relpath(path, ROOT)}: {exc}") from exc


def read_clause(path: str) -> dict[str, Any]:
    try:
        clause = json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        raise CatalogueError(f"{os.path.relpath(path, ROOT)}: {exc}") from exc
    if not isinstance(clause, dict) or not isinstance(clause.get("id"), str):
        raise CatalogueError(f"{os.path.relpath(path, ROOT)}: not a clause")
    return clause


def clause_tree() -> dict[str, dict[str, Any]]:
    """Every clause, by id."""
    tree = {c["id"]: c for c in map(read_clause, map(str, spec_tree.clause_files(SPECS)))}
    if not tree:
        raise CatalogueError(f"{os.path.relpath(SPECS, ROOT)}: no clause files")
    return tree


def binds(clause: dict[str, Any]) -> bool:
    """A live clause of this edition: neither retired nor deferred ([STYL.5.3.3])."""
    return clause.get("kind") != "tombstone" and not clause.get("deferred")


def table(clause: dict[str, Any], columns: list[str]) -> Rows:
    """A registry table clause's rows ([STYL.5.3.2.1]), whose columns must be
    exactly `columns`."""
    cid = clause.get("id", "?")
    if not binds(clause):
        raise CatalogueError(f"[{cid}] does not bind this edition")
    data = clause.get("data")
    if not isinstance(data, dict) or "rows" not in data:
        raise CatalogueError(f"[{cid}] carries no table data")
    if data.get("columns") != columns:
        raise CatalogueError(f"[{cid}]: columns are {data.get('columns')}, expected {columns}")
    rows = data["rows"]
    if not rows:
        raise CatalogueError(f"[{cid}]: the table has no rows")
    for row in rows:
        if (not isinstance(row, list) or len(row) != len(columns)
                or not all(isinstance(cell, str) for cell in row)):
            raise CatalogueError(f"[{cid}]: a row is not {len(columns)} strings: {row!r}")
    return rows


# -- rendering ----------------------------------------------------------------

# A cell's text goes into a pipe table, where an unescaped `|` (`Int | Float`)
# ends the cell. A `\|` the source already escaped is left alone.
_BARE_PIPE = re.compile(r"(?<!\\)\|")


def cell(text: str) -> str:
    return _BARE_PIPE.sub(r"\\|", " ".join(text.split()))


def code(text: str) -> str:
    return f"`{text}`"


def cites(ids: list[str]) -> str:
    """Clause ids in the reference books' citation form, `[LEXP.3.2]` (R3.6)."""
    return ", ".join(f"[{i}]" for i in ids)


def render(columns: list[str], rows: Rows, source: str) -> str:
    out = [
        f"<!-- Generated from {source} by scripts/spec/catalogues.py. Do not edit. -->",
        "",
        "| " + " | ".join(columns) + " |",
        "|" + "|".join("---" for _ in columns) + "|",
    ]
    out += ["| " + " | ".join(cell(c) for c in row) + " |" for row in rows]
    return "\n".join(out) + "\n"


# -- the catalogues -----------------------------------------------------------

BUILTINS_COLUMNS = ["Name", "Arities", "Tier", "Signature", "Summary", "Defined by"]


def _builtin_rows(tree: dict[str, dict[str, Any]],
                  keep: Callable[[list[str]], bool]) -> Rows:
    """[LEXP.17.2]'s rows whose Defined by clauses `keep` takes."""
    rows = table(tree.get("LEXP.17.2") or {"id": "LEXP.17.2"}, BUILTINS_COLUMNS)
    out = []
    for name, arities, tier, signature, summary, defined_by in rows:
        ids = [i.strip() for i in defined_by.split(",") if i.strip()]
        unknown = [i for i in ids if i not in tree]
        if not ids or unknown:
            raise CatalogueError(f"[LEXP.17.2]: `{name}` is defined by "
                                 f"{defined_by!r}, which names no clause")
        if keep(ids):
            out.append([code(name), arities, tier, signature, summary, cites(ids)])
    return out


def _is_aggregation(ids: list[str]) -> bool:
    """Whether a [LEXP.17.2] row's Defined by clauses make it an aggregation."""
    return any(i.startswith("LSER.16.") for i in ids)


def builtins(tree: dict[str, dict[str, Any]]) -> str:
    """The builtin functions: the rows of [LEXP.17.2] that `aggregations` does
    not take, so each row has one home (R2.1)."""
    rows = _builtin_rows(tree, lambda ids: not _is_aggregation(ids))
    if not rows:
        raise CatalogueError("[LEXP.17.2]: every row is defined by an LSER.16.* clause")
    return render(BUILTINS_COLUMNS, rows, "[LEXP.17.2], less its `LSER.16.*` rows")


def aggregations(tree: dict[str, dict[str, Any]]) -> str:
    """The aggregations: the rows of [LEXP.17.2] an `LSER.16.*` clause defines."""
    rows = _builtin_rows(tree, _is_aggregation)
    if not rows:
        raise CatalogueError("[LEXP.17.2]: no row is defined by an LSER.16.* clause")
    return render(BUILTINS_COLUMNS, rows, "[LEXP.17.2]'s `LSER.16.*` rows")


KEYWORDS_COLUMNS = ["Word", "Reserved by", "Class"]


def keywords(tree: dict[str, dict[str, Any]]) -> str:
    """The reserved words: [LLEX.9.6], row for row."""
    rows = table(tree.get("LLEX.9.6") or {"id": "LLEX.9.6"}, KEYWORDS_COLUMNS)
    out = [[code(word), by, cls] for word, by, cls in rows]
    return render(KEYWORDS_COLUMNS, out, "[LLEX.9.6]")


# The refusals a shipped compiler issues for what this edition defers. Each stays
# in the diagnostics whatever else defers around it, so
# a tree in which only a deferred clause names one stops the run.
DEFERRAL_REFUSALS = ("DS_VALIDATE_REALTIME_DEFERRED", "DS_VALIDATE_CAPABILITY_DEFERRED",
                     "DS_VALIDATE_FINANCE_DEFERRED")


def validate_codes(ebnf: str = VALIDATE_EBNF) -> list[tuple[str, int]]:
    """Every live code of `validate.ebnf` with its number, but
    DS_VALIDATE_UNSPECIFIED, which names no diagnostic."""
    if not os.path.isfile(ebnf):
        raise CatalogueError(f"{os.path.relpath(ebnf, ROOT)}: no such file")
    try:
        registry = gen_ebnf_registry.parse(ebnf)
    except SystemExit as exc:            # its own refusal: a registry it cannot read
        raise CatalogueError(str(exc.code)) from None
    bad = registry.check()
    if bad:
        raise CatalogueError(f"{os.path.relpath(ebnf, ROOT)}: {'; '.join(bad)}")
    codes = [(name, number) for name, number in registry.live
             if name != gen_ebnf_registry.VALIDATE_ZERO]
    if not codes:
        raise CatalogueError(f"{os.path.relpath(ebnf, ROOT)}: no live code")
    return codes


def diagnostic_rows(tree: dict[str, dict[str, Any]], codes: list[tuple[str, int]]
                    ) -> tuple[Rows, list[str], list[str]]:
    """The diagnostics' rows, with the codes they leave out and the codes no
    clause names. A code goes when a deferred clause's `errors` names it and no
    live clause's does (R4.2). A code no clause names is another case: it stays,
    and the run prints it so it can be filed. A tombstone names nothing."""
    raised_by: dict[str, list[str]] = {}
    deferred: set[str] = set()
    for cid, clause in sorted(tree.items(), key=lambda kv: _id_key(kv[0])):
        if binds(clause):
            for name in clause.get("errors") or []:
                raised_by.setdefault(name, []).append(cid)
        elif clause.get("kind") != "tombstone":
            deferred.update(clause.get("errors") or [])
    dropped = [name for name, _ in codes if name in deferred and name not in raised_by]
    kept_refusals = sorted(set(DEFERRAL_REFUSALS) & set(dropped))
    if kept_refusals:
        raise CatalogueError("only a deferred clause names " + ", ".join(kept_refusals)
                             + ", a refusal the compiler issues in this edition")
    unnamed = [name for name, _ in codes if name not in deferred and name not in raised_by]
    rows = [[code(name), str(number), cites(raised_by.get(name, []))]
            for name, number in codes if name not in dropped]
    return rows, dropped, unnamed


def diagnostics(tree: dict[str, dict[str, Any]], ebnf: str = VALIDATE_EBNF) -> str:
    """The compile-time diagnostics: the live codes of `validate.ebnf` this
    edition can raise, with the clauses whose `errors` name each."""
    rows, _dropped, _unnamed = diagnostic_rows(tree, validate_codes(ebnf))
    if not rows:
        raise CatalogueError("every live code of validate.ebnf is deferred")
    return render(["Code", "Number", "Raised by"], rows, "`specs/registry/validate.ebnf`")


def _id_key(cid: str) -> list[Any]:
    """A clause id in document order: LEXP.3.10 after LEXP.3.9."""
    return [(0, int(p), "") if p.isdigit() else (1, 0, p)
            for p in re.findall(r"\d+|[A-Za-z]+", cid)]


REALTIME_CENSUS = "NERR.18"


def realtime_only(tree: dict[str, dict[str, Any]]) -> set[str]:
    """The codes the reference books leave out as realtime's (R4.2): exactly
    those [NERR.18], which is deferred, defines. Its table and its `defines`
    must name the same codes."""
    clause = tree.get(REALTIME_CENSUS)
    if clause is None or clause.get("kind") == "tombstone" or not clause.get("deferred"):
        raise CatalogueError(f"[{REALTIME_CENSUS}] is absent or not deferred")
    defined = set((clause.get("defines") or {}).get("errors") or [])
    if not defined:
        raise CatalogueError(f"[{REALTIME_CENSUS}] defines no code")
    parsed = spec_render.parse_md_table(clause.get("text", ""))
    if parsed is None or parsed[0][:1] != ["Code"]:
        raise CatalogueError(f"[{REALTIME_CENSUS}] carries no Code table")
    rows = {name for row in parsed[1] for name in spec_registry.CODE_IN_CELL.findall(row[0])}
    if rows != defined:
        raise CatalogueError(f"[{REALTIME_CENSUS}]: its table and its defines differ on "
                             + ", ".join(sorted(rows ^ defined)))
    return defined


def errors(tree: dict[str, dict[str, Any]], header: str | None = None) -> str:
    """The `DS_ERR_*` codes: one row per live `#define` in libds.h (`header`,
    its text, read from the tree when not given), with its value from the
    header, which decides the C API's values, and its meaning from the [NERR]
    census row that names it in its Code column. A code [NERR.18] defines is
    realtime's and has no row here (`realtime_only`), and no row in a binding
    census clause."""
    if header is None:
        header = read_text(spec_registry.LIBDS_H)
    defined = {}
    for line in header.splitlines():
        m = spec_registry.ERR_RE.match(line)
        if m and m.group(1) not in spec_registry.RETIRED_ERRORS:
            defined[m.group(1)] = int(m.group(2))
    if not defined:
        raise CatalogueError("runtime/include/libds.h: no DS_ERR_* #define")
    realtime = realtime_only(tree)
    undeclared = sorted(realtime - set(defined))
    if undeclared:
        raise CatalogueError(f"[{REALTIME_CENSUS}] defines " + ", ".join(undeclared)
                             + ", which libds.h does not define")

    meaning: dict[str, tuple[str, str]] = {}
    for cid, clause in sorted(tree.items(), key=lambda kv: _id_key(kv[0])):
        if not cid.startswith("NERR.") or not binds(clause):
            continue
        parsed = spec_render.parse_md_table(clause.get("text", ""))
        if parsed is None:
            continue
        columns, rows = parsed
        if not columns or columns[0] != "Code":
            continue
        for row in rows:
            for name in spec_registry.CODE_IN_CELL.findall(row[0]):
                if name not in defined:
                    raise CatalogueError(f"[{cid}] has a row for `{name}`, which "
                                         "libds.h does not define")
                if name in realtime:
                    raise CatalogueError(f"`{name}` has a row in [{cid}] and in "
                                         f"[{REALTIME_CENSUS}]")
                if name in meaning:
                    raise CatalogueError(f"`{name}` has a row in [{meaning[name][1]}] "
                                         f"and in [{cid}]")
                meaning[name] = (row[-1], cid)
    unlisted = sorted(set(defined) - set(meaning) - realtime)
    if unlisted:
        raise CatalogueError("no [NERR] census row names " + ", ".join(unlisted)
                             + " in its Code column")
    rows = [[code(name), str(value), meaning[name][0], cites([meaning[name][1]])]
            for name, value in sorted(defined.items(), key=lambda kv: -kv[1])
            if name not in realtime]
    return render(["Code", "Value", "Meaning", "Census"], rows,
                  "the [NERR] census and `runtime/include/libds.h`")


EVENT_KIND_PROTO = os.path.join(ROOT, "proto", "stream_event_kind.proto")
# The clauses whose Kind tables state the kinds: emitted, reserved, and the faults.
EVENT_KIND_CLAUSES = ("NCBK.2.3", "NCBK.2.4", "NCBK.2.8")
_EVENT_KIND_IN_CELL = re.compile(r"`DS_EV_([A-Z0-9_]*[A-Z0-9])`")


def event_kinds(tree: dict[str, dict[str, Any]], proto: str = EVENT_KIND_PROTO) -> str:
    """The stream event kinds: one row per member of `StreamEventKind`, which
    libds.h's `ds_stream_ev_kind_t` mirrors ([STYL.5.9.7]), by value, with the
    clause whose Kind table has its row. A retired number is no member, so it
    has no row; a kind declared and never emitted is a member, so it has one."""
    read_text(proto)
    members = spec_registry._enum_members(proto, "STREAM_EVENT_KIND_")
    if not members:
        raise CatalogueError(f"{os.path.relpath(proto, ROOT)}: no STREAM_EVENT_KIND_ member")
    stated: dict[str, str] = {}
    for cid in EVENT_KIND_CLAUSES:
        clause = tree.get(cid)
        readable = clause is not None and binds(clause)
        parsed = spec_render.parse_md_table(clause.get("text", "")) if readable else None
        if parsed is None or parsed[0][:1] != ["Kind"]:
            raise CatalogueError(f"[{cid}] carries no Kind table")
        for row in parsed[1]:
            names = _EVENT_KIND_IN_CELL.findall(row[0])
            if len(names) != 1:
                raise CatalogueError(f"[{cid}]: a Kind cell names no one kind: {row[0]!r}")
            if names[0] not in members:
                raise CatalogueError(f"[{cid}] has a row for `DS_EV_{names[0]}`, "
                                     "which StreamEventKind does not have")
            if names[0] in stated:
                raise CatalogueError(f"`DS_EV_{names[0]}` has a row in [{stated[names[0]]}] "
                                     f"and in [{cid}]")
            stated[names[0]] = cid
    unstated = sorted(set(members) - set(stated))
    if unstated:
        raise CatalogueError("no Kind table has a row for "
                             + ", ".join(f"DS_EV_{n}" for n in unstated))
    rows = [[code(f"DS_EV_{name}"), str(value), cites([stated[name]])]
            for name, value in sorted(members.items(), key=lambda kv: kv[1])]
    return render(["Kind", "Value", "Clause"], rows, "`proto/stream_event_kind.proto`")


UNITS_COLUMNS = ["Module", "Unit", "Dimension", "Conversion", "Label", "Aliases"]
# A declaration with no conversion declares the base unit ([LUNI.4.3]).
UNIT_BASE = "base"
# Currency is not part of this edition, so `units.currency` has no rows
#. `units` stops if [LUNI.13.11] ever stops saying so.
CURRENCY_CLAUSE = "LUNI.13.11"
CURRENCY_MODULE = "units.currency"

_UNIT_LINE = re.compile(r"unit\b")
_LABEL = r'(?:\s*label\s+"(?P<label>[^"]*)")?'
_LINE_END = r"\s*(?:#.*)?$"
# [LUNI.4]: a form word followed by `:` begins a unit_symbol, which these leave to
# _UNIT_SYMBOL by requiring a name after the form word.
_UNIT_DIMENSION = re.compile(
    r"unit\s+dimension\s+(?P<name>\w+)\s+storage\s+\w+(?:\s+base\s+\S+)?" + _LABEL + _LINE_END)
_UNIT_SCALAR = re.compile(r"unit\s+scalar\s+(?P<name>\w+)\s+storage\s+\w+" + _LABEL + _LINE_END)
_UNIT_FORMULA = re.compile(r"unit\s+formula\s+\w+(?:\s+\w+)*\s*:" + _LINE_END)
_UNIT_SYMBOL = re.compile(r'unit\s+(?P<unit>[^\s:,#="]+)\s*:\s*(?P<dimension>\w+)(?P<rest>.*)$')
_TIER_2_REST = re.compile(r"\s*:" + _LABEL + _LINE_END)
_INLINE_REST = re.compile(r"(?:\s*=\s*(?P<body>.*?))?" + _LABEL
                          + r"(?:\s*alias\s+(?P<aliases>[^#]*?))?" + _LINE_END)
_ALIAS = re.compile(r'[^\s:,#="]+')
_TIER_2_BODY = re.compile(r"\s+(?P<key>to_base|from_base)\s*:\s*(?P<body>[^#]*?)" + _LINE_END)
# [LUNI.4.3]'s vocabularies. A tier-1 body is tested against its own because `.*?`
# above would otherwise take a malformed label or alias into the body.
_NUMBER_OR_OPERATOR = r"\d[\d_.]*(?:e[-+]?\d+)?|\*\*|[-+*/()]"
_TIER_1_TOKEN = re.compile(r"\b(?:x|pi)\b|" + _NUMBER_OR_OPERATOR)
_TIER_2_TOKEN = re.compile(r"\b(?:x|pi|sqrt|abs|ln|log10|log2|exp)\b|" + _NUMBER_OR_OPERATOR)


def _body_reads(body: str, vocabulary: re.Pattern[str]) -> bool:
    return (not vocabulary.sub(" ", body).strip() and bool(body.strip())
            and body.count("(") == body.count(")"))


def _unit_symbol(line: str) -> tuple[str, str, str, list[str], str | None] | None:
    """A [LUNI.4.3] declaration line as its unit, dimension, label, aliases and
    conversion, or None when it is not one. A tier-2 head's conversion is None:
    it is on the lines that follow."""
    head = _UNIT_SYMBOL.match(line)
    if head is None:
        return None
    tier_2 = _TIER_2_REST.match(head["rest"])
    if tier_2 is not None:
        return head["unit"], head["dimension"], tier_2["label"] or "", [], None
    inline = _INLINE_REST.match(head["rest"])
    if inline is None:
        return None
    body = inline["body"]
    if body is not None and not _body_reads(body, _TIER_1_TOKEN):
        return None
    aliases = [] if inline["aliases"] is None else [
        a.strip() for a in inline["aliases"].split(",")]
    if not all(_ALIAS.fullmatch(a) for a in aliases):
        return None
    conversion = UNIT_BASE if body is None else code(" ".join(body.split()))
    return head["unit"], head["dimension"], inline["label"] or "", aliases, conversion


def _tier_2_conversion(where: str, following: Iterator[tuple[int, str]]) -> str:
    """The two lines after a tier-2 head, in [LUNI.4.3]'s order, as one cell."""
    parts = []
    for key in ("to_base", "from_base"):
        number, line = next(following, (0, ""))
        body = _TIER_2_BODY.match(line)
        if body is None or body["key"] != key or not _body_reads(body["body"], _TIER_2_TOKEN):
            raise CatalogueError(f"{where}: a tier-2 unit's next line is not its `{key}:`: "
                                 f"{line!r}")
        parts.append(code(f"{key}: {' '.join(body['body'].split())}"))
    return "; ".join(parts)


def unit_rows(modules: dict[str, str]) -> Rows:
    """The units `modules` (module name to its source) declare, by module and in
    source order. A `unit scalar` that no unit is a member of is itself the unit
    ([LUNI.6.2]), and has a row of its own. A scalar with members and a `unit
    dimension` are groups, and a `unit formula` converts, so none has a row."""
    declared: set[str] = set()
    entries: list[tuple[str, str, str, str, str, list[str], bool]] = []
    for module in sorted(modules):
        if module == CURRENCY_MODULE:
            continue
        # Comments and blank lines never reach the parser ([LGRA.3.1]), so none
        # stands between a tier-2 head and its body.
        lines = iter([(number, line) for number, line
                      in enumerate(modules[module].splitlines(), 1)
                      if line.strip() and not line.lstrip().startswith("#")])
        for number, line in lines:
            if _TIER_2_BODY.match(line) is not None:
                raise CatalogueError(f"{module}, line {number}: no tier-2 head before {line!r}")
            if _UNIT_LINE.match(line) is None:
                continue
            scalar = _UNIT_SCALAR.match(line)
            dimension = _UNIT_DIMENSION.match(line)
            symbol = _unit_symbol(line)
            if scalar is not None:
                declared.add(scalar["name"])
                entries.append((module, scalar["name"], scalar["name"], UNIT_BASE,
                                scalar["label"] or "", [], True))
            elif dimension is not None:
                declared.add(dimension["name"])
            elif symbol is not None:
                unit, group, label, aliases, conversion = symbol
                if conversion is None:
                    conversion = _tier_2_conversion(f"{module}, line {number}", lines)
                entries.append((module, unit, group, conversion, label, aliases, False))
            elif _UNIT_FORMULA.match(line) is None:
                raise CatalogueError(f"{module}, line {number}: cannot read {line!r}")
    members = {entry[2] for entry in entries if not entry[-1]}
    unknown = sorted(members - declared)
    if unknown:
        raise CatalogueError("a unit's dimension is declared nowhere: " + ", ".join(unknown))
    rows = [[code(module), code(unit), code(group), conversion, code(label) if label else "",
             ", ".join(code(a) for a in aliases)]
            for module, unit, group, conversion, label, aliases, is_scalar in entries
            if not (is_scalar and unit in members)]
    empty = sorted(set(modules) - {CURRENCY_MODULE}
                   - {module for module, *_ in entries})
    if empty or not rows:
        raise CatalogueError("no unit declared in " + (", ".join(empty) or "any module"))
    return rows


def units(tree: dict[str, dict[str, Any]], directory: str = UNITS_DIR) -> str:
    """The standard library's units: the declarations of `stdlib/units/*.ds`."""
    clause = tree.get(CURRENCY_CLAUSE)
    if clause is None or not binds(clause):
        raise CatalogueError(f"[{CURRENCY_CLAUSE}] is absent or does not bind, so nothing "
                             f"says {CURRENCY_MODULE} leaves the table")
    if not os.path.isdir(directory):
        raise CatalogueError(f"{os.path.relpath(directory, ROOT)}: no such directory")
    names = sorted(n for n in os.listdir(directory) if n.endswith(".ds"))
    if not names:
        raise CatalogueError(f"{os.path.relpath(directory, ROOT)}: no module")
    modules = {f"units.{name[:-len('.ds')]}": read_text(os.path.join(directory, name))
               for name in names}
    return render(UNITS_COLUMNS, unit_rows(modules), "`stdlib/units/*.ds`")


# Each catalogue: the book it belongs to, its file under that book's
# `_generated/`, and its generator.
CATALOGUES: list[tuple[str, str, Callable[[dict[str, dict[str, Any]]], str]]] = [
    ("docs/references/author", "builtins.md", builtins),
    ("docs/references/author", "aggregations.md", aggregations),
    ("docs/references/author", "keywords.md", keywords),
    ("docs/references/author", "diagnostics.md", diagnostics),
    ("docs/references/author", "units.md", units),
    ("docs/references/integrator", "errors.md", errors),
    ("docs/references/integrator", "event_kinds.md", event_kinds),
]


# -- negative fixtures, fed on every run ----------------------------------------

def _clause(cid: str, **fields: Any) -> dict[str, Any]:
    return {"id": cid, "kind": "table", "text": "", **fields}


_MISSING = os.path.join(HERE, "no-such-source")
_NERR_TABLE = "| Code | Meaning |\n|---|---|\n| `DS_ERR_{}` | a meaning |\n"


def _realtime(defines: tuple[str, ...] = ("RT",), rows: tuple[str, ...] = ("RT",),
              deferred: bool = True) -> dict[str, Any]:
    """A [NERR.18] defining `defines`, with a row for each of `rows`."""
    return _clause(REALTIME_CENSUS, deferred=deferred,
                   defines={"errors": [f"DS_ERR_{c}" for c in defines]},
                   text="| Code | Meaning |\n|---|---|\n"
                        + "".join(f"| `DS_ERR_{c}` | m |\n" for c in rows))


def _nerr(*codes: str) -> dict[str, dict[str, Any]]:
    """A census with a row for each of `codes`, beside a [NERR.18] defining RT."""
    return {**{f"NERR.{n}": _clause(f"NERR.{n}", text=_NERR_TABLE.format(c))
               for n, c in enumerate(codes, 1)},
            REALTIME_CENSUS: _realtime()}


def _header_of(*codes: str) -> str:
    """A libds.h defining `codes` and [NERR.18]'s RT."""
    return "\n".join(f"#define DS_ERR_{c} -{n}" for n, c in enumerate((*codes, "RT"), 1))


def _error_codes() -> set[str]:
    return set(spec_registry.CODE_IN_CELL.findall(
        errors(_nerr("INVAL", "CONTRACT_BREACH"), _header_of("INVAL", "CONTRACT_BREACH"))))


_EVERY_KIND = [*spec_registry._enum_members(EVENT_KIND_PROTO, "STREAM_EVENT_KIND_")] \
    if os.path.isfile(EVENT_KIND_PROTO) else []


def _kinds(emitted: list[str] | None = None, reserved: list[str] | None = None,
           faults: list[str] | None = None) -> dict[str, dict[str, Any]]:
    """EVENT_KIND_CLAUSES' Kind tables, by default every kind: its first in
    [NCBK.2.4], its last in [NCBK.2.8] and the rest in [NCBK.2.3]. A table with
    no row is no table, so each has one."""
    held = (_EVERY_KIND[1:-1] if emitted is None else emitted,
            _EVERY_KIND[:1] if reserved is None else reserved,
            _EVERY_KIND[-1:] if faults is None else faults)
    return {cid: _clause(cid, text="| Kind | Note |\n|---|---|\n" + "".join(
                f"| `DS_EV_{k}` | n |\n" for k in kinds))
            for cid, kinds in zip(EVENT_KIND_CLAUSES, held)}


def _builtin(name: str, defined_by: str) -> list[str]:
    return [name, "1", "pure", "(cursor) → Int", "s", defined_by]


_AGGREGATION_TREE = {
    "LEXP.17.2": _clause("LEXP.17.2", data={"columns": BUILTINS_COLUMNS, "rows": [
        _builtin("abs", "LEXP.3.1"), _builtin("mean", "LSER.16.2")]}),
    "LEXP.3.1": _clause("LEXP.3.1"), "LSER.16.2": _clause("LSER.16.2"),
}


def _named_by(live: tuple[str, ...] = (), deferred: tuple[str, ...] = ()
              ) -> dict[str, dict[str, Any]]:
    """A clause tree in which LX.1 is live and LX.2 deferred, each naming its codes."""
    return {"LX.1": _clause("LX.1", errors=list(live)),
            "LX.2": _clause("LX.2", errors=list(deferred), deferred=True)}


def _left_out(live: tuple[str, ...] = (), deferred: tuple[str, ...] = (),
              code_name: str = "DS_VALIDATE_X") -> tuple[int, list[str], list[str]]:
    """How many rows `code_name` has, with the codes dropped and those no clause names."""
    rows, dropped, unnamed = diagnostic_rows(_named_by(live, deferred), [(code_name, 1)])
    return len(rows), dropped, unnamed


_UNITS_HEAD = "unit dimension length storage float64 base meter\nunit meter: length\n"


def _units_with(*lines: str) -> Rows:
    return unit_rows({"units.core": _UNITS_HEAD + "\n".join(lines) + "\n"})


def _every_unit_form() -> Rows:
    return _units_with(
        "# unit no_such: a comment",
        'unit foot: length = (x - 1) * 304.8e-3 / 2  label "ft"  alias ft, f  # a comment',
        "unit fathom: length = x ** 2",
        'unit phon: length:  label "ph#on"',
        "    # a comment between the head and its body",
        "    to_base:   2.0 ** ((x - 40.0) / 10.0)",
        "",
        "    from_base: 10.0 * log2(x) + 40.0  # a comment",
        "unit scalar angle storage float64",
        "unit radian: angle",
        'unit scalar dB storage float64 label "generic decibel"',
        "unit formula f inverting implicit:",
        "    a(x: meter): meter = x",
        "unit scalar: length",
    )


# What a catalogue must leave in and leave out, held like the refusals.
BEHAVES: list[tuple[str, Callable[[], bool]]] = [
    ("every code with a row in a binding census clause stays",
     lambda: {"DS_ERR_INVAL", "DS_ERR_CONTRACT_BREACH"} <= _error_codes()),
    ("a code [NERR.18] defines goes", lambda: "DS_ERR_RT" not in _error_codes()),
    ("[NERR.18]'s defines are the realtime set",
     lambda: realtime_only({REALTIME_CENSUS: _realtime(("RT", "WM"), ("WM", "RT"))})
     == {"DS_ERR_RT", "DS_ERR_WM"}),
    ("an aggregation is a row an LSER.16.* clause defines",
     lambda: "`mean`" in aggregations(_AGGREGATION_TREE)
     and "`abs`" not in aggregations(_AGGREGATION_TREE)),
    ("an aggregation leaves the builtins, and the other rows stay",
     lambda: "`mean`" not in builtins(_AGGREGATION_TREE)
     and "`abs`" in builtins(_AGGREGATION_TREE)),
    ("a code only a deferred clause names goes, and the run can name it",
     lambda: _left_out(deferred=("DS_VALIDATE_X",)) == (0, ["DS_VALIDATE_X"], [])),
    ("a code a live and a deferred clause both name stays",
     lambda: _left_out(("DS_VALIDATE_X",), ("DS_VALIDATE_X",)) == (1, [], [])),
    ("a code no clause names stays, and the run can name it",
     lambda: _left_out() == (1, [], ["DS_VALIDATE_X"])),
    ("a code only a tombstone names is named by no clause",
     lambda: diagnostic_rows({"LX.1": _clause("LX.1", kind="tombstone", errors=["DS_VALIDATE_X"])},
                             [("DS_VALIDATE_X", 1)])[1:] == ([], ["DS_VALIDATE_X"])),
    ("a deferral refusal a live clause names stays",
     lambda: _left_out(DEFERRAL_REFUSALS[:1], code_name=DEFERRAL_REFUSALS[0])
     == (1, [], [])),
    ("each unit form reads as what it declares",
     lambda: _every_unit_form() == [
         [code("units.core"), code(unit), code(group), conversion, label, aliases]
         for unit, group, conversion, label, aliases in (
             ("meter", "length", "base", "", ""),
             ("foot", "length", code("(x - 1) * 304.8e-3 / 2"), code("ft"),
              f"{code('ft')}, {code('f')}"),
             ("fathom", "length", code("x ** 2"), "", ""),
             ("phon", "length", code("to_base: 2.0 ** ((x - 40.0) / 10.0)") + "; "
              + code("from_base: 10.0 * log2(x) + 40.0"), code("ph#on"), ""),
             ("radian", "angle", "base", "", ""),
             ("dB", "dB", "base", code("generic decibel"), ""),
             ("scalar", "length", "base", "", ""))]),
    ("a row's conversion is in the Conversion column of the table",
     lambda: render(UNITS_COLUMNS, _units_with("unit fathom: length = x * 1.8288"), "s")
     .splitlines()[-1].split(" | ")[3] == code("x * 1.8288")),
    ("units.currency has no rows, and its fx_pair is never read",
     lambda: unit_rows({"units.core": _UNITS_HEAD,
                        CURRENCY_MODULE: "unit fx_pair A_to_B: a to b\nunit USD: currency\n"})
     == [[code("units.core"), code("meter"), code("length"), "base", "", ""]]),
    ("a unit may join a group another module declares",
     lambda: len(unit_rows({"units.core": _UNITS_HEAD, "units.x": "unit foot: length = x\n"})) == 2),
    ("the kinds come in value order, each with its clause",
     lambda: re.findall(r"^\| `DS_EV_(\w+)` \| (\d+) \| \[(NCBK\.2\.[348])\] \|$",
                        event_kinds(_kinds()), re.M)[:2]
     == [(_EVERY_KIND[0], "0", "NCBK.2.4"), (_EVERY_KIND[1], "1", "NCBK.2.3")]),
]


NEGATIVE: list[tuple[str, Callable[[], object]]] = [
    ("a clause file that does not exist", lambda: read_clause(_MISSING)),
    ("a clause file that is not JSON", lambda: read_clause(__file__)),
    ("the builtins clause absent", lambda: builtins({})),
    ("the builtins table with no rows",
     lambda: builtins({"LEXP.17.2": _clause("LEXP.17.2", data={
         "columns": BUILTINS_COLUMNS, "rows": []})})),
    ("the keywords table with other columns",
     lambda: keywords({"LLEX.9.6": _clause("LLEX.9.6", data={
         "columns": ["Word", "Class"], "rows": [["abs", ""]]})})),
    ("the keywords clause deferred",
     lambda: keywords({"LLEX.9.6": _clause("LLEX.9.6", deferred=True, data={
         "columns": KEYWORDS_COLUMNS, "rows": [["abs", "builtin", ""]]})})),
    ("a builtin defined by no clause",
     lambda: builtins({"LEXP.17.2": _clause("LEXP.17.2", data={
         "columns": BUILTINS_COLUMNS,
         "rows": [["abs", "1", "pure", "(x: Int) → Int", "s", "LEXP.0.0"]]})})),
    ("the builtins with every row an aggregation",
     lambda: builtins({"LEXP.17.2": _clause("LEXP.17.2", data={
         "columns": BUILTINS_COLUMNS, "rows": [_builtin("mean", "LSER.16.2")]}),
         "LSER.16.2": _clause("LSER.16.2")})),
    ("the validate registry absent", lambda: diagnostics({}, _MISSING)),
    *[(f"{refusal} named only by a deferred clause",
       lambda name=refusal: _left_out(deferred=(name,), code_name=name))
      for refusal in DEFERRAL_REFUSALS],
    ("the units with [LUNI.13.11] absent", lambda: units({})),
    ("the units with [LUNI.13.11] deferred",
     lambda: units({CURRENCY_CLAUSE: _clause(CURRENCY_CLAUSE, deferred=True)})),
    ("the units' directory absent",
     lambda: units({CURRENCY_CLAUSE: _clause(CURRENCY_CLAUSE)}, _MISSING)),
    ("a units directory with no module",
     lambda: units({CURRENCY_CLAUSE: _clause(CURRENCY_CLAUSE)}, HERE)),
    ("a unit line with no dimension", lambda: _units_with("unit foot length")),
    ("a unit label that is no string", lambda: _units_with("unit foot: length label ft")),
    ("a label read into a body", lambda: _units_with("unit foot: length = x label ft")),
    ("a body outside the tier-1 vocabulary", lambda: _units_with("unit foot: length = sin(x)")),
    ("a body left open", lambda: _units_with("unit foot: length = (x *")),
    ("an empty body", lambda: _units_with("unit foot: length =")),
    ("an alias on a tier-2 head", lambda: _units_with('unit foot: length: label "f" alias f')),
    ("a tier-2 head at the end of its module", lambda: _units_with("unit foot: length:")),
    ("a tier-2 head with to_base alone",
     lambda: _units_with("unit foot: length:", "    to_base: x", "unit yard: length")),
    ("a tier-2 body in the wrong order",
     lambda: _units_with("unit foot: length:", "    from_base: x", "    to_base: x")),
    ("a tier-2 body outside its vocabulary",
     lambda: _units_with("unit foot: length:", "    to_base: sin(x)", "    from_base: x")),
    ("a tier-2 body left open",
     lambda: _units_with("unit foot: length:", "    to_base: (x", "    from_base: x")),
    ("an empty tier-2 body",
     lambda: _units_with("unit foot: length:", "    to_base:", "    from_base: x")),
    ("a to_base after a tier-1 unit",
     lambda: _units_with("unit foot: length = x", "    to_base: x")),
    ("an alias list with a hole", lambda: _units_with("unit foot: length alias f,")),
    ("a form word with no name", lambda: _units_with("unit scalar storage float64")),
    ("a dimension with no storage", lambda: _units_with("unit dimension area base m")),
    ("a formula with no body's colon", lambda: _units_with("unit formula f")),
    ("an fx_pair outside units.currency", lambda: _units_with("unit fx_pair A_to_B: a to b")),
    ("a unit of a dimension declared nowhere", lambda: _units_with("unit foot: width = x")),
    ("a module declaring no unit",
     lambda: unit_rows({"units.core": _UNITS_HEAD, "units.x": "from math import pi\n"})),
    ("no module at all", lambda: unit_rows({})),
    ("a header that does not exist", lambda: read_text(_MISSING)),
    ("a header with no DS_ERR_* #define", lambda: errors(_nerr("INVAL"), "")),
    ("a libds.h code with no census row",
     lambda: errors(_nerr("INVAL"), _header_of("INVAL", "OOM"))),
    ("a census row for a code libds.h does not define",
     lambda: errors(_nerr("INVAL", "OOM"), _header_of("INVAL"))),
    ("one code with rows in two census clauses",
     lambda: errors(_nerr("INVAL", "INVAL"), _header_of("INVAL"))),
    ("a code whose only row is in another deferred clause",
     lambda: errors({**_nerr("INVAL"), "NERR.2": _clause(
         "NERR.2", deferred=True, text=_NERR_TABLE.format("OOM"))},
         _header_of("INVAL", "OOM"))),
    ("[NERR.18] absent", lambda: realtime_only({})),
    ("[NERR.18] not deferred",
     lambda: realtime_only({REALTIME_CENSUS: _realtime(deferred=False)})),
    ("[NERR.18] a tombstone",
     lambda: realtime_only({REALTIME_CENSUS: {**_realtime(), "kind": "tombstone"}})),
    ("[NERR.18] defining nothing",
     lambda: realtime_only({REALTIME_CENSUS: _realtime(defines=())})),
    ("[NERR.18] with no table",
     lambda: realtime_only({REALTIME_CENSUS: {**_realtime(), "text": "prose"}})),
    ("a code [NERR.18] defines with no row",
     lambda: realtime_only({REALTIME_CENSUS: _realtime(defines=("RT", "WM"))})),
    ("a [NERR.18] row for a code it does not define",
     lambda: realtime_only({REALTIME_CENSUS: _realtime(rows=("RT", "WM"))})),
    ("a code both [NERR.18] and a binding clause have a row for",
     lambda: errors(_nerr("INVAL", "RT"), _header_of("INVAL"))),
    ("a code [NERR.18] defines that libds.h does not",
     lambda: errors(_nerr("INVAL"), "#define DS_ERR_INVAL -1")),
    ("the aggregations with no LSER.16.* row",
     lambda: aggregations({"LEXP.17.2": _clause("LEXP.17.2", data={
         "columns": BUILTINS_COLUMNS, "rows": [_builtin("abs", "LEXP.3.1")]}),
         "LEXP.3.1": _clause("LEXP.3.1")})),
    ("the event kinds' proto absent", lambda: event_kinds(_kinds(), _MISSING)),
    ("a proto with no StreamEventKind member", lambda: event_kinds(_kinds(), __file__)),
    ("a Kind clause absent", lambda: event_kinds({})),
    ("a Kind clause deferred",
     lambda: event_kinds({**_kinds(), "NCBK.2.8": {**_kinds()["NCBK.2.8"], "deferred": True}})),
    ("a Kind cell naming no kind",
     lambda: event_kinds({**_kinds(), "NCBK.2.3": _clause("NCBK.2.3", text=(
         "| Kind | Note |\n|---|---|\n| none | n |\n"))})),
    ("a kind with no row", lambda: event_kinds(_kinds(emitted=_EVERY_KIND[2:-1]))),
    ("a row for a kind the proto does not have",
     lambda: event_kinds(_kinds(emitted=[*_EVERY_KIND[1:-1], "NO_SUCH_KIND"]))),
    ("one kind with rows in two clauses",
     lambda: event_kinds(_kinds(faults=[*_EVERY_KIND[-1:], *_EVERY_KIND[:1]]))),
]


def refusals_refuse() -> list[str]:
    """The fixtures some reader accepted; empty when every one was refused."""
    accepted = []
    for what, run in NEGATIVE:
        try:
            run()
        except CatalogueError:
            continue
        accepted.append(what)
    return accepted


def behaviours_broken() -> list[str]:
    """The BEHAVES entries that do not hold; empty when every one does."""
    broken = []
    for what, holds in BEHAVES:
        try:
            if holds():
                continue
        except CatalogueError as exc:
            what = f"{what} ({exc})"
        broken.append(what)
    return broken


# -- main -----------------------------------------------------------------------


def main(argv: list[str]) -> int:
    if argv:
        print(__doc__, file=sys.stderr)
        return 2
    accepted = refusals_refuse()
    if accepted:
        for what in accepted:
            print(f"catalogues: accepted {what}, which it must refuse", file=sys.stderr)
        return 1
    broken = behaviours_broken()
    if broken:
        for what in broken:
            print(f"catalogues: does not hold: {what}", file=sys.stderr)
        return 1
    try:
        tree = clause_tree()
        written = [(book, name, make(tree)) for book, name, make in CATALOGUES]
        realtime = sorted(realtime_only(tree))
        _rows, deferred_only, unnamed = diagnostic_rows(tree, validate_codes())
    except CatalogueError as exc:
        print(f"catalogues: {exc}", file=sys.stderr)
        return 1
    for book, name, text in written:
        path = os.path.join(ROOT, book, "_generated", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"catalogues: wrote {book}/_generated/{name} "
              f"({text.count(chr(10)) - 4} rows)")
    print(f"catalogues: errors.md leaves out as realtime's: {', '.join(realtime)}")
    print("catalogues: diagnostics.md leaves out as only deferred clauses': "
          f"{', '.join(deferred_only) or 'nothing'}")
    print("catalogues: diagnostics.md keeps, named by no clause, to be filed: "
          f"{', '.join(unnamed) or 'nothing'}")
    print(f"catalogues: {len(NEGATIVE)} negative fixtures refused, {len(BEHAVES)} behaviours hold")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

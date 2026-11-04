#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# spec_render.py -- project a structured spec document directory (specs/<tree>/<DOC>/)
# back to its Markdown book (STYL.5.6). Because each clause's `text` is the verbatim
# source span and every source line is covered, rendering is: the manifest preamble,
# then each clause's `text` in `seq` order. The rendered Markdown is a build product,
# not committed to the normative tree.
#
# Usage: spec_render.py specs/<tree>/<DOC>            (prints the reconstructed Markdown)
# Pure stdlib.

import glob
import json
import os
import re
import sys
from typing import Any


def load_doc(docdir):
    """(manifest, clauses-sorted-by-seq) for a specs/<tree>/<DOC>/ directory. Shared
    by the byte-exact projection (render_doc) and the enriched book renderer
    (spec_book.render_book_page)."""
    with open(os.path.join(docdir, "_file.json"), encoding="utf-8") as fh:
        manifest = json.load(fh)
    clauses = []
    for p in glob.glob(os.path.join(docdir, "*.json")):
        if os.path.basename(p) == "_file.json":
            continue
        with open(p, encoding="utf-8") as fh:
            clauses.append(json.load(fh))
    clauses.sort(key=lambda c: c["seq"])
    return manifest, clauses


def render_doc(docdir):
    manifest, clauses = load_doc(docdir)
    out = [manifest.get("preamble", "")]
    for c in clauses:
        if c.get("kind") == "tombstone":
            continue  # a retired-ID stub carries no prose (STYL.2.8.4)
        out.append(c["text"])
    return "".join(out)


def render_ebnf_block(source: str) -> str:
    """Render an `ebnf` `data` payload as the fenced block that goes in `text`.

    The counterpart of `render_md_table`, and deliberately as dumb: `data` is the
    source, so the render must be a pure function of it with nothing added. The
    fence language is `ebnf` because `[STYL.2.15.2]` registers that as THE
    notation for grammars, and `docs/` highlights on it.
    """
    return "```ebnf\n" + source.rstrip("\n") + "\n```"

def render_clause_data(data: dict[str, Any]) -> str:
    """Render whichever shape `data` carries — the one dispatch point.

    EBNFFOLD1. Presence is the discriminator, and the schema's
    `oneOf` with `additionalProperties: false` on
    both arms is what makes that safe: an object carrying both keys, or neither,
    validates against nothing and never reaches here.

    ONE FUNCTION BECAUSE THE GATE AND THE GENERATOR MUST NOT DISAGREE. The
    byte-exactness gate renders through `load_md_rendered` and `--regen-tables`
    writes through `regenerate_clause_data`; both call this, so a shape added
    later is added once. Splitting them is how `text` and `data` drift, which is
    the whole thing `[STYL.5.3.2.1]` exists to prevent.
    """
    if "ebnf" in data:
        return render_ebnf_block(data["ebnf"])
    return render_md_table(data["columns"], data["rows"])

# A cell boundary is a pipe no backslash escapes. A pipe that is part of a
# table's content is written `\|` in its Markdown (`[LEXP.3.9.3]`'s `\|x\|`, the
# bitwise-or rows of `[IRET.9.7]` and `[RLOW.6.1.1]`), and splitting on every
# pipe cut those cells in two: the row's count no longer matched the header, and
# the whole table read as absent.
#
# A `data` cell is a value a tool reads ([STYL.5.3.2.1]), so it holds its pipes
# bare: [LEXP.17.2]'s `Int | Float` is what `ds lsp` shows. The escape is the
# render's to add (`_md_cell`), never the cell's to carry. A `\|` a cell
# already holds is left alone, so a table parsed from `text` renders back
# byte for byte.
_MD_CELL_BOUNDARY = re.compile(r"(?<!\\)\|")


def _md_cell(cell: str) -> str:
    """A cell as its Markdown table writes it: every pipe that would end the
    cell escaped, and nothing else changed."""
    return _MD_CELL_BOUNDARY.sub(r"\\|", cell)


def _md_row_cells(row: str) -> list[str]:
    """The stripped cells of one pipe-table row, kept as written (escapes
    included), so `render_md_table` reproduces them byte for byte."""
    return [c.strip() for c in _MD_CELL_BOUNDARY.split(row[1:-1])]

def parse_md_table(text: str) -> tuple[list[str], list[list[str]]] | None:
    """Extract the first Markdown pipe table from a clause body.

    Returns (columns, rows) with every cell stripped, or None when the body holds
    no table. A table is a header row, a `|---|` separator, then body rows; a row
    whose cell count differs from the header is a malformed table and returns None
    rather than a silently truncated one. Cells split on unescaped pipes only, and
    keep their `\\|` escapes, so `render_md_table` writes the table back as it
    was.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        s = line.strip()
        if not (s.startswith("|") and s.endswith("|")):
            continue
        if i + 1 >= len(lines):
            break
        sep = lines[i + 1].strip()
        if not (sep.startswith("|") and set(sep) <= set("|-: ")):
            continue
        cols = _md_row_cells(s)
        rows: list[list[str]] = []
        for body in lines[i + 2:]:
            b = body.strip()
            if not (b.startswith("|") and b.endswith("|")):
                break
            cells = _md_row_cells(b)
            if len(cells) != len(cols):
                return None
            rows.append(cells)
        return (cols, rows) if rows else None
    return None

def render_md_table(columns: list[str], rows: list[list[str]]) -> str:
    """Render (columns, rows) back to a Markdown pipe table, column-aligned.

    Padded to the widest cell per column, which is how the corpus's tables are
    written; an unpadded render would be valid Markdown but would not reproduce
    the committed text, and [STYL.5.3.2.1]'s "one source" needs the generated form
    to BE the committed form. Each cell goes through `_md_cell`, so a bare pipe in
    a `data` cell stays inside its cell.
    """
    columns = [_md_cell(c) for c in columns]
    rows = [[_md_cell(c) for c in r] for r in rows]
    widths = [
        max(len(columns[i]), *(len(r[i]) for r in rows)) if rows else len(columns[i])
        for i in range(len(columns))
    ]
    head = "| " + " | ".join(c.ljust(widths[i]) for i, c in enumerate(columns)) + " |"
    sep = "|" + "|".join("-" * (w + 2) for w in widths) + "|"
    body = [
        "| " + " | ".join(c.ljust(widths[i]) for i, c in enumerate(r)) + " |"
        for r in rows
    ]
    return "\n".join([head, sep, *body])


def main():
    sys.stdout.write(render_doc(sys.argv[1]))


if __name__ == "__main__":
    main()

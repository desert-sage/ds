# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A fragment the compiler refuses renders as refused, with its code.

A reference page shows a refused program as a fence that names its code,
```` ```ds rule error=DS_VALIDATE_UNKNOWN_SLOT ````, and the docs-examples gate
holds every such fragment to being refused with exactly that code. The render
used to drop it: MyST keeps a fence's first word as the language and nothing
after it, so a refused fragment rendered exactly as an accepted one did.

This extension marks each one when the page is read. The block gains the class
``ds-refused``, drawn with a red rule down its left edge, and a line above it
reads "Refused with `DS_VALIDATE_UNKNOWN_SLOT`". An accepted fragment is left
as it is. A writer writes the fence as before and nothing more.

HOW A FENCE FINDS ITS BLOCK. The doctree no longer carries the info string, so
the page's own source is read for its fences. Each refusal fence is matched to
the rendered block with the same text, the one at the fence's line where the
text recurs. A refusal fence that matches no block is named in the render's
log with its page and line. It is never marked by guess, since marking the
wrong block would label accepted code as refused. A page whose source cannot be
read is named too, and the log's last word from this extension is how many
fragments it marked, so a render that marked nothing says so.

The pure part (``fences``, ``code``) imports nothing, and ``mark`` imports
docutils when it runs, so the tests can load this module without a Sphinx
application.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

__all__ = ["BOOKS", "CLASS", "CSS", "LABEL_CLASS", "Fence", "code", "fences",
           "mark", "setup"]

__version__ = "1.0"

# The class a refused block carries, and the class of the line above it.
CLASS = "ds-refused"
LABEL_CLASS = "ds-refused-label"

# The books whose fragments are marked: ds_intersphinx's names for the four
# reference books. Only the author book's fragments carry `error=` today.
BOOKS = frozenset({"author", "integrator", "bindings", "internals"})

CSS = ("<style>"
       f"div.{CLASS}{{border-left:4px solid #c62828;}}"
       f"p.{LABEL_CLASS}{{margin:0 0 .25em;font-size:.875em;color:#c62828;}}"
       "</style>")

_OPEN = re.compile(r"^(?P<indent>[ \t]*)(?P<mark>`{3,}|~{3,})(?P<info>[^`]*)$")
_CODE = re.compile(r"^error=(?P<code>[A-Z][A-Z0-9_]*)$")


@dataclass(frozen=True)
class Fence:
    """A fenced block in a page's source: its opening line, counted from 1,
    its info string, and its lines, each stripped."""

    line: int
    info: str
    body: tuple[str, ...]


def fences(text: str) -> list[Fence]:
    """Every fenced block in ``text``, in order.

    A fence closes on a line of its own character, at least as long as the one
    that opened it, as CommonMark has it. A fence left open runs to the end. A
    directive's fence (```` ```{note} ````) holds markdown, so the fences inside
    it are its page's too."""
    return _fences(text.splitlines(), 0)


def _fences(lines: list[str], offset: int) -> list[Fence]:
    out: list[Fence] = []
    i = 0
    while i < len(lines):
        m = _OPEN.match(lines[i])
        if m is None:
            i += 1
            continue
        mark_ = m.group("mark")
        close = re.compile(rf"^[ \t]*{re.escape(mark_[0])}{{{len(mark_)},}}[ \t]*$")
        j = i + 1
        while j < len(lines) and not close.match(lines[j]):
            j += 1
        info = m.group("info").strip()
        if info.startswith("{"):
            out.extend(_fences(lines[i + 1:j], offset + i + 1))
        else:
            out.append(Fence(offset + i + 1, info, _strip(lines[i + 1:j])))
        i = j + 1
    return out


def code(fence: Fence) -> str | None:
    """The code a `ds` fence says its fragment is refused with, or None."""
    words = fence.info.split()
    if not words or words[0] != "ds":
        return None
    for word in words[1:]:
        m = _CODE.match(word)
        if m is not None:
            return m.group("code")
    return None


def _strip(lines) -> tuple[str, ...]:
    """Lines stripped, with blank lines at either end dropped."""
    body = [line.strip() for line in lines]
    while body and not body[0]:
        body.pop(0)
    while body and not body[-1]:
        body.pop()
    return tuple(body)


def mark(doctree, text: str) -> list[Fence]:
    """Mark the block of every refusal fence in ``text``, the doctree's source.

    Returns the refusal fences that no block matched, each left unmarked."""
    from docutils import nodes

    walk = getattr(doctree, "findall", None) or doctree.traverse
    blocks = [(b, _strip(b.astext().splitlines()))
              for b in walk(nodes.literal_block)]
    claimed: set[int] = set()
    missed: list[Fence] = []
    for fence in fences(text):
        refused = code(fence)
        if refused is None:
            continue
        same = [b for b, body in blocks
                if body == fence.body and id(b) not in claimed]
        at = [b for b in same if b.line in (fence.line, fence.line + 1)]
        block = at[0] if at else same[0] if len(same) == 1 else None
        if block is None:
            missed.append(fence)
            continue
        claimed.add(id(block))
        block["classes"].append(CLASS)
        label = nodes.paragraph("", "", nodes.Text("Refused with "),
                                nodes.literal(refused, refused),
                                classes=[LABEL_CLASS])
        block.parent.insert(block.parent.index(block), label)
    return missed


def _book(app) -> str | None:
    """This book's name in ds_intersphinx's catalogue, or None.

    Imported when called: both are local extensions loaded by path, and a book
    that loads this one without ds_intersphinx marks nothing rather than
    failing its render."""
    try:
        from ds_intersphinx import book_name
    except ImportError:
        return None
    return book_name(app.srcdir)


def setup(app):
    from sphinx.util import logging

    logger = logging.getLogger(__name__)
    marked = {"n": 0}

    def _read(app_, doctree):
        if _book(app_) not in BOOKS:
            return
        docname = app_.env.docname
        try:
            text = Path(app_.env.doc2path(docname)).read_text(encoding="utf-8")
        except OSError as err:
            logger.warning(f"ds_refused: the page's source cannot be read ({err}), "
                           f"so no fragment on it is marked", location=docname)
            return
        refusals = sum(1 for fence in fences(text) if code(fence) is not None)
        missed = mark(doctree, text)
        marked["n"] += refusals - len(missed)
        for fence in missed:
            logger.warning(f"ds_refused: the refusal fence at line {fence.line} "
                           f"({fence.info}) matches no rendered block, and is "
                           f"not marked", location=docname)

    def _finished(app_, exception):
        # The count is what shows the marking ran: a render that read no
        # source, or found no fence, warns of nothing and says 0 here.
        if exception is None and _book(app_) in BOOKS:
            logger.info(f"ds_refused: {marked['n']} refused fragments marked")

    def _page(app_, pagename, templatename, context, doctree):
        if _book(app_) in BOOKS:
            context["metatags"] = context.get("metatags", "") + CSS

    app.connect("doctree-read", _read)
    app.connect("html-page-context", _page)
    app.connect("build-finished", _finished)
    # The count is kept as each page is read, so a parallel read would report
    # only part of it.
    return {"version": __version__,
            "parallel_read_safe": False,
            "parallel_write_safe": True}

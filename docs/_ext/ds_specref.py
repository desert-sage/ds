# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A clause ID cited in a reference book links to its clause, as written.

A reference page cites a clause by its ID in brackets: ``*(Spec: [LEXP.7.13.1])*``
at the end of an entry, or ``[RDSC.11.1]`` in a sentence. When the page renders,
this extension makes each such ID a link to the clause in the specs book. The
brackets stay as text and the ID inside them is the link, so the page reads as
it was written. A writer writes the ID and nothing more.

HOW AN ID RESOLVES. ``scripts/spec/spec_book.py`` puts a target before every
clause it renders, ``(LEXP-7-13-1)=``, and the specs book's inventory lists each
as a ``std:label``, lower-cased. That is the entry a hand-written
``[LEXP.7.13.1](inv:specs:std:label#lexp-7-13-1)`` resolves against, so both
reach the same place. The inventory is the one ``ds_intersphinx`` maps, read
here after intersphinx has loaded it, and the href is the one intersphinx
would write: root-absolute, which the site packer rewrites as it rewrites every
other cross-book link.

WHAT IT LEAVES ALONE. Code, inline or fenced; text already inside a link or a
cross-reference; headings; and an ID no clause label answers. That last one
stays the text it was, since a link to nothing is worse than none. Such a
citation names a clause the specs book does not render as a clause, or no
clause at all, which is a defect of the page, so the render's log names each
one with its page.

THE LINKS ARE MARKED. Each carries the class ``ds-specref``. The docs link
gate's conservation check holds the cross-book links a render emits equal to
the ``](inv:`` links its sources write, and these have no ``inv:`` in their
source. The gate counts them apart, so they can neither fail that check nor
make up for a link the render deleted.

PASS 1 LINKS NOTHING. ``ds_intersphinx`` installs no mapping there, so no
inventory is loaded and every citation stays text, in a render nothing ships.

The pure part (``CITATION``, ``label``, ``split``) imports nothing, and ``link``
imports docutils when it runs, so the tests can load this module without a
Sphinx application.
"""
from __future__ import annotations

import os
import re

__all__ = ["BOOKS", "CITATION", "CLASS", "label", "link", "setup", "split"]

__version__ = "1.0"

# A clause ID in brackets: a capital prefix, then dot-separated segments, each
# digits with an optional lower-case tail ([LEXP.7.13.1], [RDSC.4a.9.5],
# [NDBG.14r.6.5]).
CITATION = re.compile(r"\[([A-Z]{3,6}(?:\.[0-9]+[a-z]*)+)\]")

# The class every link made here carries, which the docs link gate reads.
CLASS = "ds-specref"

# The books whose citations are linked: ds_intersphinx's names for the four
# reference books. The specs book is not one: its pages are generated, and its
# own links reach its clauses.
BOOKS = frozenset({"author", "integrator", "bindings", "internals"})


def label(cid: str) -> str:
    """The specs book's inventory name for a clause ID: LEXP.7.13.1 -> lexp-7-13-1.

    ``spec_book.slug`` writes the target as ``LEXP-7-13-1``, and Sphinx lower-cases
    a label's name when it records it."""
    return cid.replace(".", "-").lower()


def split(text: str) -> list[tuple[str, str]]:
    """``text`` as ``("text", s)`` and ``("cite", id)`` runs, in order.

    The brackets fall in the text runs either side of a citation, so only the
    ID is linked. No run is empty."""
    runs: list[tuple[str, str]] = []
    at = 0
    for m in CITATION.finditer(text):
        runs.append(("text", text[at:m.start(1)]))
        runs.append(("cite", m.group(1)))
        at = m.end(1)
    runs.append(("text", text[at:]))
    return [(kind, s) for kind, s in runs if s]


def _left_alone(node) -> bool:
    """Whether a text node sits where a citation is not linked."""
    from docutils import nodes

    fixed = (nodes.FixedTextElement,   # fenced code, raw, comments, math blocks
             nodes.literal, nodes.math,
             nodes.reference, nodes.target,
             nodes.title, nodes.subtitle)
    parent = node.parent
    while parent is not None:
        if isinstance(parent, fixed):
            return True
        if parent.tagname == "pending_xref":
            return True
        # An unresolved MyST link renders as an inline of class `xref`.
        if isinstance(parent, nodes.inline) and "xref" in parent.get("classes", ()):
            return True
        parent = parent.parent
    return False


def link(doctree, uris: dict[str, str]) -> list[str]:
    """Link every citation in ``doctree`` whose label ``uris`` maps to an href.

    Returns the IDs cited that no label answered, in page order. Each stays the
    text it was."""
    from docutils import nodes

    missed: list[str] = []
    walk = getattr(doctree, "findall", None) or doctree.traverse
    for text in list(walk(nodes.Text)):
        s = str(text)
        if "[" not in s or text.parent is None or _left_alone(text):
            continue
        runs = split(s)
        if not any(kind == "cite" for kind, _ in runs):
            continue
        new = []
        for kind, run in runs:
            uri = uris.get(label(run)) if kind == "cite" else None
            if uri is None:
                if kind == "cite":
                    missed.append(run)
                new.append(nodes.Text(run))
            else:
                new.append(nodes.reference(run, run, refuri=uri, internal=False,
                                           classes=[CLASS]))
        text.parent.replace(text, new)
    return missed


def _uri(item) -> str:
    """An inventory entry's href: a (project, version, uri, name) tuple, or an
    object with a ``uri``."""
    uri = getattr(item, "uri", None)
    return uri if isinstance(uri, str) else item[2]


def _clause_uris(app) -> dict[str, str]:
    """Label name -> href, for every std:label in the specs book's inventory."""
    named = getattr(app.builder.env, "intersphinx_named_inventory", None) or {}
    labels = named.get("specs", {}).get("std:label", {})
    return {name: _uri(item) for name, item in labels.items()}


def _book(app) -> str | None:
    """This book's name in ds_intersphinx's catalogue, or None.

    Imported when called: both are local extensions loaded by path, and a book
    that loads this one without ds_intersphinx links nothing rather than failing
    its render."""
    try:
        from ds_intersphinx import book_name
    except ImportError:
        return None
    return book_name(app.srcdir)


def setup(app):
    from sphinx.util import logging

    logger = logging.getLogger(__name__)
    state: dict = {"uris": None, "missed": []}

    def _resolved(app_, doctree, docname):
        if os.environ.get("DS_DOCS_PASS") == "1" or _book(app_) not in BOOKS:
            return
        if state["uris"] is None:
            state["uris"] = _clause_uris(app_)
            if not state["uris"]:
                logger.warning("ds_specref: the specs book's inventory has no "
                               "clause labels, so no clause citation is linked")
        if state["uris"]:
            state["missed"].extend((docname, cid)
                                   for cid in link(doctree, state["uris"]))

    def _finished(app_, exception):
        if exception is not None or not state["missed"]:
            return
        lines = "\n".join(f"  {doc}: [{cid}]" for doc, cid in state["missed"])
        logger.warning(f"ds_specref: {len(state['missed'])} clause citations name "
                       f"no clause label in the specs book, and stay text:\n{lines}")

    app.connect("doctree-resolved", _resolved)
    app.connect("build-finished", _finished)
    # The misses are gathered as each page is written, so a parallel write would
    # report only some of them.
    return {"version": __version__,
            "parallel_read_safe": True,
            "parallel_write_safe": False}

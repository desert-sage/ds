# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Cross-book intersphinx wiring for the DS documentation site (XBOOK1).

The five books are five separate Sphinx projects, so a relative markdown link that
leaves its own book has no target: MyST renders it as ``<span class="xref myst">``
— the text, unlinked — and neither warns loudly nor fails the build. Cross-book
references therefore go through intersphinx, written as::

    [Calls & Responses](inv:integrator:std:doc#guide/calls)

This extension is loaded by every book's ``_config.yml`` (``local_extensions``,
the same mechanism ``ds_lexer`` uses) and builds that book's
``intersphinx_mapping`` from the one catalogue below. The alternative — an
``intersphinx_mapping`` hand-written into each of five configs — is twenty
(uri, inventory) pairs maintained in five places, and this repo has already been
bitten by exactly that: two book catalogues in the release graph drifted,
shipping a tarball with five books while six were built.

Two things here are load-bearing and were measured, not assumed:

* **The served URI is root-absolute** (``/integrator``), never relative. Sphinx
  emits an intersphinx base URI *verbatim* into the href rather than making it
  document-relative, so a relative base is wrong at every page depth but one.
  Root-absolute is correct at all depths of a site served at ``/``. It is wrong
  for a site served under a prefix, so the site packer rewrites each
  ``href="/<book>/`` to a page-relative path when it packs the books
  (gitea #713). A render outside the pack — ``_build/html`` on its own — still
  carries the root-absolute form.

* **Inventories come from the pass-1 render** (``<book>/_inv/…``), because the
  cross-book graph is cyclic and no build order can satisfy it. The release
  graph renders every book once to produce inventories, then again to resolve
  against them. A pass-1 render sets ``DS_DOCS_PASS=1`` and gets no mapping at
  all. ``_build/`` is accepted as a fallback so a hand-run ``jupyter-book
  build`` still resolves what it can.

A missing inventory is only a warning (Sphinx continues, rc=0) and an
unresolvable ``inv:`` target *deletes its own link text*, so neither failure is
visible in a green build. That is what the docs link gate is for.
"""

from __future__ import annotations

import os
from pathlib import Path

__all__ = ["BOOKS", "TITLES", "setup"]

# name -> repo-relative source directory.
#
# THE cross-book catalogue. The release graph's docs section has two more (`table
# Book` and the `docs-pack` argv) for different reasons — a Book fact set and a
# path:label list. Adding or renaming a book means touching all three.
BOOKS = {
    "author": "docs/references/author",
    "integrator": "docs/references/integrator",
    "bindings": "docs/references/bindings",
    "internals": "docs/references/internals",
    "specs": "docs/specs",
}

# Written into each book's own objects.inv. Without this the inventory carries no
# project name and every inbound cross-book link renders
# `title="Project name not set"` as its hover text.
TITLES = {
    "author": "The DS Author's Reference",
    "integrator": "The DS Integrator's Reference",
    "bindings": "The DS Bindings Reference",
    "internals": "The DS Internals Reference",
    "specs": "The DS Specifications",
}

_UNSET_PROJECT = ("", "Python", "Project name not set")


def _locate(srcdir: Path):
    """Return (book_name, repo_root) for a book's Sphinx srcdir, or (None, None).

    Matched by path suffix rather than basename because `docs/specs` does not sit
    under `docs/references/` with the others.
    """
    posix = srcdir.resolve().as_posix()
    for name, rel in BOOKS.items():
        suffix = "/" + rel
        if posix.endswith(suffix):
            return name, Path(posix[: -len(suffix)])
    return None, None


def book_name(srcdir):
    """The book's URL segment for a Sphinx srcdir, or None.

    PUBLIC BECAUSE `ds_banner` NEEDS IT (gitea #355). The banner bakes a deep
    link into every page's href, and `pagename` is relative to *this book's*
    project root — the five books are five separate Sphinx projects, so it carries
    nothing identifying which one. The site's URL space is
    `/docs/<version>/<book>/<path>`, so the segment has to come from somewhere,
    and `BOOKS` above is already THE catalogue. A private copy in `ds_banner`
    would make four places to touch when a book is added, which is the drift the
    comment on `BOOKS` warns about.

    Returns `None` for a srcdir that is not one of the six; callers must treat
    that as "emit nothing" rather than guess a segment, because a *wrong* book
    segment is a link to somebody else's page.
    """
    name, _root = _locate(Path(srcdir))
    return name


def _inventory(root: Path, rel: str) -> str:
    """Prefer the pass-1 inventory; fall back to a plain `_build` render."""
    pass1 = root / rel / "_inv" / "_build" / "html" / "objects.inv"
    if pass1.is_file():
        return str(pass1)
    return str(root / rel / "_build" / "html" / "objects.inv")


def _mapping(name: str, root: Path) -> dict:
    return {
        other: (f"/{other}", _inventory(root, rel))
        for other, rel in BOOKS.items()
        if other != name
    }


def _on_config_inited(app, config):
    name, root = _locate(Path(app.srcdir))
    if name is None:  # not one of ours — leave the build untouched
        return

    if str(getattr(config, "project", "")) in _UNSET_PROJECT:
        config.project = TITLES.get(name, name)

    # Pass 1 exists only to emit this book's own objects.inv. Resolving anything
    # then is pointless (the other inventories do not exist yet) and would fill
    # the log with misses that pass 2 goes on to resolve.
    if os.environ.get("DS_DOCS_PASS") == "1":
        config.intersphinx_mapping = {}
        return

    config.intersphinx_mapping = _mapping(name, root)


def setup(app):
    """Register as a Sphinx/JupyterBook local extension."""
    app.setup_extension("sphinx.ext.intersphinx")
    # Ahead of intersphinx's own `normalize_intersphinx_mapping` (priority 800).
    app.connect("config-inited", _on_config_inited, priority=100)
    return {
        "version": "1.0",
        "parallel_read_safe": True,
        "parallel_write_safe": True,
    }

# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The books set their code in Fira Code, with ligatures off.

Every book loads this extension. It adds `static/` beside this file to the
book's static files, so each rendered book carries the font itself and loads
nothing from another host. It also links `ds_codefont.css`, which declares the
face, points the theme's monospace variable at it, and turns ligatures off
for `code`, `pre`, `kbd` and `samp`.

Ligatures off is the point. With them on, `->`, `=>` and `!=` render as single
glyphs, and a rule is written `->`, so a reader copying from a book has to see
the characters they type.

THE FONT IS WHOLE AND PINNED. `static/FiraCode-Regular.woff2` is Fira Code
6.2's Regular face as its release ships it, unmodified: Latin, Greek and
Cyrillic, with the superscripts and subscripts DS unit labels write
(`W·m⁻²·Hz⁻¹`). No subset of it ships, since every published subset drops
those. `FONTS` maps it to its digest, and a release test holds the file to it.

A DS identifier may be written in any script, and no font holds them all. A
character the face lacks falls back, one character at a time, to the next face
in the stack and then to the reader's own fonts, which every system carries
for the major scripts.

The font is under the SIL Open Font License 1.1, which asks that the copyright
notice and the licence travel with every copy. `static/OFL.txt` is the licence
from Fira Code's repository at the 6.2 tag. It goes into every book beside the
font, and `THIRD_PARTY_NOTICES.md` names both.
"""
from __future__ import annotations

from pathlib import Path

__all__ = ["CSS", "FONTS", "LICENCE", "STATIC", "setup"]

__version__ = "1.0"

STATIC = Path(__file__).resolve().parent / "static"
CSS = "ds_codefont.css"
FONTS = {
    "FiraCode-Regular.woff2":
        "a6ce59520b90e15d7062ffef214f94c8add5a4085c0bbb1683602ef227a4d1fe",
}
LICENCE = "OFL.txt"


def _add_static(app, config):
    """Put `static/` among the book's static paths, once."""
    paths = list(getattr(config, "html_static_path", None) or [])
    if str(STATIC) not in paths:
        paths.append(str(STATIC))
    config.html_static_path = paths


def setup(app):
    app.connect("config-inited", _add_static)
    app.add_css_file(CSS)
    return {"version": __version__,
            "parallel_read_safe": True,
            "parallel_write_safe": True}

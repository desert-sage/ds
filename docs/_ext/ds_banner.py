# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Version banner for the DS documentation books (gitea #142 item 2).

Every rendered page states which release it documents, and offers the same page
in whatever is current. Loaded by all five books' ``_config.yml`` through
``local_extensions`` — the mechanism ``ds_lexer`` and ``ds_intersphinx`` already
use, and for the same reason: the alternative is one hand-written banner in six
configs, which is the drift ``ds_intersphinx`` was written to end.

THE CONSTRAINT THAT SHAPES ALL OF THIS: a render cannot know what will be
current when someone reads it. The 1.0.0 books are rendered when 1.0.0 is cut
and have no way to learn that 1.1.0 followed. So the banner names ONLY the
page's own version — a baked "this is the latest" becomes a lie in HTML nobody
can go back and correct — and defers currency to a ``latest`` alias the site
resolves at request time.

THE DEEP LINK IS BAKED PER PAGE, AND THE SCRIPT IS THE FALLBACK. ``announcement``
is a single HTML string in ``html_theme_options``, injected verbatim with no
per-page templating — so the config-inited half can only ever name the ``latest``
root. ``html-page-context`` fires per page and carries ``pagename``, the path
relative to the BOOK ROOT, so the real href is written there. That is also the
no-JS answer: a reader with scripts disabled now lands on their own page rather
than on a book index.

THE SCRIPT MUST ANCHOR ON THE VERSION, NOT CONCATENATE (gitea #355). It used to
be ``_LATEST_ROOT + location.pathname``, which is correct only if the books are
served at the SERVER ROOT. They are not: the site mounts each release under a
versioned prefix, which is what makes a ``latest`` alias meaningful at all. So
``/docs/0.12.1/author/lang/facts.html`` produced
``/docs/latest/docs/0.12.1/author/lang/facts.html`` — a path that does not exist,
from a banner whose whole purpose is rescuing readers from stale docs.

It now finds ``/<version>/`` in the request path and keeps what follows. Anchoring
on the version rather than on ``/docs/`` means the mount point can move without
this breaking again; if the segment is absent the script leaves the baked href
alone, so an unexpected layout degrades to the correct book-relative link rather
than to a wrong one.

WHY THIS COULD NOT BE LEFT TO A LATER RELEASE. Published renders are immutable
and the site does not rewrite book HTML, so a wrong link in 1.0.0's books is
wrong permanently — the exact failure mode that made the banner a launch blocker
in #142.

The site handles the other half. A page that was renamed or split since this
render will 404 under ``latest``; #142 states the site falls back to the book
index for exactly that case. Upstream supplies the label and the link; the site
supplies the resolution.
"""
from pathlib import Path

__version__ = "1.0"

# The site's stable alias. Only the ALIAS is hardcoded — never a version, which
# is the whole point of the constraint above.
_LATEST_ROOT = "https://ds-lang.org/docs/latest"


def _repo_version() -> str:
    """The release this render documents, from the repo-root VERSION file.

    Walks up from this file rather than taking a configured value: VERSION is
    the one source of truth, and a second copy in six `_config.yml` files is
    the drift this extension exists to avoid.

    Returns "" when VERSION cannot be found or is empty. Callers treat that as
    "emit no banner" rather than guessing — a banner naming the wrong release
    is worse than no banner, because it is quotable.
    """
    for parent in Path(__file__).resolve().parents:
        candidate = parent / "VERSION"
        if candidate.is_file():
            try:
                return candidate.read_text(encoding="utf-8").strip()
            except OSError:
                return ""
    return ""


def _book_segment(app) -> str:
    """This book's URL segment, or "" when it cannot be resolved.

    Deferred to `ds_intersphinx.BOOKS`, which is already THE cross-book
    catalogue and says so — a private copy here would make four places to touch
    when a book is added, and the segment being wrong is the failure this exists
    to prevent.

    The import is inside the function because both are `local_extensions` loaded
    by path: at module-import time there is no guarantee the sibling is on
    `sys.path` yet, and a book that loads `ds_banner` without `ds_intersphinx`
    should degrade to the root link rather than fail the render.
    """
    try:
        from ds_intersphinx import book_name
    except ImportError:
        return ""
    return book_name(app.srcdir) or ""


def _banner_html(version: str, page_path: str = "") -> str:
    """The banner, optionally deep-linked to ``page_path`` within the book.

    ``page_path`` is the page's path relative to the BOOK ROOT
    (``author/lang/facts.html``), never the request path. Empty for the
    template-level default, which reaches the ``latest`` root.
    """
    href = f"{_LATEST_ROOT}/{page_path}" if page_path else f"{_LATEST_ROOT}/"
    # The version segment as it appears in the served path. Anchoring on the
    # VERSION rather than on a mount prefix is deliberate — see below.
    seg = f"/{version}/"
    return (
        f'<span>This is the documentation for DS {version}.</span> '
        f'<a id="ds-latest-link" href="{href}">'
        f'View this page in the current release</a>'
        f'<script>(function(){{'
        f'var a=document.getElementById("ds-latest-link");'
        f'if(!a){{return;}}'
        f'var p=window.location.pathname,s="{seg}",i=p.indexOf(s);'
        f'if(i>=0){{a.href="{_LATEST_ROOT}/"+p.slice(i+s.length);}}'
        f'}})();</script>'
    )


def setup(app):
    version = _repo_version()
    if not version:
        # Loud, and no banner. A silent skip here would ship a book with no
        # version statement and nothing saying why.
        app.warn = getattr(app, "warn", None)
        print("ds_banner: no VERSION file found — no version banner rendered")
        return {"version": __version__, "parallel_read_safe": True}

    # Books that set their own announcement opt out of both halves below.
    ours = {"claimed": False}

    def _apply(app_, config):
        opts = dict(getattr(config, "html_theme_options", None) or {})
        # Do not clobber a book that sets its own announcement deliberately.
        if not opts.get("announcement"):
            opts["announcement"] = _banner_html(version)
            config.html_theme_options = opts
            ours["claimed"] = True

    def _per_page(app_, pagename, templatename, context, doctree):
        """Bake THIS page's path into the href (gitea #355).

        The theme renders `announcement` from the template context, so
        overriding it here gives each page its own deep link — which is what
        the JS was doing at read time and what a no-JS reader never got.

        ⚠ `pagename` IS NOT ENOUGH, AND THAT WAS THE SECOND HALF OF #355.
        It is relative to *this book's* Sphinx project root, and the five books
        are five separate projects — so for `author/lang/facts.html` it is
        `lang/facts`, carrying nothing that says `author`. The site's URL space
        is `/docs/<version>/<book>/<path>`, so a href baked from `pagename`
        alone is short by exactly one segment.

        That is worse than a dead link, because the fallbacks COLLIDE: the
        `search.html` of the author, specs and integrator books all baked
        `/docs/latest/search.html`. Three pages, one URL — which no redirect on
        the site's side can repair, because the URL stops identifying the page.
        Same for `index.html` and `genindex.html` across all five books.

        The script half never had this bug, and the asymmetry is the whole
        explanation: `window.location.pathname` contains the book segment after
        the version, and `pagename` does not. Which is why the two disagreed
        despite both being written for #355.

        The segment comes from `ds_intersphinx.BOOKS`, the existing catalogue —
        see its `book_name`. With no segment resolvable, leave the
        config-inited banner alone: the `latest` ROOT is a poor link but a true
        one, whereas a guessed segment is a confident link to another book's
        page.

        STRICTLY ADDITIVE. If a theme ignores `theme_announcement`, the script
        below still corrects the href, so this cannot leave a page worse off
        than the script alone. Guarded on `ours` so a book with its own
        announcement is never rewritten.
        """
        if not ours["claimed"]:
            return
        if not context.get("theme_announcement"):
            return
        book = _book_segment(app_)
        if not book:
            return
        context["theme_announcement"] = _banner_html(
            version, f"{book}/{pagename}.html",
        )

    app.connect("config-inited", _apply)
    app.connect("html-page-context", _per_page)
    return {"version": __version__, "parallel_read_safe": True}

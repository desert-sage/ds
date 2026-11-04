#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Render one of the DS books with jupyter-book, and hand the render on as one file.

    render_book.py BOOK --archive OUT      the book's render, archived to OUT
    render_book.py BOOK --inv              pass 1: the inventory alone, in BOOK/_inv

ds_docs.build runs this for each book. A rendered book is a directory of
hundreds of files, and a step's declared outputs are what reaches the steps
that read it: build-unit moves a declared output between the trees its steps
run in, and nothing else. So the render's output is one archive of its whole
`_build/html`, and whatever reads the book reads the archive.

The archive holds `html/`, the render, and `PAGES`, the pages the book's
`_toc.yml` names, one path per line relative to `html/`. Every book sets
`only_build_toc_files`, so those are the pages the render emits. The render is
refused, and no archive is written, if any page `PAGES` names is missing from
it. A reader of the archive holds it to `PAGES` the same way, so a book that
lost pages anywhere between the render and the reader is refused by name.

The archive depends only on its contents: members sorted, each member's time
`SOURCE_DATE_EPOCH` (0 when unset), owner 0, and no time or name in the gzip
header.

`DS_DOCS_UNPACK` names archives, separated by spaces, to unpack into the
working directory before the render: pages another step generated, as one
declared file (the specs book's, from `scripts/spec/spec_book.py --archive`).

Run from the repository root. Pure stdlib, but for jupyter-book itself.
"""
from __future__ import annotations

import argparse
import gzip
import io
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path

# A `_toc.yml` page: the `root:` line, or a `file:` entry.
_TOC_ENTRY = re.compile(r"^\s*(?:-\s*)?(?:root|file):\s*(\S+)\s*$", re.M)


def toc_pages(book: Path) -> list[str]:
    """The pages `book`'s `_toc.yml` names, as paths under its `_build/html`.

    A book with no TOC, or a TOC naming no page, is refused: a check over no
    page passes everything."""
    toc = book / "_toc.yml"
    if not toc.is_file():
        sys.exit(f"render_book: {book} is no book: no {toc}")
    entries = _TOC_ENTRY.findall(toc.read_text(encoding="utf-8"))
    if not entries:
        sys.exit(f"render_book: {toc} names no page")
    return sorted({os.path.splitext(e)[0] + ".html" for e in entries})


def missing_pages(html: Path, pages: list[str]) -> list[str]:
    """The pages of `pages` that `html` does not hold."""
    return [p for p in pages if not (html / p).is_file()]


def _epoch() -> int:
    raw = os.environ.get("SOURCE_DATE_EPOCH", "").strip()
    try:
        return int(raw)
    except ValueError:
        return 0


def write_archive(out: Path, html: Path, pages: list[str]) -> None:
    """Write `html` as `html/` and `pages` as `PAGES` to the .tar.gz `out`."""
    epoch = _epoch()

    def normalise(ti: tarfile.TarInfo) -> tarfile.TarInfo:
        ti.mtime = epoch
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        return ti

    listing = ("\n".join(pages) + "\n").encode("utf-8")
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=epoch) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
                info = normalise(tarfile.TarInfo("PAGES"))
                info.size = len(listing)
                info.mode = 0o644
                tar.addfile(info, io.BytesIO(listing))
                tar.add(str(html), arcname="html", filter=normalise)


def unpack(archives: list[str]) -> None:
    """Unpack each archive into the working directory."""
    for archive in archives:
        if not os.path.isfile(archive):
            sys.exit(f"render_book: DS_DOCS_UNPACK names no file: {archive}")
        with tarfile.open(archive) as tar:
            tar.extractall(".", filter="data")
        print(f"render_book: unpacked {archive}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument("book", type=Path)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--archive", type=Path, metavar="OUT")
    mode.add_argument("--inv", action="store_true")
    args = ap.parse_args(argv)

    book: Path = args.book
    pages = toc_pages(book)
    unpack(os.environ.get("DS_DOCS_UNPACK", "").split())

    if args.inv:
        cmd = ["jupyter-book", "build", "--all", "--path-output", str(book / "_inv"), str(book)]
        env = {**os.environ, "DS_DOCS_PASS": "1"}
    else:
        cmd = ["jupyter-book", "build", "--all", str(book)]
        env = dict(os.environ)
    print("render_book: " + " ".join(cmd), flush=True)
    rc = subprocess.run(cmd, env=env).returncode
    if rc != 0:
        sys.exit(f"render_book: jupyter-book exited {rc}")
    if args.inv:
        return 0

    html = book / "_build" / "html"
    lost = missing_pages(html, pages)
    if lost:
        sys.exit(f"render_book: {book}'s render lacks {len(lost)} of the {len(pages)} "
                 f"pages its _toc.yml names: " + ", ".join(lost))
    write_archive(args.archive, html, pages)
    print(f"render_book: {book}: {len(pages)} pages, archived to {args.archive}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

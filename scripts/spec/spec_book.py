#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# spec_book.py -- (re)generate the normative spec Markdown pages from the JSON
# tree (STYL.5.6). The clause `.md` under docs/specs/<tree>/ are BUILD PRODUCTS
# regenerated from specs/**; only the JSON is committed. This runs FIRST in the
# `spec` gate and in the docs render, so every downstream consumer reads pages
# that are, by
# construction, in lock-step with the JSON — no committed .md, no drift.
#
# The book page is the byte-exact projection (spec_render.render_doc) ENRICHED with
# structured navigation the raw source cannot carry (STYL.5.6.3):
#   * a MyST cross-reference target before each clause (`(RPIR-8-1)=`), so every
#     clause is deep-linkable and can be the destination of a cross-link;
#   * a per-clause footer, present only on "connected" clauses, carrying
#       - `ratified` when a conformance test that counts links to it (STYL.5.3.11),
#       - coverage chips from the clause `checks` map (`alloy` `k×2`),
#       - a `see also:` list linking the clauses this one cites (`refs`),
#       - a `realizes:` list linking the higher-tree clauses it realizes.
# The enrichment is built ENTIRELY from structured fields (checks/refs/realizes/
# also_ids) — the verbatim prose in `text` is emitted untouched, so nothing here can
# corrupt a clause body, and render_doc stays byte-exact for the migration roundtrip.
#
# Writes docs/specs/<tree>/<doc>.md for every specs/<tree>/<doc>/ (using the
# manifest `src` path). The committed docs/specs/.gitignore ignores them by
# pattern, so a page for a document added later is never committed either; this
# script does not write it. The book config, TOC, and narrative pages
# (overviews / READMEs) stay committed and are untouched.
#
# AND ONE PAGE PER `.proto` (STYL.5.6.4).
# `proto/**` is part of `specs/`
# (STYL.2.14.1) and its message names and field layouts carry the same force as a
# clause of English (STYL.2.14.2), so a `.proto` that no page renders is a
# specification nobody can read. The page carries the anchors that make
# STYL.2.14.3's citation form — `proto/alfa.proto`, `proto/alfa.proto#AlphaNode` —
# resolve as a link the way a clause id does, which is what a clause's
# `checks.proto` tie is rendered into.
#
# Usage: spec_book.py                  (regenerate the pages)
#        spec_book.py --archive OUT    (and archive every page written to OUT)
#
# `--archive` is how the pages reach a render that runs in another tree:
# ds_docs.build's spec-book step declares OUT, the one file build-unit moves,
# and the specs book's render unpacks it (scripts/docs/render_book.py). OUT is
# a .tar.gz of the pages at their paths from the repository root, members
# sorted, each member's time SOURCE_DATE_EPOCH (0 when unset) and owner 0.
# Pure stdlib.

import glob
import gzip
import json
import os
import re
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spec_render import load_doc, render_doc  # noqa: E402  (render_doc: byte-exact projection)
# A registry table's body is its `data`, and its `text` is empty ([STYL.5.3.2.1]).
# The page renders it through the ONE renderer spec_db's gates also use, so the
# book cannot show a table the gates did not read.
from spec_render import render_clause_data  # noqa: E402
import spec_tree  # noqa: E402  (the clause tree; specs/conformance/ holds no clause)
import test_links  # noqa: E402  (test-to-clause links, read from the tests)

SPECS = os.path.join(ROOT, "specs")
STYLE = os.path.join(ROOT, "docs", "specs", "SPEC_STYLE.md")

# The kinds that have a ratification state ([STYL.5.3.11]).
RATIFIABLE = frozenset({"normative", "definition", "observation", "grammar", "table"})

# D4: the book marks what IS ratified and says nothing of what is not.
# Every clause that is not deferred binds this edition whether or not a test
# ratifies it yet, so an "unratified" marker on thousands of clauses would read as
# a qualification of the contract, which it is not. The marker says one thing a
# reader can rely on: a conformance test checks this clause on every product.
_RATIFIED_CHIP = "*ratified*"
BOOK = os.path.join(ROOT, "docs", "specs")
PROTO = os.path.join(ROOT, "proto")

# Deliberately unpublished: absent from _toc.yml ON PURPOSE, so the orphan warning
# below must not fire for them. AOT is frozen as implemented and not shipped in v1
# — the specs stay in the
# tree and stay gated, they are simply not in the reader's book.
#
# This list exists so the warning keeps MEANING something. Three permanent warnings
# that everyone learns to scroll past is worse than no warning at all, because the
# next unintended orphan arrives into noise. Removing an entry here republishes.
_UNPUBLISHED = frozenset({
    "runtime/CODE_AOT",   # RAOT
    "impl/CODE_AOT",      # IAOT
    "proto/aot",          # the CODE atom body
})

# footer coverage chips, formal-model guarantees first then property/conformance tests.
# `proto` is deliberately NOT here: a proto tie is not verification COVERAGE of the
# clause, it is where the clause's subject is normatively defined (STYL.2.14.2), and a
# `proto×2` chip alongside the `defined in:` links would say the same thing twice while
# implying the weaker of the two meanings.
# Conformance tests are in no `checks` block: their links are on the test side
#, so they have no chip here.
TOOL_ORDER = ["alloy", "tla", "k", "saw", "souffle", "idris"]


def slug(cid):
    """A MyST-target-safe anchor for a dotted clause id: RPIR.8.1 -> RPIR-8-1. Dotted
    ids are unreliable as Sphinx labels; dashes are always safe, and the map is
    injective (clause ids never contain dashes)."""
    return cid.replace(".", "-")


def proto_slug(cite):
    """A MyST-target-safe anchor for a [STYL.2.14.3] proto citation:
    `proto/alfa.proto` -> `proto-alfa-proto`, `proto/alfa.proto#AlphaNode` ->
    `proto-alfa-proto-AlphaNode`. `/`, `.` and `#` are the only three characters a
    citation carries that a Sphinx label cannot, and none of them can occur in a
    proto file stem or in a message name, so the map is injective."""
    return cite.replace("/", "-").replace(".", "-").replace("#", "-")


def proto_stem(rel):
    """The book doc stem for a proto path: `proto/alfa.proto` -> `proto/alfa`.

    NOT `proto/alfa.proto` (i.e. a page named `alfa.proto.md`). A docname carrying a
    dot is a standing source of trouble in Sphinx's suffix handling, and nothing needs
    it: links resolve through the ANCHOR, which keeps the full citation form, so the
    page's own path never has to spell it."""
    return "proto/" + os.path.basename(rel)[: -len(".proto")]


def split_proto(text):
    """Segment a `.proto` source into `(name, body)` chunks: one per top-level
    `message` / `enum`, in source order, with everything between them — syntax,
    package, imports, file-level comments — carried as unnamed chunks.

    Every NON-BLANK line of the source appears exactly once and in order, so the page
    is still the source *rendered, not paraphrased* as [STYL.5.6.4] requires. The
    segmentation exists only so each message can carry an anchor of its own, which one
    fenced block cannot do. What it does not preserve is the blank lines BETWEEN
    chunks: render_proto_page strips each body and drops one that is empty, so the
    separators become the gaps between fenced blocks. Nothing normative under
    [STYL.2.14.2] — names, numbers, types, `reserved` — lives in a blank line.

    Depth is a NET brace count per line, not a "does this line contain a brace" test:
    six comment lines under proto/ carry braces (`{x:.1f}`, `{"X-Tag":"production"}`,
    `{binding.slot}`) and every one of them is balanced, so a net count reads them
    correctly and a containment test would open a frame that never closes. A container
    that opens and closes on one line (`message Dsc { repeated Atom atoms = 1; }`,
    proto/atom.proto) is likewise a complete chunk, because depth is evaluated after
    the whole line.

    The contiguous run of `//` comment lines immediately above an opener is its doc
    comment and travels with it; a blank line breaks the run, which is the same rule a
    reader applies by eye."""
    open_re = re.compile(r"^(message|enum)\s+(\w+)\b")
    chunks, pending, cur, name, depth = [], [], [], None, 0
    for line in text.splitlines(keepends=True):
        if depth == 0 and name is None:
            mo = open_re.match(line)
            if mo:
                # the buffered comment run is this container's doc comment; anything
                # buffered before it is file-level and closes as its own chunk.
                lead = []
                while pending and pending[-1].lstrip().startswith("//"):
                    lead.insert(0, pending.pop())
                if pending:
                    chunks.append((None, "".join(pending)))
                pending = []
                name, cur = mo.group(2), lead + [line]
                depth = line.count("{") - line.count("}")
                if depth <= 0:
                    chunks.append((name, "".join(cur)))
                    name, cur, depth = None, [], 0
                continue
            pending.append(line)
            continue
        cur.append(line)
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            chunks.append((name, "".join(cur)))
            name, cur, depth = None, [], 0
    if cur:                                  # unterminated container — emit verbatim
        chunks.append((name, "".join(cur)))
    if pending:
        chunks.append((None, "".join(pending)))
    return chunks


def toc_docs():
    """The doc stems the specs book actually builds, from `_toc.yml` (e.g.
    'language/EXPRESSIONS'). A clause in a doc NOT listed here has no page and thus no
    resolvable anchor, so it must never be the destination of a cross-link. Parsed by
    line (jb-book `- file:` entries) — no PyYAML in the ds-spec image."""
    toc = os.path.join(BOOK, "_toc.yml")
    docs = set()
    if os.path.exists(toc):
        with open(toc, encoding="utf-8") as fh:
            for line in fh:
                s = line.strip().lstrip("-").strip()
                if s.startswith("file:"):
                    docs.add(s.split("file:", 1)[1].strip())
    return docs


def badge(checks):
    """Coverage chips from a clause `checks` map: `alloy` `k×2` `conformance×3`; '' if
    the clause carries no checks."""
    chips = []
    for tool in TOOL_ORDER:
        n = len(checks.get(tool, []))
        if n:
            chips.append(f"`{tool}×{n}`" if n > 1 else f"`{tool}`")
    return "*checks:* " + " ".join(chips) if chips else ""


def xref(ids, known, exclude):
    """A `, `-joined list of clause ids as links: ids in `known` become MyST
    cross-links to their anchor; others (e.g. a STYL.* house rule, no page) render as
    plain code so the citation is still legible."""
    out = []
    for cid in ids:
        if cid in exclude:
            continue
        out.append(f"[{cid}](#{slug(cid)})" if cid in known else f"`{cid}`")
    return ", ".join(out)


def proto_xref(ties, proto_known):
    """A `, `-joined list of [STYL.2.14.3] citations as links, from a clause's
    `checks.proto` entries. A tie with no `name` cites the file; one with a name cites
    the message. Ties whose target has no rendered anchor fall back to plain code, the
    same way xref() does for a clause with no page."""
    out, seen = [], set()
    for t in ties:
        cite = t["path"] + ("#" + t["name"] if t.get("name") else "")
        if cite in seen:
            continue
        seen.add(cite)
        out.append(f"[{cite}](#{proto_slug(cite)})" if cite in proto_known
                   else f"`{cite}`")
    return ", ".join(out)


def footer(c, known, proto_known, ratified=frozenset()):
    """The per-clause metadata line (ratified + checks + defined-in + see-also +
    realizes), or '' when the clause has none of them — so pure leaf prose stays
    clean and only connected clauses carry a footer."""
    own = {c["id"]} | set(c.get("also_ids", []))
    sections = []
    if c["id"] in ratified:
        sections.append(_RATIFIED_CHIP)
    b = badge(c.get("checks", {}))
    if b:
        sections.append(b)
    ties = c.get("checks", {}).get("proto", [])
    if ties:
        links = proto_xref(ties, proto_known)
        if links:
            sections.append("*defined in:* " + links)
    seen = set()
    refs = [r for r in c.get("refs", [])
            if r not in own and not (r in seen or seen.add(r))]
    if refs:
        links = xref(refs, known, own)
        if links:
            sections.append("*see also:* " + links)
    real = [r for r in c.get("realizes", []) if r not in own]
    if real:
        links = xref(real, known, own)
        if links:
            sections.append("*realizes:* " + links)
    return "  —  ".join(sections)


def render_proto_page(rel, text):
    """The book page for one `.proto` ([STYL.5.6.4]): an anchor for the file, then the
    source segmented per top-level message/enum, each under its own anchor.

    The page states its own normative standing, because a reader arriving from a
    clause link lands on what looks like generated API documentation and there is
    nothing else on the page to tell them the field numbers are as binding as the
    English they came from ([STYL.2.14.2])."""
    out = [
        f"({proto_slug(rel)})=\n\n",
        f"# `{rel}`\n\n",
        f"**Normative.** `proto/**` is part of `specs/` ([STYL.2.14.1]); message "
        f"names, field numbers, types and `reserved` ranges carry the same force as "
        f"a clause of English ([STYL.2.14.2]). Cite this file as `{rel}` and a "
        f"message within it as `{rel}#<Message>` ([STYL.2.14.3]). This page is the "
        f"protobuf source, rendered.\n\n",
    ]
    for name, body in split_proto(text):
        body = body.strip("\n")
        if not body:
            continue
        if name:
            out.append(f"({proto_slug(rel + '#' + name)})=\n\n")
            out.append(f"## `{name}`\n\n")
        out.append("```protobuf\n" + body + "\n```\n\n")
    return "".join(out)


def clause_body(c):
    """A clause's rendered body: `text` verbatim, or — for a registry table, whose
    `text` is empty because `data` is its source ([STYL.5.3.2.1]) — the clause id
    and the table rendered from `data`. Without this the seven registry tables
    rendered as nothing but an anchor."""
    data = c.get("data")
    if not data:
        return c["text"]
    lead = c["text"] if c["text"] else f"[{c['id']}]\n\n"
    if not lead.endswith("\n\n"):
        lead += "\n" if lead.endswith("\n") else "\n\n"
    return lead + render_clause_data(data) + "\n"


# D4: what the book says about a clause that does not bind this edition.
# The marker sits after the body, so it follows a section's heading rather than
# preceding it, and it is written once per run: a clause whose parent is also
# deferred inherits the parent's marker and gets none of its own.
_DEFERRED_MARKER = "*Deferred: not binding in this edition.*"

# A document whose every live clause is deferred binds nothing in this edition
# ([STYL.5.3.3]), and its page says so under its title. It stays in the book:
# clauses and preambles elsewhere link to it, and leaving it out would turn those
# links into dead references.
_BINDS_NOTHING_BANNER = (
    "**Not in this edition.** Every clause in this document is deferred or "
    "retired, so nothing here binds a 1.0 implementation. It is kept so that "
    "its ids and the references to them resolve.\n\n"
)


def with_banner(preamble):
    """`preamble` with the binds-nothing banner after its first `# ` title line,
    or at its end when it has none."""
    lines = preamble.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.startswith("# "):
            return "".join(lines[:i + 1]) + "\n" + _BINDS_NOTHING_BANNER + "".join(lines[i + 1:])
    return preamble + ("\n" if preamble and not preamble.endswith("\n") else "") + _BINDS_NOTHING_BANNER


def binds(c):
    """True if the clause is live and binds this edition."""
    return c.get("kind") != "tombstone" and not c.get("deferred")


def status_marker(c, by_id):
    """The deferred marker for `c`, or '' when it is not deferred or its parent
    carries the marker."""
    if not c.get("deferred"):
        return ""
    parent = by_id.get(c.get("parent") or "")
    if parent is not None and parent.get("deferred"):
        return ""
    return _DEFERRED_MARKER


def ratified_ids(clauses_by_doc):
    """The ids of the clauses that are ratified ([STYL.5.3.11]): a ratifiable kind,
    not deferred, and linked from at least one conformance test that counts. The
    same reading spec_db's `test_tag` and `reports/ratification.sql` make."""
    clauses = [c for _manifest, cs in clauses_by_doc for c in cs]
    ids = {c["id"] for c in clauses}
    if os.path.exists(STYLE):
        with open(STYLE, encoding="utf-8") as fh:
            ids |= set(test_links.ID_RE.findall(fh.read()))
    links, unreadable = test_links.links(ids, ROOT)
    if unreadable:
        sys.exit("spec-book: vectors that are not valid JSON: " + ", ".join(unreadable))
    pinned = test_links.pinned_scenarios(ROOT)
    observable = test_links.compile_observable(clauses)
    counting = {lk.clause_id for lk in links
                if test_links.why_not(lk, pinned, ROOT,
                                      observable=observable) is None}
    return frozenset(c["id"] for c in clauses
                     if c.get("kind") in RATIFIABLE and not c.get("deferred")
                     and c["id"] in counting)


def render_book_page(manifest, clauses, known, proto_known, ratified=frozenset()):
    """The enriched book page for one specs/<tree>/<DOC>/ directory: the manifest
    preamble, then each clause as `(anchor)=` target + body + optional status
    marker + optional footer, in `seq` order (tombstone stubs skipped,
    STYL.2.8.4). The body is `text` verbatim, or a registry table's `data`
    rendered (clause_body)."""
    by_id = {c["id"]: c for c in clauses}
    preamble = manifest.get("preamble", "")
    if not any(binds(c) for c in clauses):
        preamble = with_banner(preamble)
    out = [preamble]
    for c in clauses:
        if c.get("kind") == "tombstone":
            continue
        anchors = "".join(f"({slug(i)})=\n"
                          for i in sorted({c["id"]} | set(c.get("also_ids", []))))
        out.append(anchors)
        body = clause_body(c)
        out.append(body)                # verbatim clause body, or its data rendered
        # Guarantee a blank line after the body. `text` is verbatim and 182 clause
        # texts do not end in a newline, so whatever comes next lands ON the body's
        # last line: the see-also footer for the 38 that carry one, and the NEXT
        # clause's `(anchor)=` for the rest. Where that last line ends in emphasis
        # the markdown then mis-parses and the reader sees the trailer inside the
        # italics — `…Reference**see also:` in one `<em>` ([LNLS.10], [LCAP.7]).
        # Separating here rather than in the footer branch fixes both: the anchor
        # case is latent today but is the same defect (SBGEN1).
        if not body.endswith("\n\n"):
            out.append("\n" if body.endswith("\n") else "\n\n")
        marker = status_marker(c, by_id)
        if marker:
            out.append(marker + "\n\n")
        line = footer(c, known, proto_known, ratified)
        if line:
            out.append(line + "\n\n")
    page = "".join(out)
    # A clause that closes its section with `---` before a heading that is now a
    # tombstone leaves the page ending on a transition, and docutils refuses it:
    # "Document may not end with a transition". A break with nothing after it
    # separates nothing, so the last one goes. A transition with a footer or a
    # marker after it is not at the end, and stays.
    rest = page.rstrip()
    if rest.endswith("\n---"):
        page = rest[: -len("---")].rstrip() + "\n"
    return page


def write_pages_archive(out, pages):
    """Write `pages`, absolute paths under ROOT, to the .tar.gz `out` at their
    paths from ROOT."""
    raw_epoch = os.environ.get("SOURCE_DATE_EPOCH", "").strip()
    epoch = int(raw_epoch) if raw_epoch.isdigit() else 0
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=epoch) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
                for page in sorted(pages):
                    info = tar.gettarinfo(page, arcname=os.path.relpath(page, ROOT))
                    info.mtime = epoch
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mode = 0o644
                    with open(page, "rb") as fh:
                        tar.addfile(info, fh)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    archive = None
    if argv:
        if len(argv) != 2 or argv[0] != "--archive":
            sys.exit("usage: spec_book.py [--archive OUT]")
        archive = argv[1]
    # Load every doc once. `known` is the set of ids that actually receive a resolvable
    # anchor: a non-tombstone clause (a tombstone carries no page block) in a doc that
    # the book actually builds (in `_toc.yml`). A cross-link to any other id — retired,
    # or in a doc orphaned from the toctree — must NOT be emitted (no target ⇒ dangling
    # reference that warns/breaks the jupyter-book build), so it is EXCLUDED here and
    # xref() renders it as plain code instead.
    included = toc_docs()
    docs, known, orphaned = [], set(), []
    for docdir in (str(d) for d in spec_tree.doc_dirs(SPECS)
                   if (d / spec_tree.MANIFEST).is_file()):
        manifest, clauses = load_doc(docdir)
        docs.append((manifest, clauses))
        docstem = os.path.relpath(os.path.join(ROOT, manifest["src"]), BOOK)[:-len(".md")]
        in_book = docstem in included
        if not in_book:
            orphaned.append(docstem)
        for c in clauses:
            if c.get("kind") != "tombstone" and in_book:
                known.add(c["id"])
                known.update(c.get("also_ids", []))
    # The proto half of the same rule ([STYL.5.6.4]). `proto_known` holds CITATIONS in
    # [STYL.2.14.3] form rather than slugs, because that is what a `checks.proto` tie
    # spells and what proto_xref() has to look up. A file outside `_toc.yml` still gets
    # a page — same as a clause doc — but contributes no citation, so a link to it is
    # never emitted.
    protos, proto_known = [], set()
    for path in sorted(glob.glob(os.path.join(PROTO, "*.proto"))):
        rel = os.path.relpath(path, ROOT)
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        protos.append((rel, src))
        if proto_stem(rel) not in included:
            orphaned.append(proto_stem(rel))
            continue
        proto_known.add(rel)
        proto_known.update(rel + "#" + n for n, _ in split_proto(src) if n)
    ratified = ratified_ids(docs)
    # No .gitignore is written: docs/specs/.gitignore is committed and ignores
    # every page here by pattern.
    written = []
    for manifest, clauses in docs:
        page = os.path.join(ROOT, manifest["src"])       # the original source path
        os.makedirs(os.path.dirname(page), exist_ok=True)
        with open(page, "w", encoding="utf-8") as fh:
            fh.write(render_book_page(manifest, clauses, known, proto_known, ratified))
        written.append(page)
    for rel, src in protos:
        page = os.path.join(BOOK, proto_stem(rel) + ".md")
        os.makedirs(os.path.dirname(page), exist_ok=True)
        with open(page, "w", encoding="utf-8") as fh:
            fh.write(render_proto_page(rel, src))
        written.append(page)
    if archive is not None:
        write_pages_archive(archive, written)
        print(f"spec-book: archived {len(written)} pages to {archive}")
    print(f"spec-book: regenerated {len(docs)} clause pages and {len(protos)} proto pages "
          f"under {os.path.relpath(BOOK, ROOT)}/ "
          f"({len(known)} clause anchors, {len(proto_known)} proto anchors, "
          f"{len(ratified)} clauses marked ratified)")
    orphaned = [o for o in orphaned if o not in _UNPUBLISHED]
    if orphaned:
        print(f"spec-book: WARNING — {len(orphaned)} generated doc(s) not listed in "
              f"_toc.yml, so their clauses are unpublished and not cross-linkable: "
              f"{', '.join(sorted(orphaned))}")


if __name__ == "__main__":
    main()

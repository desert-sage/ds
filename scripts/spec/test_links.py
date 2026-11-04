# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Which clauses each conformance test is linked to.

A conformance test checks something a clause states, and it says which clause:

  * by NAME. A vector whose file name leads with the clause id
    (`specs/conformance/runtime/LSTO.4.7.5_refused_cache_write_stops_the_rhs.json`),
    or a test function named `test_<clause slug>__<tag>`
    (`test_ntst_3_3__tick_on_the_sample_not_the_mutation`).
  * by a LINKING COMMENT. A comment line `@spec [ID]` in a test file, naming one
    or more clauses; or, in a vector, which is JSON and has no comments, its
    top-level `clauses` list.

A test with no link is a unit test. The relation is derived from the test files
on every load and never stored in a clause, so it cannot be out of date.

Stdlib only.
"""

from __future__ import annotations

import glob
import json
import os
import re
from typing import Any, Iterable, Mapping, NamedTuple

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# A dotted clause id in brackets. A segment may carry a lowercase tail
# (`RDSC.4a.5`, `LDET.3.3a.1`).
ID_RE = re.compile(r"\[([A-Z]{3,5}\.[0-9][0-9a-z.]*)\]")

# Vectors: every JSON file of the conformance corpus.
VECTOR_GLOB = "specs/conformance/**/*.json"
# A vector basename that leads with a dotted clause id. Which reading of a
# trailing letter is meant (`IARC.1.11a` the serial, `LDET.3.3a` the id) only
# the clause tree can say: `vector_clause` asks it.
VECTOR_NAME_RE = re.compile(r"^([A-Z]{3,5}(?:\.[0-9]+[a-z]?)+)")

# Where test files live. A path under `bindings/` counts only inside a
# binding's own `test` or `tests` directory.
TEST_ROOTS = (
    "specs/conformance",
    "runtime/tests",
    "runtime/mercury/test",
    "compiler/mercury/test",
    "tools/dsdb/test",
)
BINDING_TEST_GLOBS = ("bindings/*/test", "bindings/*/tests")

# The test languages, and how each writes a line comment for the marker.
COMMENT_OPEN: dict[str, tuple[str, str]] = {
    ".c": ("/*", " */"),
    ".h": ("/*", " */"),
    ".py": ("#", ""),
    ".m": ("%", ""),
    ".scn": ("#", ""),     # the Mercury runtime's differential scenarios
    ".mjs": ("//", ""),
    ".js": ("//", ""),
    ".ts": ("//", ""),
}

# A test function named for its clause: `test_idat_4_3__slots` -> IDAT.4.3.
TEST_FN_RE = re.compile(r"\btest_([a-z]{3,5}(?:_[0-9]+[a-z]?)+)__\w+")
# A linking comment: a line that is a comment and whose text starts with
# `@spec`, followed by one or more bracketed ids. Anchored at the comment
# opener so that `@spec` inside a string literal is not a link.
MARKER_RE = re.compile(r"^\s*(?://|/\*|\*|#|%)\s*@spec\b(.*)$")


class Link(NamedTuple):
    path: str              # repo-relative
    name: str | None       # the test function, where the link names one
    clause_id: str
    how: str               # vector_name | vector_list | test_name | comment


# --- Product classes and harnesses ---------------
#
# A conformance test counts toward ratifying a clause only when the harness that
# runs it is run by per-PR CI, runs it on EVERY product of its class with the
# results compared, and the clause is in a tree the class covers.

class ProductClass(NamedTuple):
    products: frozenset[str]
    trees: frozenset[str]          # clause-id prefix letters the class covers


CLASSES: dict[str, ProductClass] = {
    "compiler": ProductClass(frozenset({"dsc"}), frozenset("LR")),
    "runtime": ProductClass(frozenset({"libds", "mercury"}), frozenset("LR")),
    "capi": ProductClass(frozenset({"libds"}), frozenset("NI")),
    # The bindings by their published names: the import `pyds` (its
    # PyPI distribution is `ds-lang`), npm's `@ds-lang/ds`, and the Mercury
    # library `mercury_ds`. [STYL.5.3.11]'s class table names the same three.
    "binding": ProductClass(frozenset({"pyds", "@ds-lang/ds", "mercury_ds"}), frozenset("N")),
    # dsdb: `ds dap` and `ds lsp`, the one implementation of the debug adapter
    # and the language server ([NDBG]). It runs on
    # @ds-lang/ds, but what its suite tests is dsdb's own protocol surface, not
    # the binding, so it is a class of its own and not `binding`, whose three
    # products it could never cover.
    "tooling": ProductClass(frozenset({"dsdb"}), frozenset("N")),
}


class Harness(NamedTuple):
    prefix: str                    # repo-relative path prefix; the longest match wins
    name: str                      # the CI gate that runs it
    klass: str                     # a key of CLASSES
    runs_on: frozenset[str]        # the products it actually runs each test on
    per_pr: bool                   # whether per-PR CI runs it


def _h(prefix: str, name: str, klass: str, runs_on: set[str], per_pr: bool) -> Harness:
    return Harness(prefix, name, klass, frozenset(runs_on), per_pr)


# What each harness does today. A row changes when its harness does.
# Several rows may share a prefix
# when several gates run the same files; a link counts when any one of them
# meets every condition.
HARNESSES: tuple[Harness, ...] = (
    _h("specs/conformance/compiler/", "compiler", "compiler", {"dsc"}, True),
    # The behavioural categories run on libds in `conformance` and on the Mercury
    # runtime in `compiler`'s behaviour suite,
    # each against the vector's expectation. Both fail on any vector
    # that neither passes nor is deprecated, so a live vector passes on
    # both wherever CI is green.
    _h("specs/conformance/runtime/", "conformance + compiler", "runtime",
       {"libds", "mercury"}, True),
    _h("specs/conformance/logical/", "conformance + compiler", "runtime",
       {"libds", "mercury"}, True),
    _h("specs/conformance/temporal/", "conformance + compiler", "runtime",
       {"libds", "mercury"}, True),
    _h("specs/conformance/adapter/", "conformance + compiler", "runtime",
       {"libds", "mercury"}, True),
    _h("specs/conformance/cross-tier/", "conformance + compiler", "runtime",
       {"libds", "mercury"}, True),
    # `conformance` runs the harness's own test files per PR, and
    # test_harness_files_gated.py fails on one it does not name.
    # They drive libds alone.
    _h("specs/conformance/harness/", "conformance", "runtime", {"libds"}, True),
    _h("runtime/mercury/test/scenarios/", "conformance (lockstep differential)",
       "runtime", {"libds", "mercury"}, True),
    # The same scenarios, through the bindings, compared byte for byte
    # (`binding-diff`): pyds,
    # @ds-lang/ds and mercury_ds.
    _h("runtime/mercury/test/scenarios/", "binding-diff", "binding",
       {"pyds", "@ds-lang/ds", "mercury_ds"}, True),
    _h("runtime/mercury/test/", "mercury-runtime", "runtime", {"mercury"}, True),
    _h("runtime/tests/libds/impl/", "libds-unit", "capi", {"libds"}, True),
    _h("runtime/tests/libds/spec/", "libds-spec", "capi", {"libds"}, True),
    # Python scans over libds's source, run by `libds-unit` before its C suite.
    _h("runtime/tests/libds/source/", "libds-unit", "capi", {"libds"}, True),
    # [NDET.1.4]'s double-backend check: DS's subject between
    # TestFloat's generator and verifier, linked against libds.a and run by
    # `testfloat`, which its own paths select.
    _h("runtime/tests/testfloat/", "testfloat", "capi", {"libds"}, True),
    _h("runtime/tests/", "(none per PR)", "capi", {"libds"}, False),
    _h("compiler/mercury/test/", "compiler", "compiler", {"dsc"}, True),
    _h("bindings/python/", "pyds", "binding", {"pyds"}, True),
    _h("bindings/js/", "js", "binding", {"@ds-lang/ds"}, True),
    _h("bindings/mercury/", "mercury", "binding", {"mercury_ds"}, True),
    _h("bindings/", "post-1.0", "binding", set(), False),
    # dsdb's suite, `dap.test.mjs` and `lsp.test.mjs` among it, runs in the
    # js lane,
    # selected by `tools/dsdb/*`.
    _h("tools/dsdb/test/", "js", "tooling", {"dsdb"}, True),
)
# The hypothesis files inside specs/conformance/harness/ are run by their own
# gate, `hypothesis`; they drive libds through
# pyds.
HYPOTHESIS_RE = re.compile(r"^specs/conformance/harness/test_\w+_hypothesis\.py$")
HYPOTHESIS = _h("specs/conformance/harness/", "hypothesis", "runtime", {"libds"}, True)


def harnesses_of(path: str) -> list[Harness]:
    """Every harness that runs a test file: the rows with the longest prefix
    that matches it, in table order. Empty if no harness does."""
    if HYPOTHESIS_RE.match(path):
        return [HYPOTHESIS]
    best = max((len(h.prefix) for h in HARNESSES if path.startswith(h.prefix)), default=-1)
    return [h for h in HARNESSES if path.startswith(h.prefix) and len(h.prefix) == best]


def harness_of(path: str) -> Harness | None:
    """The first harness that runs a test file, or None if no harness does."""
    hs = harnesses_of(path)
    return hs[0] if hs else None


# A runtime-differential scenario a gate is told to treat as an expected
# difference carries an `# exempt: <gate> <kind> #<issue> <reason>` line.
SCENARIOS = "runtime/mercury/test/scenarios"
EXEMPT_RE = re.compile(r"^#\s*exempt:")


_MANIFESTS: dict[str, frozenset[str]] = {}


def manifest_scenarios(root: str = ROOT) -> frozenset[str]:
    """The scenarios `SCENARIOS/MANIFEST` pairs with a fixture: the second
    column of each line that is neither blank nor a comment, as
    binding_differential.py's `read_manifest` reads it. Both differentials run
    these pairs and nothing else, so a scenario outside them is run by neither."""
    full = os.path.join(root, SCENARIOS, "MANIFEST")
    if full not in _MANIFESTS:
        names: set[str] = set()
        try:
            with open(full, encoding="utf-8") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) >= 2 and not parts[0].startswith("#"):
                        names.add(parts[1])
        except OSError:
            pass
        _MANIFESTS[full] = frozenset(names)
    return _MANIFESTS[full]


def pinned_scenarios(root: str = ROOT) -> set[str]:
    """Scenario names some gate is pinned to treat as an expected difference."""
    pinned: set[str] = set()
    for full in glob.glob(os.path.join(root, SCENARIOS, "*.scn")):
        with open(full, encoding="utf-8") as fh:
            if any(EXEMPT_RE.match(line) for line in fh):
                pinned.add(os.path.splitext(os.path.basename(full))[0])
    return pinned


_VECTORS: dict[str, dict[str, Any] | None] = {}


def _vector(path: str, root: str) -> dict[str, Any] | None:
    """A vector's JSON object, read once; None if it is not one."""
    full = os.path.join(root, path)
    if full not in _VECTORS:
        try:
            with open(full, encoding="utf-8") as fh:
                obj = json.load(fh)
        except (OSError, ValueError):
            obj = None
        _VECTORS[full] = obj if isinstance(obj, dict) else None
    return _VECTORS[full]


def vector_deprecated(path: str, root: str = ROOT) -> bool:
    """Whether a vector carries `deprecated` ([RCTS.1.2.12]): kept, never run,
    so it checks nothing. Read from the vector itself."""
    obj = _vector(path, root)
    return obj is not None and "deprecated" in obj


def vector_expect(path: str, root: str = ROOT) -> str | None:
    """A vector's `expect.kind`, or None if it has none."""
    obj = _vector(path, root)
    expect = obj.get("expect") if obj is not None else None
    kind = expect.get("kind") if isinstance(expect, dict) else None
    return kind if isinstance(kind, str) else None


def vector_expect_code(path: str, root: str = ROOT) -> str | None:
    """A vector's `expect.code`, the diagnostic or status it pins, or None if
    it has none."""
    obj = _vector(path, root)
    expect = obj.get("expect") if obj is not None else None
    code = expect.get("code") if isinstance(expect, dict) else None
    return code if isinstance(code, str) else None


def compile_observable(clauses: Iterable[Mapping[str, Any]]) -> frozenset[str]:
    """The ids of the clauses a `compile_ok` vector can ratify ([STYL.5.3.11]
    condition 4): a `grammar` clause, or one marked `compiler_only`
    ([STYL.5.3.11.1]). Every caller of `why_not` passes it."""
    return frozenset(c["id"] for c in clauses
                     if c.get("kind") == "grammar" or c.get("compiler_only") is True)


def why_not(link: Link, pinned: set[str], root: str = ROOT, *,
            observable: frozenset[str]) -> str | None:
    """None when `link` counts toward ratifying its clause; else the reason it
    does not. Deferral and whether the clause's kind has a ratification state
    are the caller's. The one clause fact read here is `observable`
    (`compile_observable`): a `compile_ok` vector counts only for those
    clauses, whatever harness runs it. A file several harnesses run counts when
    any one of them meets every condition; otherwise the first harness's reason
    is given."""
    hs = harnesses_of(link.path)
    if not hs:
        return "no harness runs this file"
    unobservable = _compile_ok_refusal(link, root, observable)
    if unobservable:
        return unobservable
    reasons = [_why_not_by(h, link, pinned, root) for h in hs]
    return None if None in reasons else reasons[0]


def counting_products(link: Link, pinned: set[str], root: str = ROOT, *,
                      observable: frozenset[str]) -> frozenset[str]:
    """The products a link counts for ([ITST.10.1]): every product of the class
    of each harness through which it counts. Empty exactly when `why_not` gives
    a reason.

    A UNION OVER HARNESSES, not one class: a file several harnesses run may
    count through rows of different classes. A differential scenario counts for
    an L or R clause through the lockstep row, class `runtime`, and for an N
    clause through `binding-diff`, class `binding`, and the clause's tree
    decides which rows meet every condition."""
    hs = harnesses_of(link.path)
    if not hs or _compile_ok_refusal(link, root, observable):
        return frozenset()
    products: set[str] = set()
    for h in hs:
        if _why_not_by(h, link, pinned, root) is None:
            products |= CLASSES[h.klass].products
    return frozenset(products)


def _compile_ok_refusal(link: Link, root: str, observable: frozenset[str]) -> str | None:
    """The reason a `compile_ok` vector does not count for its clause, whatever
    harness runs it ([STYL.5.3.11] condition 4), or None."""
    if (link.path.startswith("specs/conformance/") and link.path.endswith(".json")
            and vector_expect(link.path, root) == "compile_ok"
            and link.clause_id not in observable):
        return ("a compile_ok vector observes only that the program compiles, and "
                f"{link.clause_id} is neither grammar nor compiler_only")
    return None


def _why_not_by(h: Harness, link: Link, pinned: set[str], root: str) -> str | None:
    """`why_not` for the one harness `h`. A live vector is not asked whether it
    passes: its harness's gate fails on one that does not."""
    klass = CLASSES[h.klass]
    if link.clause_id[:1] not in klass.trees:
        return f"a {h.klass} test does not cover a {link.clause_id[:1]} clause"
    if not h.per_pr:
        return f"{h.name} is not run per PR"
    missing = klass.products - h.runs_on
    if missing:
        return f"{h.name} does not run it on {', '.join(sorted(missing))}"
    if link.path.startswith("specs/conformance/") and link.path.endswith(".json"):
        if vector_deprecated(link.path, root):
            return "the vector is deprecated, so no harness runs it"
    if link.path.endswith(".scn"):
        scenario = os.path.splitext(os.path.basename(link.path))[0]
        if scenario in pinned:
            return "the scenario carries an `# exempt:` line"
        if (link.path.startswith(SCENARIOS + "/")
                and scenario not in manifest_scenarios(root)):
            return "the scenario is in no MANIFEST pair, so no differential runs it"
    return None


def vector_clause(basename: str, spec_ids: set[str]) -> str | None:
    """The clause a vector's file name names: the longest leading id that is a
    real clause. Drops one trailing letter or one trailing segment at a time,
    longest first, so the serial and the id readings of a letter are both
    tried. None when no prefix is a clause.

    A letter after a number is ambiguous in this corpus and only the clause
    tree can resolve it: `IARC.1.11a.json` is clause IARC.1.11 with
    vector serial `a`, while `LDET.3.3a_transcendental_*.json` is clause
    LDET.3.3a. Taking either reading always credits some vectors to the wrong
    clause."""
    m = VECTOR_NAME_RE.match(basename)
    if not m:
        return None
    cand = m.group(1)
    while "." in cand:
        if cand in spec_ids:
            return cand
        cand = cand[:-1] if cand[-1].isalpha() else cand.rpartition(".")[0]
    return None


def clause_from_slug(slug: str) -> str:
    """`idat_4_3` -> `IDAT.4.3`."""
    parts = slug.split("_")
    return parts[0].upper() + "." + ".".join(parts[1:])


def test_dirs(root: str = ROOT) -> list[str]:
    """Every directory that holds test files, repo-relative."""
    dirs = [d for d in TEST_ROOTS if os.path.isdir(os.path.join(root, d))]
    for pattern in BINDING_TEST_GLOBS:
        dirs += sorted(os.path.relpath(p, root)
                       for p in glob.glob(os.path.join(root, pattern))
                       if os.path.isdir(p))
    return dirs


def is_test_file(rel: str, root: str = ROOT) -> bool:
    """Whether a repo-relative path is a test file this module reads."""
    if os.path.splitext(rel)[1] not in COMMENT_OPEN:
        return False
    return any(rel == d or rel.startswith(d + "/") for d in test_dirs(root))


def marker_ids(line: str) -> list[str] | None:
    """The ids a linking-comment line names, or None if the line is not one."""
    m = MARKER_RE.match(line)
    if not m:
        return None
    return ID_RE.findall(m.group(1))


def _next_test_name(lines: list[str], start: int) -> str | None:
    """The test a linking comment sits above: the first `test...` identifier on
    the next line that is neither blank nor a comment. None if there is none,
    which leaves the link naming the file."""
    for line in lines[start:start + 8]:
        s = line.strip()
        if not s or MARKER_RE.match(line) or s.startswith(("//", "/*", "*", "#", "%")):
            continue
        m = re.search(r"\b(test\w*)\b", s)
        return m.group(1) if m else None
    return None


def vector_links(spec_ids: set[str], root: str = ROOT) -> tuple[list[Link], list[str]]:
    """Links from vectors: the file name, and the `clauses` list. Returns the
    links and the vectors that are not valid JSON."""
    links: list[Link] = []
    unreadable: list[str] = []
    for full in sorted(glob.glob(os.path.join(root, VECTOR_GLOB), recursive=True)):
        rel = os.path.relpath(full, root)
        cid = vector_clause(os.path.basename(full), spec_ids)
        if cid:
            links.append(Link(rel, None, cid, "vector_name"))
        try:
            with open(full, encoding="utf-8") as fh:
                obj = json.load(fh)
        except (OSError, ValueError):
            unreadable.append(rel)
            continue
        listed = obj.get("clauses") if isinstance(obj, dict) else None
        if isinstance(listed, list):
            for c in listed:
                if isinstance(c, str):
                    links.append(Link(rel, None, c, "vector_list"))
    return links, unreadable


class Witness(NamedTuple):
    path: str               # the vector, repo-relative
    entry: str              # the entry as written
    check_path: str | None  # None when the entry is not `<path>#<name>`
    check_name: str | None


# A `witnesses` entry ([STYL.5.3.6.4]): a `checks` path and element name,
# joined by one `#`.
WITNESS_RE = re.compile(r"^([^#\s]+)#([^#\s]+)$")


def vector_witnesses(root: str = ROOT) -> list[Witness]:
    """Every entry of every vector's top-level `witnesses` list.

    An entry that is not a `<path>#<name>` string is kept, with no parts, so the
    gate reports it: dropping it here would be a link that silently checks
    nothing. A `witnesses` value that is not a list is one such entry."""
    out: list[Witness] = []
    for full in sorted(glob.glob(os.path.join(root, VECTOR_GLOB), recursive=True)):
        rel = os.path.relpath(full, root)
        obj = _vector(rel, root)
        if obj is None or "witnesses" not in obj:
            continue
        listed = obj["witnesses"]
        if not isinstance(listed, list):
            text = listed if isinstance(listed, str) else json.dumps(listed)
            out.append(Witness(rel, text, None, None))
            continue
        for e in listed:
            m = WITNESS_RE.match(e) if isinstance(e, str) else None
            text = e if isinstance(e, str) else json.dumps(e)
            out.append(Witness(rel, text, m.group(1) if m else None,
                               m.group(2) if m else None))
    return out


def code_part(line: str, ext: str, in_block: bool) -> tuple[str, bool]:
    """The part of a line that is code rather than comment, and whether a block
    comment is still open after it.

    A test named in a comment is not a test: a removal note such as
    `/* test_ierr_2_3__x removed */` names a test that no longer exists, and a
    comment citing another suite's test names one this file does not run. Only
    the code part is searched for `TEST_FN_RE`. `@spec` markers are comments by
    design and are read before this runs.

    Comment syntax per language, by extension: `#` for Python and scenarios, `%`
    for Mercury, and `//` and `/* */` for C and JavaScript. A comment opener
    inside a string literal ends the code part early; that loses at most a
    call site after it, never adds a link."""
    if ext in (".py", ".scn"):
        return line.split("#", 1)[0], False
    if ext == ".m":
        return line.split("%", 1)[0], False
    out: list[str] = []
    i = 0
    while i < len(line):
        if in_block:
            j = line.find("*/", i)
            if j < 0:
                return "".join(out), True
            i = j + 2
            in_block = False
            continue
        j = line.find("/*", i)
        k = line.find("//", i)
        if k >= 0 and (j < 0 or k < j):
            out.append(line[i:k])
            return "".join(out), False
        if j < 0:
            out.append(line[i:])
            return "".join(out), False
        out.append(line[i:j])
        i = j + 2
        in_block = True
    return "".join(out), in_block


def code_links(root: str = ROOT) -> list[Link]:
    """Links from test files in code: test function names, and `@spec` lines."""
    links: list[Link] = []
    for d in test_dirs(root):
        for dirpath, _dirs, files in os.walk(os.path.join(root, d)):
            for fn in sorted(files):
                if os.path.splitext(fn)[1] not in COMMENT_OPEN:
                    continue
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, root)
                with open(full, encoding="utf-8", errors="replace") as fh:
                    lines = fh.read().splitlines()
                ext = os.path.splitext(fn)[1]
                in_block = False
                for i, line in enumerate(lines):
                    ids = marker_ids(line)
                    if ids is not None:
                        name = _next_test_name(lines, i + 1)
                        for cid in ids:
                            links.append(Link(rel, name, cid, "comment"))
                        _, in_block = code_part(line, ext, in_block)
                        continue
                    code, in_block = code_part(line, ext, in_block)
                    for m in TEST_FN_RE.finditer(code):
                        links.append(Link(rel, m.group(0),
                                          clause_from_slug(m.group(1)), "test_name"))
    return links


def links(spec_ids: set[str], root: str = ROOT) -> tuple[list[Link], list[str]]:
    """Every link, deduplicated, in a stable order; and the unreadable vectors.
    A link to an id that is not a clause is kept: the caller decides whether it
    is a dead link or a STYL id."""
    vec, unreadable = vector_links(spec_ids, root)
    seen: set[Link] = set()
    out: list[Link] = []
    for link in vec + code_links(root):
        if link not in seen:
            seen.add(link)
            out.append(link)
    return out, unreadable

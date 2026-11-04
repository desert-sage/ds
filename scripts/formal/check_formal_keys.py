#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""scripts/formal/check_formal_keys.py [buildfile] [--table FILE] — every formal
lane's stamp is keyed on what its verdict depends on.

The recipe behind formal.build's `keys.stamp`, whose table is `GRAPHS` below. A
graph that is not in this file keeps its own table and passes it with
`--table FILE`: a Python file whose `FORMAL_KEYS = {...}` assignment is the
table as a literal, read with `ast` and never imported (`_parse_table`). Each
graph has its own table, and a lane is checked against the graph that runs it.
A lane's stamp is reused when its
key is unchanged, and the key is the lane's `reads`. An input the `reads` leaves
out is an input whose edit reuses the earlier green: the proof stands, and it is
a proof of what the file used to say. Five such inputs were missing when this
was written — the idris modules, the C the saw and cbmc lanes prove, the Alloy
harness, and the architecture guard on six lanes of seven.

WHAT IS DERIVED, per lane, from the lane's own files and not from a list kept
here:

  * the RECIPE, `scripts/formal/check_<lane>.py` unless `RECIPE` names another,
    and every module it imports, transitively, from the graph's import homes
    (`py_homes`: `scripts/formal/` for formal.build; another graph's table names
    its own);
  * the C UNDER PROOF, for saw and cbmc: each shim or harness, the translation
    units a harness names in `@cbmc-src` (read with check_cbmc's own parser),
    and every header any of them includes, transitively, through the include
    path the recipe passes;
  * the CORPUS ON DISK: every file matching what the recipe globs.

Each must be a declared input of `<lane>.stamp`, read off the EXPANSION of the
graph: an explicit `Consumes`, or a pattern some rule joins to the step.

WHAT IS NOT DERIVED, and is a table below because nothing states it but the
recipe's own code: which patterns a recipe globs (`CORPUS`). A package with
relative imports is not followed; a lane that imports one names its files in
its `reads` by hand.

THIS CHECK'S OWN KEY IS HELD TO THE SAME RULE. Every file opened or listed here
is recorded, and each must be a declared input of the graph's own keys step.

PATTERNS ARE MATCHED A DIRECTORY LEVEL AT A TIME: `*` does not cross a `/`, and
`**` stands for any number of levels, none included. Under fnmatch
`formal/idris/*.idr` would swallow `formal/idris/Rete/Network.idr` and report a
coverage the graph does not have.

PROVEN ABLE TO FIRE FIRST ([STYL.5.10.5]). `_selftest` runs the reader and the
matcher on a graph written here, where a missing input is known to be missing.
"""
from __future__ import annotations

import ast
import fnmatch
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent              # scripts/formal
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
import check_cbmc  # noqa: E402 — the one parser of `@cbmc-src`

# Per graph: its own keys step, its aggregate (a stamp that folds the lanes and is
# not one), what each lane's recipe globs, any lane whose recipe is not
# `scripts/formal/check_<lane>.py`, and where a recipe's own imports live.
# `_findings` fails on a lane with no row and a row with no lane, so a lane moved
# between graphs must move between tables. A graph not listed here passes its
# table with `--table` (`TABLE_FIELDS`, `_parse_table`).
#
# CORPUS: patterns from the repo root. `cbmc-sweep` is the cbmc harnesses' second
# step (`check_cbmc.py --step sweep`): the same recipe over the same corpus, so
# the same key. A graph is keyed by its path from the repo root, which is how
# its own keys step names it (`check_formal_keys.py formal/formal.build`).
TABLE_FIELDS = ("own", "aggregate", "corpus", "recipe", "py_homes")

GRAPHS: dict[str, dict] = {
    "formal/formal.build": {
        "own": "keys.stamp",
        "aggregate": "formal-all.stamp",
        "corpus": {
            "alloy": ("formal/alloy/RunAlloy.java", "formal/alloy/*.als"),
            "tla": ("formal/tla/*.tla", "formal/tla/*.cfg"),
            "saw": ("formal/saw/*.saw", "formal/saw/*.c"),
            "cbmc": ("formal/cbmc/*.c",),
            "cbmc-sweep": ("formal/cbmc/*.c",),
            "k": ("formal/k/*.k", "formal/k/*.prog", "formal/k/*.expected"),
            "idris": ("formal/idris/**/*.idr", "formal/idris/*.ipkg",
                      "formal/idris/tests/*.lowered", "formal/idris/tests/*.expected"),
            # Not a lane but a step of this graph all the same: the two models it
            # reads, and the .cfg that says which graph the module's ELSE branch is.
            "instances": ("formal/tla/tms_cascade.tla", "formal/tla/tms_cascade.cfg",
                          "formal/idris/Rete/Refcount.idr"),
        },
        "recipe": {"cbmc-sweep": "scripts/formal/check_cbmc.py"},
        "py_homes": ("scripts/formal",),
    },
}

# The graph under check; `main` selects it (`_select`).
BUILDFILE = "formal/formal.build"
OWN_STEP = GRAPHS[BUILDFILE]["own"]
AGGREGATE = GRAPHS[BUILDFILE]["aggregate"]
CORPUS: dict[str, tuple[str, ...]] = GRAPHS[BUILDFILE]["corpus"]
RECIPE: dict[str, str] = GRAPHS[BUILDFILE]["recipe"]
# Where a recipe's own imports live; a home that holds no such module is passed
# over.
PY_HOMES: tuple[str, ...] = GRAPHS[BUILDFILE]["py_homes"]

# The lanes that prove C, and the include path their recipes pass to the
# compiler (check_saw.py and check_cbmc.py build the same two `-I`s).
C_LANES = ("saw", "cbmc", "cbmc-sweep")
INCLUDE_PATH = ("runtime/include", "runtime/src/libds")

_IMPORT = re.compile(r"^[ \t]*(?:import|from)[ \t]+([A-Za-z_][A-Za-z0-9_]*)", re.M)
_INCLUDE = re.compile(r'^[ \t]*#[ \t]*include[ \t]+"([^"]+)"', re.M)
_STEP_ID = re.compile(r'emit Step\s+logical\s+id:\s*"([^"]+)"')

_READ: set[str] = set()


def _rel(path: Path) -> str:
    return path.resolve().relative_to(REPO).as_posix()


# ---- a graph's table, from `--table` -----------------------------------------

def _parse_table(text: str, origin: str) -> dict:
    """The table in `text`: its `FORMAL_KEYS = {...}` assignment, a literal with
    exactly `TABLE_FIELDS`, each of its shape. Read with `ast`, so nothing in
    the file runs. ValueError names what is wrong."""
    try:
        body = ast.parse(text, filename=origin).body
    except SyntaxError as e:
        raise ValueError(f"{origin} does not parse: {e}") from e
    node = next((n for n in body if isinstance(n, ast.Assign)
                 and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name)
                 and n.targets[0].id == "FORMAL_KEYS"), None)
    if node is None:
        raise ValueError(f"{origin} has no `FORMAL_KEYS = {{...}}` assignment")
    try:
        table = ast.literal_eval(node.value)
    except ValueError as e:
        raise ValueError(f"{origin}: FORMAL_KEYS is not a literal: {e}") from e
    if not isinstance(table, dict) or set(table) != set(TABLE_FIELDS):
        raise ValueError(f"{origin}: FORMAL_KEYS must have exactly the fields "
                         f"{', '.join(TABLE_FIELDS)}")

    def strs(v: object) -> bool:
        return isinstance(v, (list, tuple)) and all(isinstance(s, str) for s in v)

    corpus, recipe = table["corpus"], table["recipe"]
    if not (isinstance(table["own"], str) and isinstance(table["aggregate"], str)
            and isinstance(corpus, dict)
            and all(isinstance(k, str) and strs(v) for k, v in corpus.items())
            and isinstance(recipe, dict)
            and all(isinstance(k, str) and isinstance(v, str)
                    for k, v in recipe.items())
            and strs(table["py_homes"])):
        raise ValueError(f"{origin}: FORMAL_KEYS has a field of the wrong shape "
                         f"(own and aggregate are strings, corpus maps a lane "
                         f"to patterns, recipe a lane to a path, py_homes is "
                         f"a list of directories)")
    table["corpus"] = {k: tuple(v) for k, v in corpus.items()}
    table["py_homes"] = tuple(table["py_homes"])
    return table


def _text(path: Path) -> str:
    _READ.add(_rel(path))
    return path.read_text(encoding="utf-8")


# ---- the graph ---------------------------------------------------------------

def declared(graph: str, step: str) -> tuple[set[str], list[str]]:
    """(explicit products, patterns) the expanded graph gives `step`. A pattern
    belongs to a step when a rule joins a match on it to a `Consumes` of that
    step — however the edge was written."""
    head = r'emit Consumes\s+logical step: "' + re.escape(step) + r'"\s+product: "'
    explicit = set(re.findall(head + r'([^"{]+)"', graph))
    patterns: list[str] = []
    for block in re.split(r"(?m)^(?=rule\s)", graph):
        m = re.search(head + r'\{(\w+)\.name\}"', block)
        if m:
            patterns += re.findall(
                r"\b" + re.escape(m.group(1)) + r'\.pattern == "([^"]+)"', block)
    return explicit, patterns


def matches(path: str, pattern: str) -> bool:
    """`path` against `pattern`, a directory level at a time."""
    def walk(p: list[str], g: list[str]) -> bool:
        if not g:
            return not p
        if g[0] == "**":
            return any(walk(p[i:], g[1:]) for i in range(len(p) + 1))
        return bool(p) and fnmatch.fnmatchcase(p[0], g[0]) and walk(p[1:], g[1:])
    return walk(path.split("/"), pattern.split("/"))


def uncovered(needed: set[str], explicit: set[str], patterns: list[str]) -> list[str]:
    return sorted(p for p in needed
                  if p not in explicit and not any(matches(p, g) for g in patterns))


# ---- what a lane depends on --------------------------------------------------

def _py_closure(recipe: Path) -> set[str]:
    seen: set[Path] = set()
    todo = [recipe]
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        for mod in _IMPORT.findall(_text(f)):
            todo += [REPO / home / f"{mod}.py" for home in PY_HOMES
                     if (REPO / home / f"{mod}.py").is_file()]
    return {_rel(f) for f in seen}


def _c_closure(roots: list[Path]) -> tuple[set[str], list[str]]:
    """(files reached, includes that resolved to nothing)."""
    seen: set[Path] = set()
    lost: list[str] = []
    todo = list(roots)
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        for inc in _INCLUDE.findall(_text(f)):
            homes = [f.parent, *(REPO / d for d in INCLUDE_PATH)]
            hit = next((h / inc for h in homes if (h / inc).is_file()), None)
            if hit is None:
                lost.append(f'{_rel(f)} includes "{inc}"')
            else:
                todo.append(hit)
    return {_rel(f) for f in seen}, lost


def _on_disk(patterns: tuple[str, ...]) -> set[str]:
    found: set[str] = set()
    for pattern in patterns:
        for f in REPO.glob(pattern):
            rel = f.relative_to(REPO).as_posix()
            # `build/` is where idris2 writes; it is ignored and holds no model.
            if f.is_file() and "build" not in rel.split("/")[:-1]:
                found.add(rel)
    _READ.update(found)
    return found


def needed(lane: str) -> tuple[set[str], list[str]]:
    """(every file `<lane>.stamp` must be keyed on, what could not be resolved)."""
    need = _py_closure(REPO / RECIPE.get(lane, f"scripts/formal/check_{lane}.py"))
    corpus = _on_disk(CORPUS[lane])
    problems = [] if corpus else [f"nothing on disk matches {CORPUS[lane]}"]
    need |= corpus
    if lane in C_LANES:
        roots = [REPO / p for p in sorted(corpus) if p.endswith(".c")]
        for harness in list(roots):
            roots += [REPO / s for s in check_cbmc._sources(harness)]
        missing = [r for r in roots if not r.is_file()]
        problems += [f"{_rel(r)} is named and does not exist" for r in missing]
        reached, lost = _c_closure([r for r in roots if r.is_file()])
        need |= reached
        problems += lost
    return need, problems


# ---- the check ---------------------------------------------------------------

def _findings(graph: str) -> list[str]:
    out: list[str] = []
    steps = set(_STEP_ID.findall(graph))
    lanes = {s[:-len(".stamp")] for s in steps
             if s.endswith(".stamp") and s not in (OWN_STEP, AGGREGATE)}
    for lane in sorted(lanes - set(CORPUS)):
        out.append(f"{lane}.stamp is a lane of {BUILDFILE} with no row in CORPUS — "
                   f"nothing here says what its recipe reads")
    for lane in sorted(set(CORPUS) - lanes):
        out.append(f"CORPUS has a row for `{lane}` and {BUILDFILE} has no "
                   f"{lane}.stamp step — the reader found no such step")

    for lane in sorted(set(CORPUS) & lanes):
        explicit, patterns = declared(graph, f"{lane}.stamp")
        if not explicit and not patterns:
            out.append(f"{lane}.stamp: no input could be read off the expansion — "
                       f"the graph's shape has moved and this reader has not")
            continue
        need, problems = needed(lane)
        out += [f"{lane}.stamp: {p}" for p in problems]
        gaps = uncovered(need, explicit, patterns)
        out += [f"{lane}.stamp is not keyed on {p}" for p in gaps]
        print(f"   {lane}.stamp: {len(need)} input(s) derived, {len(gaps)} "
              f"undeclared; the graph declares {len(explicit)} by name and "
              f"{len(patterns)} pattern(s)")

    explicit, patterns = declared(graph, OWN_STEP)
    own = uncovered(set(_READ), explicit, patterns)
    out += [f"{OWN_STEP} is not keyed on {p}, which this check read" for p in own]
    print(f"   {OWN_STEP}: {len(_READ)} file(s) read, {len(own)} undeclared; the "
          f"graph declares {len(explicit)} by name and {len(patterns)} pattern(s)")
    return out


_SELFTEST_GRAPH = '''emit Step      logical id: "x.stamp" tool: "python3" require: "amd64 linux"
emit Consumes  logical step: "x.stamp" product: "scripts/formal/check_x.py"
emit Consumes  logical step: "y.stamp" product: "scripts/formal/check_y.py"
rule x_corpus logical
  when GlobMatch m where m.pattern == "formal/x/*.c"
  emit Consumes logical step: "x.stamp" product: "{m.name}"
rule y_corpus logical
  when GlobMatch m where m.pattern == "formal/y/**/*.idr"
  emit Consumes logical step: "y.stamp" product: "{m.name}"
'''


def _selftest() -> list[str]:
    wrong: list[str] = []

    def expect(label: str, got: object, want: object) -> None:
        if got != want:
            wrong.append(f"{label}: wanted {want!r}, read {got!r}")

    expect("a step's explicit inputs and patterns are its own",
           declared(_SELFTEST_GRAPH, "x.stamp"),
           ({"scripts/formal/check_x.py"}, ["formal/x/*.c"]))
    expect("a step the graph does not have has none",
           declared(_SELFTEST_GRAPH, "z.stamp"), (set(), []))
    explicit, patterns = declared(_SELFTEST_GRAPH, "x.stamp")
    expect("an undeclared input is reported, a declared one is not",
           uncovered({"scripts/formal/check_x.py", "scripts/formal/formal_arch.py",
                      "formal/x/a.c", "formal/x/sub/a.c", "formal/y/a.c",
                      "runtime/src/libds/oa.h"},
                     explicit, patterns),
           ["scripts/formal/formal_arch.py", "formal/x/sub/a.c", "formal/y/a.c",
            "runtime/src/libds/oa.h"])
    explicit, patterns = declared(_SELFTEST_GRAPH, "y.stamp")
    expect("`**` is any number of levels, none included",
           uncovered({"formal/y/A.idr", "formal/y/a/B.idr", "formal/y/a/b/C.idr",
                      "formal/y/A.ipkg", "formal/A.idr"}, explicit, patterns),
           ["formal/A.idr", "formal/y/A.ipkg"])

    good = ('FORMAL_KEYS = {"own": "k.stamp", "aggregate": "", '
            '"corpus": {"x": ["formal/x/*.c"]}, "recipe": {}, '
            '"py_homes": ["scripts/formal"]}\n')
    try:
        t = _parse_table(good, "<good>")
        expect("a --table literal is read, its lists as tuples",
               (t["own"], t["corpus"], t["py_homes"]),
               ("k.stamp", {"x": ("formal/x/*.c",)}, ("scripts/formal",)))
    except ValueError as e:
        wrong.append(f"a well-formed --table was refused: {e}")
    for label, text in (
            ("a --table with no FORMAL_KEYS", "TABLE = {}\n"),
            ("a --table missing a field", 'FORMAL_KEYS = {"own": "k.stamp"}\n'),
            ("a --table that is not a literal", "FORMAL_KEYS = dict(own='k')\n"),
            ("a --table with a field of the wrong shape",
             good.replace('"py_homes": ["scripts/formal"]', '"py_homes": "formal"')),
            ("a --table that does not parse", "FORMAL_KEYS = {\n")):
        try:
            _parse_table(text, "<bad>")
            wrong.append(f"{label} was accepted")
        except ValueError:
            pass
    return wrong


def _select(buildfile: str, table: dict) -> None:
    global BUILDFILE, OWN_STEP, AGGREGATE, CORPUS, RECIPE, PY_HOMES
    BUILDFILE, OWN_STEP, AGGREGATE = buildfile, table["own"], table["aggregate"]
    CORPUS, RECIPE, PY_HOMES = table["corpus"], table["recipe"], table["py_homes"]


def main(argv: list[str]) -> int:
    args = argv[1:]
    table_file = None
    if "--table" in args:
        i = args.index("--table")
        if i + 1 >= len(args):
            print("== formal keys: --table needs a file ==", file=sys.stderr)
            return 2
        table_file = args[i + 1]
        del args[i:i + 2]
    buildfile = args[0] if args else "formal/formal.build"
    if table_file is None:
        if buildfile not in GRAPHS:
            print(f"== formal keys: no table for {buildfile} here (GRAPHS has "
                  f"{', '.join(GRAPHS)}); a graph outside this file passes its "
                  f"own with --table FILE ==", file=sys.stderr)
            return 2
        table = GRAPHS[buildfile]
    else:
        if buildfile in GRAPHS:
            print(f"== formal keys: {buildfile}'s table is in this file; "
                  f"--table would shadow it ==", file=sys.stderr)
            return 2
        try:
            table = _parse_table(_text(REPO / table_file), table_file)
        except (OSError, ValueError) as e:
            print(f"== formal keys: REFUSED — {e} ==", file=sys.stderr)
            return 2
    _select(buildfile, table)

    wrong = _selftest()
    if wrong:
        print("== formal keys: the reader failed its own fixtures, so its silence "
              "on the graph would mean nothing ==", file=sys.stderr)
        for w in wrong:
            print(f"   {w}", file=sys.stderr)
        return 2

    # build-unit's own expansion of the step sugar: pure Python, no compiler.
    try:
        from build_unit.expand import expand
    except ImportError as e:
        # REFUSED, not skipped: without the expansion there is no graph to read
        # a key off.
        print(f"== formal keys: REFUSED — cannot expand {BUILDFILE}: {e} ==\n"
              f"   build-unit expands the step sugar; run this through the graph "
              f"(`{OWN_STEP}`), whose harness is build-unit.", file=sys.stderr)
        return 2
    graph = expand((REPO / BUILDFILE).read_text(encoding="utf-8"),
                   label=BUILDFILE).text
    _READ.add(BUILDFILE)
    _py_closure(Path(__file__).resolve())       # this recipe, and what it imports

    print(f"== formal keys: {BUILDFILE}, lane by lane ==")
    findings = _findings(graph)
    if findings:
        print(f"== formal keys: {len(findings)} finding(s) — an input a key omits "
              f"cannot invalidate the stamp, so a warm store answers with the "
              f"green that was proved before the edit ==", file=sys.stderr)
        for f in findings:
            print(f"   FAIL: {f}", file=sys.stderr)
        return 1
    print("== formal keys: every derived input is a declared one ==")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

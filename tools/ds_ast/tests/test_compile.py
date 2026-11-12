# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`unparse`'s line map, and `compile`, which reports what `dsc` says
about unparsed text at the nodes that text was written for.

A program built as nodes has no source of its own, so `dsc` can only name
lines of `unparse`'s output. The map is what carries each back to a node,
and through the node's `lineno` to whatever source the generator built it
from. Two properties hold it: every located node is on the line its
`lineno` says, wherever `unparse` keeps the layout (the round trip's
programs, which it keeps line for line); and a refusal of relocated nodes
is reported at the relocated line, not the text's. A diagnostic in a
library the program imports is in no such text, and the map is not used
for it.
"""
import json
import os
import pathlib
import subprocess
import warnings

import pytest

import ds_ast
from ds_ast import (Cast, DSSyntaxError, DSSyntaxWarning, PatternClause,
                    walk)

from test_parse import PROGRAM, _corpus

# runtime/mercury/test/fixtures/06_rule_with_where.ds, with the `use default`
# the harness compiles it under ([LDIA.2.10.8]).
GOOD = (
    "use default\n\n"
    "schema Sensor scope logical:\n"
    "    entity_id: String key\n"
    "    state: Float mutable\n\n"
    "rule kitchen_high:\n"
    "    Sensor s where {where}\n"
    "->\n"
    "    log warning \"high\"\n")
WHERE_LINE = 8
WHERE = 's.state > 75 and s.entity_id == "kitchen"'
# A slot `Sensor` does not declare: refused at the `where`.
UNKNOWN_SLOT = 's.level > 75 and s.entity_id == "kitchen"'
# An identity cast: accepted, with a warning ([LCST.4.5.1]).
IDENTITY_CAST = 's.state::Float > 75 and s.entity_id == "kitchen"'


@pytest.fixture(scope="module")
def dsc():
    binary = os.environ.get("DS_AST_DSC")
    if not binary or not pathlib.Path(binary).is_file():
        pytest.fail("DS_AST_DSC must name the Mercury dsc binary; the ds-ast "
                    "gate builds it")
    return binary


def _located(tree):
    return [node for node in walk(tree)
            if getattr(node, "lineno", None) is not None]


def _missing(tree, lines):
    """Each located node that is not on the line its `lineno` names."""
    return [f"{type(node).__name__} at line {node.lineno}"
            for node in _located(tree)
            if not (0 < node.lineno <= len(lines))
            or not any(x is node for x in lines[node.lineno - 1])]


def _where(tree):
    """The rule's `where` expression."""
    clause = next(node for node in walk(tree)
                  if isinstance(node, PatternClause))
    return clause.pattern.body.where


# -- the line map -------------------------------------------------------------

def test_every_located_node_is_on_its_own_line(dsc):
    tree = ds_ast.parse(PROGRAM, "program.ds", dsc=dsc)
    text, lines = ds_ast.unparse(tree, line_map=True)
    assert text == PROGRAM, "the map is measured where the layout is kept"
    assert text == ds_ast.unparse(tree), "the map moves nothing"
    assert len(lines) == text.count("\n")
    assert all(entry[0] is tree for entry in lines), \
        "every line belongs to the module first"
    assert len(_located(tree)) > 20
    assert _missing(tree, lines) == []


def test_a_line_holds_its_statement_and_what_is_written_on_it(dsc):
    tree = ds_ast.parse(GOOD.format(where=WHERE), dsc=dsc)
    _, lines = ds_ast.unparse(tree, line_map=True)
    rule = tree.body[1]
    where = _where(tree)
    on_where_line = lines[WHERE_LINE - 1]
    assert any(x is rule for x in on_where_line)
    assert all(any(x is node for x in on_where_line) for node in walk(where))
    # Nothing of the `where` is on the rule's header line, `->`, or the log.
    for i in (WHERE_LINE - 1, WHERE_LINE + 1, WHERE_LINE + 2):
        assert not any(x is where for x in lines[i - 1])


def test_an_expression_is_one_line(dsc):
    where = _where(ds_ast.parse(GOOD.format(where=WHERE), dsc=dsc))
    text, lines = ds_ast.unparse(where, line_map=True)
    assert text == WHERE and len(lines) == 1
    assert {id(node) for node in walk(where)} <= {id(x) for x in lines[0]}


def test_the_map_holds_over_the_corpus(dsc):
    """Over every corpus program whose lines `unparse` keeps, up to
    whitespace inside a line: those are the programs a located node's line
    can be checked on. Counted, and the count must not be zero."""
    checked = moved = 0
    failures = []
    for name, source in _corpus():
        try:
            tree = ds_ast.parse(source, name, dsc=dsc)
            text, lines = ds_ast.unparse(tree, line_map=True)
        except (DSSyntaxError, NotImplementedError, ValueError):
            continue
        if len(lines) != text.count("\n"):
            failures.append(f"{name}: {len(lines)} entries for "
                            f"{text.count(chr(10))} lines")
            continue
        squeeze = lambda s: ["".join(l.split()) for l in s.splitlines()]
        if squeeze(text) != squeeze(source):
            moved += 1
            continue
        checked += 1
        missing = _missing(tree, lines)
        if missing:
            failures.append(f"{name}: {', '.join(missing[:5])}")
    print(f"line map: {checked} programs checked, {moved} with moved layout, "
          f"{len(failures)} failed")
    assert checked > 0
    assert not failures, "\n".join(failures[:15])


# -- compile ------------------------------------------------------------------

def _dsc_json(dsc, text, filename="gen", search_path=()):
    """What `dsc compile` itself reports for `text`: the reference `compile`'s
    mapping is measured against."""
    library = [arg for p in search_path
               for arg in ("-L", str(pathlib.Path(p).resolve()))]
    run = subprocess.run([dsc, "compile", "-", "-o", "-", "--filename",
                          filename, "--diagnostics", "json", *library],
                         input=text.encode("utf-8"), capture_output=True,
                         check=False)
    stderr = run.stderr.decode("utf-8")
    return run.returncode, (json.loads(stderr)["diagnostics"]
                            if stderr.strip() else [])


def _relocate(tree, where, *, rest, author):
    """As a generator does: every node at `rest`, the author's `where` at
    `author` (line, column)."""
    for node in _located(tree):
        node.lineno, node.col_offset = rest, 0
    for node in walk(where):
        node.lineno, node.col_offset = author


def test_an_accepted_program_compiles_and_warns_of_nothing(dsc):
    tree = ds_ast.parse(GOOD.format(where=WHERE), dsc=dsc)
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        artefact = ds_ast.compile(tree, "program.ds", dsc=dsc)
    assert isinstance(artefact, bytes) and artefact
    assert _dsc_json(dsc, ds_ast.unparse(tree)) == (0, [])


def test_a_refusal_is_reported_at_the_authors_line(dsc):
    """The generator's case: `dsc` names the text's line 8; the error names
    the line the author wrote the `where` on, and the node."""
    tree = ds_ast.parse(GOOD.format(where=UNKNOWN_SLOT), dsc=dsc)
    where = _where(tree)
    _relocate(tree, where, rest=40, author=(12, 8))
    status, said = _dsc_json(dsc, ds_ast.unparse(tree))
    assert status == 1 and said[0]["span"]["start"]["line"] == WHERE_LINE
    with pytest.raises(DSSyntaxError) as caught:
        ds_ast.compile(tree, "Buildfile", dsc=dsc)
    err = caught.value
    assert err.code == said[0]["code"]
    assert (err.filename, err.lineno, err.offset) == ("Buildfile", 12, 9)
    assert any(err.node is node for node in walk(where))
    assert err.generated == (WHERE_LINE, said[0]["span"]["start"]["column"])
    assert err.diagnostics[0] is err
    assert [d.code for d in err.diagnostics] == [d["code"] for d in said]


def test_a_refusal_with_no_located_node_keeps_only_dscs_place(dsc):
    tree = ds_ast.parse(GOOD.format(where=UNKNOWN_SLOT), dsc=dsc)
    for node in _located(tree):
        del node.lineno
    with pytest.raises(DSSyntaxError) as caught:
        ds_ast.compile(tree, "Buildfile", dsc=dsc)
    err = caught.value
    assert (err.lineno, err.offset, err.node) == (None, None, None)
    assert err.generated[0] == WHERE_LINE


def test_a_warning_is_issued_at_the_authors_line(dsc):
    tree = ds_ast.parse(GOOD.format(where=IDENTITY_CAST), dsc=dsc)
    where = _where(tree)
    _relocate(tree, where, rest=40, author=(12, 8))
    with pytest.warns(DSSyntaxWarning) as caught:
        artefact = ds_ast.compile(tree, "Buildfile", dsc=dsc)
    assert isinstance(artefact, bytes) and artefact
    [w] = [r.message for r in caught if isinstance(r.message, DSSyntaxWarning)]
    assert w.code == "DS_VALIDATE_CAST_IDENTITY"
    assert (w.filename, w.lineno, w.offset) == ("Buildfile", 12, 9)
    assert any(w.node is node for node in walk(where))
    assert any(isinstance(node, Cast) for node in walk(where))
    assert w.generated[0] == WHERE_LINE
    assert [r.lineno for r in caught if r.category is DSSyntaxWarning] == [12]


# -- a diagnostic in a library the program imports ------------------------------
#
# [RCLI.1.9]: `dsc` names a diagnostic in any file but the program by that
# file, as its `DsSource` does ([RDSC.14.2.3]): a library read from a `-L`
# entry by the path it was read from. It is in no text `unparse` wrote, so it
# keeps `dsc`'s file, line and column, and has no node.

# A program clean in itself, every node of it located: a library diagnostic
# mapped through the line map would land on one of them.
IMPORTER = (
    "use default\n\n"
    "from mylib import Sensor\n\n"
    "rule kitchen_seen:\n"
    "    Sensor s where s.entity_id == \"kitchen\"\n"
    "->\n"
    "    log warning \"seen\"\n")

# Line 6 reads a slot `Sensor` does not declare, in a rule the library
# carries ([LIMP.1.3]).
LIBRARY_ERROR = (
    "schema Sensor scope logical:\n"
    "    entity_id: String key\n"
    "    state: Float mutable\n\n"
    "rule kitchen_level:\n"
    "    Sensor s where s.level > 75\n"
    "->\n"
    "    log warning \"high\"\n")
LIBRARY_ERROR_LINE = 6

# Line 6 names a type nobody declares, in a schema the importer does not use:
# refused in lowering, not in validation, so it reaches the diagnostics by
# another path through `dsc`.
LIBRARY_SCHEMA_ERROR = (
    "schema Sensor scope logical:\n"
    "    entity_id: String key\n"
    "    state: Float mutable\n\n"
    "schema Other scope logical:\n"
    "    name: Strin key\n")

# Accepted, with a warning on line 6: an identity cast ([LCST.4.5.1]) in a
# rule the library carries ([LIMP.1.3]).
LIBRARY_WARNING = (
    "schema Sensor scope logical:\n"
    "    entity_id: String key\n"
    "    state: Float mutable\n\n"
    "rule kitchen_high:\n"
    "    Sensor s where s.state::Float > 75\n"
    "->\n"
    "    log warning \"high\"\n")
LIBRARY_WARNING_LINE = 6


def _library(tmp_path, text):
    (tmp_path / "mylib.ds").write_text(text, encoding="utf-8")
    return tmp_path


@pytest.mark.parametrize("source, code", [
    (LIBRARY_ERROR, "DS_VALIDATE_UNKNOWN_SLOT"),
    (LIBRARY_SCHEMA_ERROR, "DS_VALIDATE_UNKNOWN_TYPE"),
], ids=["in-a-rule", "in-a-schema"])
def test_a_library_error_keeps_dscs_file_line_and_column(dsc, tmp_path,
                                                         source, code):
    lib = _library(tmp_path, source)
    tree = ds_ast.parse(IMPORTER, "prog", dsc=dsc)
    status, said = _dsc_json(dsc, ds_ast.unparse(tree), "prog", [lib])
    assert status == 1, said
    library = [d for d in said if d["span"]["file"] != "prog"]
    assert any(d["span"]["file"].endswith("mylib.ds")
               and d["span"]["start"]["line"] == LIBRARY_ERROR_LINE
               and d["code"] == code for d in library), said
    with pytest.raises(DSSyntaxError) as caught:
        ds_ast.compile(tree, "prog", dsc=dsc, search_path=[lib])
    err = caught.value
    assert err.diagnostics[0] is err
    assert [d.code for d in err.diagnostics] == [d["code"] for d in said]
    for got, want in zip(err.diagnostics, said):
        span = want["span"]
        if span["file"] == "prog":
            # The program's own: through the line map, as the Buildfile
            # tests check in full.
            assert got.filename == "prog" and got.generated is not None, said
            continue
        assert (got.filename, got.lineno, got.offset) == \
            (span["file"], span["start"]["line"],
             span["start"]["column"]), said
        assert (got.node, got.generated) == (None, None), said


def test_a_library_warning_is_issued_at_the_librarys_line(dsc, tmp_path):
    lib = _library(tmp_path, LIBRARY_WARNING)
    tree = ds_ast.parse(IMPORTER, "prog", dsc=dsc)
    status, said = _dsc_json(dsc, ds_ast.unparse(tree), "prog", [lib])
    assert status == 0
    [where] = [d for d in said if d["code"] == "DS_VALIDATE_CAST_IDENTITY"]
    assert where["span"]["file"].endswith("mylib.ds")
    assert where["span"]["start"]["line"] == LIBRARY_WARNING_LINE
    with pytest.warns(DSSyntaxWarning) as caught:
        artefact = ds_ast.compile(tree, "prog", dsc=dsc, search_path=[lib])
    assert isinstance(artefact, bytes) and artefact
    [record] = [r for r in caught if isinstance(r.message, DSSyntaxWarning)
                and r.message.code == "DS_VALIDATE_CAST_IDENTITY"]
    w = record.message
    assert (w.filename, w.lineno, w.offset) == \
        (where["span"]["file"], LIBRARY_WARNING_LINE,
         where["span"]["start"]["column"])
    assert (w.node, w.generated) == (None, None)
    assert (record.filename, record.lineno) == \
        (where["span"]["file"], LIBRARY_WARNING_LINE)


def test_one_path_is_not_a_search_path(dsc):
    tree = ds_ast.parse(GOOD.format(where=WHERE), dsc=dsc)
    with pytest.raises(TypeError):
        ds_ast.compile(tree, dsc=dsc, search_path="lib")


def test_a_broken_invocation_is_not_a_refused_program(dsc):
    """`dsc` exits 2 for a file it cannot read ([RCLI.3.1]): that is the
    command's fault, never a `DSSyntaxError` about the program."""
    tree = ds_ast.parse(GOOD.format(where=WHERE), dsc=dsc)
    missing = pathlib.Path(__file__).parent / "no-such-dialect.yaml"
    assert not missing.exists()
    with pytest.raises(RuntimeError, match="exited 2"):
        ds_ast.compile(tree, dsc=dsc, dialect_files=[missing])


def test_use_stays_first_when_every_node_has_one_line(dsc):
    """A generator that gives every node its step's line: `use` must not
    follow the rules, which `dsc` would refuse."""
    tree = ds_ast.parse(GOOD.format(where=WHERE), dsc=dsc)
    for node in _located(tree):
        node.lineno = 40
    assert ds_ast.unparse(tree) == GOOD.format(where=WHERE)

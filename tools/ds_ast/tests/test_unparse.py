# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Rung A5: `unparse`, and the round trip that keeps it honest.

`unparse` is a printer written beside a parser it shares no code with, so the
two drift unless something holds them together. That is
`parse(unparse(parse(s))) == parse(s)` over the whole corpus, locations
excluded and trivia INCLUDED -- a comment or blank line that moves to another
node fails it (tools/ds_ast/DESIGN.md section 5).
"""
import os
import pathlib
import re
import subprocess

import pytest

import ds_ast
from ds_ast import (AST, BinOp, BoolOp, Compare, Constant, Mult, Add, Name,
                    Pow, Sub, UnaryOp, USub, Attribute, Lt, Or, And, Not,
                    DSSyntaxError)

from test_parse import PROGRAM, ROOT, _corpus

_LOCATIONS = {"lineno", "col_offset", "end_lineno", "end_col_offset"}


@pytest.fixture(scope="module")
def dsc():
    binary = os.environ.get("DS_AST_DSC")
    if not binary or not pathlib.Path(binary).is_file():
        pytest.fail("DS_AST_DSC must name the Mercury dsc binary; the ds-ast "
                    "gate builds it")
    return binary


def _difference(a, b, path="Module"):
    """Where two trees differ, ignoring locations, or None. Trivia is
    compared: that is the point of keeping it."""
    if type(a) is not type(b):
        return f"{path}: {type(a).__name__} != {type(b).__name__}"
    if isinstance(a, AST):
        for name in a._fields + a._attributes:
            if name in _LOCATIONS:
                continue
            found = _difference(getattr(a, name, None), getattr(b, name, None),
                                f"{path}.{name}")
            if found:
                return found
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{path}: {len(a)} items != {len(b)}"
        for i, (x, y) in enumerate(zip(a, b)):
            found = _difference(x, y, f"{path}[{i}]")
            if found:
                return found
        return None
    return None if a == b else f"{path}: {a!r} != {b!r}"


def test_the_a3_program_comes_back_byte_for_byte(dsc):
    """Comments, the trailing comment's two spaces, blank lines, `0x1F` and
    the ttl span: everything this program carries, the tree carries."""
    assert ds_ast.unparse(ds_ast.parse(PROGRAM, dsc=dsc)) == PROGRAM


def test_every_corpus_program_round_trips(dsc):
    """The property. Counted, and a program `parse` refuses is not a
    round-trip case -- test_parse owns that population."""
    checked = 0
    failures = []
    for name, source in _corpus():
        try:
            first = ds_ast.parse(source, name, dsc=dsc)
        except (DSSyntaxError, NotImplementedError):
            continue
        checked += 1
        try:
            text = ds_ast.unparse(first)
        except ValueError as err:
            failures.append(f"{name}: unparse refused: {err}")
            continue
        try:
            second = ds_ast.parse(text, name, dsc=dsc)
        except (DSSyntaxError, NotImplementedError) as err:
            failures.append(f"{name}: the unparsed text does not parse: "
                            f"{err}\n--- unparsed ---\n{text}")
            continue
        found = _difference(first, second)
        if found:
            failures.append(f"{name}: {found}")
    print(f"round trip: {checked} programs, {len(failures)} failed")
    assert checked > 0
    assert not failures, "\n".join(failures[:15])


_CODE_LINE = re.compile(r"^([A-Z][A-Z0-9_]*): ", re.MULTILINE)
_USE_LINE = re.compile(r"^use\b", re.MULTILINE)
_HARNESS_DIALECTS = sorted(
    (ROOT / "specs" / "conformance" / "harness" / "dialects").glob("*.yaml"))


def _compile_outcome(dsc, source, scratch):
    """`dsc compile`'s exit status and the set of diagnostic codes it
    printed, for `source` written to a file under `scratch`.

    ⚠ COMPILED AS THE CONFORMANCE HARNESS COMPILES IT. A corpus source with no
    `use` line is a library ([LDIA.2.10.1]) that `dsc` refuses to build, so
    left as it is, both sides of the comparison would be the same
    DS_VALIDATE_NOT_A_PROGRAM and agree while saying nothing about the
    program. The conformance harness compiles such a test input as though
    it began with `use default`, and registers the harness
    dialects, as `runner._compile_mercury` does."""
    if not _USE_LINE.search(source):
        source = "use default\n" + source
    path = scratch / "program.ds"
    path.write_text(source, encoding="utf-8")
    dialects = [arg for d in _HARNESS_DIALECTS for arg in ("-d", str(d))]
    run = subprocess.run([dsc, "compile", str(path), "-o",
                          str(scratch / "program.dsc"), *dialects],
                         capture_output=True, check=False)
    stderr = run.stderr.decode("utf-8", errors="replace")
    return run.returncode, frozenset(_CODE_LINE.findall(stderr))


def test_unparsed_source_compiles_to_the_same_outcome(dsc):
    """DESIGN.md section 5's second check: the tree being equal is a claim
    about `ds_ast`; this is the claim about the program. `dsc compile` on
    `s` and on `unparse(parse(s))` must exit alike and name the same codes.
    Artefact bytes are not compared: the source spans and the embedded
    module text differ by construction wherever layout did.

    Scratch is under the clone's `.build/`, never `/tmp`."""
    scratch = ROOT / ".build" / "ds-ast-scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    checked = 0
    failures = []
    for name, source in _corpus():
        try:
            text = ds_ast.unparse(ds_ast.parse(source, name, dsc=dsc))
        except (DSSyntaxError, NotImplementedError, ValueError):
            continue
        checked += 1
        before = _compile_outcome(dsc, source, scratch)
        after = _compile_outcome(dsc, text, scratch)
        if before != after:
            failures.append(f"{name}: {before} != {after}")
    print(f"compile equivalence: {checked} programs, {len(failures)} differ")
    assert checked > 0
    assert not failures, "\n".join(failures[:15])


# -- parentheses, which the tree does not record -----------------------------

@pytest.mark.parametrize("tree, text", [
    (BinOp(BinOp(Name("a"), Add(), Name("b")), Mult(), Name("c")),
     "(a + b) * c"),
    (BinOp(Name("a"), Add(), BinOp(Name("b"), Mult(), Name("c"))),
     "a + b * c"),
    (BinOp(Name("a"), Sub(), BinOp(Name("b"), Sub(), Name("c"))),
     "a - (b - c)"),
    (BinOp(BinOp(Name("a"), Sub(), Name("b")), Sub(), Name("c")),
     "a - b - c"),
    (BinOp(Name("a"), Pow(), BinOp(Name("b"), Pow(), Name("c"))),
     "a ** b ** c"),
    (BinOp(BinOp(Name("a"), Pow(), Name("b")), Pow(), Name("c")),
     "(a ** b) ** c"),
    (UnaryOp(USub(), BinOp(Name("a"), Pow(), Name("b"))), "-(a ** b)"),
    (BinOp(UnaryOp(USub(), Name("a")), Pow(), Name("b")), "-a ** b"),
    (UnaryOp(Not(), BoolOp(And(), [Name("a"), Name("b")])), "not (a and b)"),
    (BoolOp(Or(), [Name("a"), BoolOp(Or(), [Name("b"), Name("c")])]),
     "a or (b or c)"),
    (Attribute(Constant(5), "bit_count"), "(5).bit_count"),
    (Compare(BinOp(Name("a"), Add(), Constant(1)), [Lt()], [Name("b")]),
     "a + 1 < b"),
])
def test_parentheses_are_inserted_by_precedence(tree, text):
    assert ds_ast.unparse(tree) == text


def test_a_log_keeps_the_arguments_validate_refuses(dsc):
    """`log` takes no kwarg, and `validate` says so by code
    (`LGRA.10.3.3_unknown_kwarg_log`) -- which only works if the argument
    survives into the tree. It used to be dropped, and the unparsed program
    then compiled where the source was refused."""
    source = 'rule r:\n    S s\n->\n    log info "x" level: 3\n'
    tree = ds_ast.parse(source, dsc=dsc)
    log = tree.body[0].actions[0]
    assert [k.arg for k in log.args] == ["level"]
    assert ds_ast.unparse(tree) == source


def test_a_unit_suffix_keeps_the_authors_code_points():
    """The lexer canonicalises `μ` (U+03BC) to `µ` (U+00B5) in the unit, so a
    correct `raw` and the unit differ in code points (LUNI.3.1_duration_sub_ms).
    The author's spelling is what is written back."""
    from ds_ast import Quantity
    assert ds_ast.unparse(Quantity("3", "_µs", "3_μs")) == "3_μs"
    assert ds_ast.unparse(Quantity("4", "_µs", "3_μs")) == "4_µs"


def test_a_changed_value_is_not_written_with_its_stale_spelling():
    literal = Constant(31, "0x1F")
    assert ds_ast.unparse(literal) == "0x1F"
    literal.value = 32
    assert ds_ast.unparse(literal) == "32"


def test_a_capture_list_round_trips(dsc):
    """[LREG.4.1]'s `where (a, b) = ...`: `captures` is a prefix on the
    `where`, which holds the whole condition, and both come back."""
    text = ("schema Log scope logical:\n    k: Int key\n    msg: String mutable\n"
            "\nrule r:\n"
            "    Log e where (a, b) = e.msg ~ /(\\w+) (\\w+)/ and a == \"x\"\n"
            "->\n    log info \"{b}\"\n")
    mod = ds_ast.parse(text, dsc=dsc)
    body = next(n for n in ds_ast.walk(mod)
                if isinstance(n, ds_ast.PatternBody))
    assert body.captures == ["a", "b"]
    assert "Log e where (a, b) = e.msg ~ " in ds_ast.unparse(mod)
    assert _difference(mod, ds_ast.parse(ds_ast.unparse(mod), dsc=dsc)) is None


def test_a_built_program_unparses_and_parses(dsc):
    """The fourth job: build a program from nodes, write it, read it back."""
    from ds_ast import Emit, Module, PatternBody, PatternClause, Rule, \
        Schema, Simple, Slot, TypeName, keyword
    where = Compare(Attribute(Name("r"), "value"), [Lt()], [Constant(5, "5")])
    body = PatternBody(TypeName("Reading"), "r", where=where)
    emit = Emit(TypeName("Alert"),
                args=[keyword("value", Attribute(Name("r"), "value"))])
    rule = Rule("hot", lhs=[PatternClause(Simple(body))], actions=[emit])
    mod = Module(body=[
        Schema("Reading", slots=[Slot("value", "Int", False)]),
        Schema("Alert", slots=[Slot("value", "Int", False)]),
        rule])
    text = ds_ast.unparse(mod)
    again = ds_ast.parse(text, dsc=dsc)
    assert _difference(mod, again) is None, text


def test_a_qualified_schema_head_round_trips(dsc):
    """LGRA.10.1 / LTSL.4.4: `emit`, `publish` and `record_event`, and
    a test's facts and `produces` heads, name a schema as a pattern does --
    `lib.Name` included -- and the qualifier survives a write and a
    read."""
    source = (
        "import ha\n\n"
        "rule r:\n"
        "    ha.Trig t\n"
        "->\n"
        "    emit ha.Alert logical v: t.v\n"
        "    publish ha.Alert v: t.v\n"
        "    record_event ha.Seen v: t.v\n\n"
        "test \"qualified\":\n"
        "    inputs:\n"
        "        at 0_s:\n"
        "            ha.Trig v: 1\n"
        "    produces:\n"
        "        emitted ha.Alert v: 1\n"
        "        wm count ha.Alert == 1\n"
        "        wm has ha.Alert v: 1\n")
    mod = ds_ast.parse(source, dsc=dsc)
    rule = mod.body[1]
    assert [type(a.schema).__name__ for a in rule.actions] == \
        ["QualifiedType"] * 3
    assert [(a.schema.library, a.schema.name) for a in rule.actions] == \
        [(["ha"], "Alert"), (["ha"], "Alert"), (["ha"], "Seen")]
    text = ds_ast.unparse(mod)
    assert "emit ha.Alert logical" in text and "wm count ha.Alert == 1" in text
    assert _difference(mod, ds_ast.parse(text, dsc=dsc)) is None, text

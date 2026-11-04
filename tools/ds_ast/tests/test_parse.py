# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Rung A4: `parse` through the Mercury `dsc`, and the strict reader.

The reader's refusals are tested on hand-built JSON, with no compiler. The
parse tests need the binary and FAIL without it rather than skipping: a
skipped parse test reads as a pass in the lane's count, which is a false
green.
"""
import json
import os
import pathlib
import subprocess

import pytest

import ds_ast
from ds_ast import (BoolOp, Compare, Constant, DSSyntaxError, DSTreeError,
                    Log, LogInfo, NoServiceResponse, Quantity, ResponseSchema,
                    Rule, Schema, Ttl, Use, from_json)

ROOT = pathlib.Path(__file__).resolve().parents[3]

# The program `test_dsc`'s `test_dump_ast` checks on the Mercury side, so the
# two halves of the round trip are measured on one input.
PROGRAM = (
    "# head\nuse default\n\nschema S scope ttl 5_min:  # after\n"
    "    k: String key\n    v: Int mutable\n\n"
    "schema Lock scope activation:\n    k: String key\n\n\n"
    "rule r:\n"
    "    S s where s.v > 0x1F and s.v < 100 and s.k == \"x\"\n"
    "->\n    log info \"hi\"\n# tail\n")


@pytest.fixture(scope="module")
def dsc():
    binary = os.environ.get("DS_AST_DSC")
    if not binary or not pathlib.Path(binary).is_file():
        pytest.fail("DS_AST_DSC must name the Mercury dsc binary; the ds-ast "
                    "gate builds it")
    return binary


@pytest.fixture(scope="module")
def tree(dsc):
    return ds_ast.parse(PROGRAM, "program.ds", dsc=dsc)


def test_the_declarations_come_back_in_order(tree):
    assert isinstance(tree.use, Use) and tree.use.dialect == "default"
    assert [type(d).__name__ for d in tree.body] == ["Schema", "Schema",
                                                     "Rule"]
    assert [d.name for d in tree.body] == ["S", "Lock", "r"]


def test_locations_are_one_based_lines_and_zero_based_columns(tree):
    rule = tree.body[2]
    assert (rule.lineno, rule.col_offset) == (12, 0)
    assert rule.end_lineno is None, "dsc writes no end positions yet"


def test_comments_and_blank_lines_ride_on_the_nodes(tree):
    assert [c.text for c in tree.use.comments_before] == ["# head"]
    assert tree.body[0].comment_after.text == "# after"
    assert tree.body[2].blank_lines_before == 2
    assert [c.text for c in tree.comments_end] == ["# tail"]


def test_the_ttl_span_is_an_expression_with_its_spelling(tree):
    scope = tree.body[0].scope
    assert isinstance(scope, Ttl) and isinstance(scope.duration, Quantity)
    assert scope.duration.raw == "5_min"


def test_a_literal_keeps_its_spelling(tree):
    raws = [n.raw for n in ds_ast.walk(tree) if isinstance(n, Constant)]
    assert "0x1F" in raws
    [hex_literal] = [n for n in ds_ast.walk(tree)
                     if isinstance(n, Constant) and n.raw == "0x1F"]
    assert hex_literal.value == 31


def test_int64_min_keeps_its_whole_spelling(dsc):
    """Two tokens, one literal: the parser folds `-` and the magnitude into one
    `ex_int` positioned at the minus ([LGRA.2.7.3]), so a raw read off one
    token is `-`, which denotes nothing."""
    tree = ds_ast.parse("const M = -9223372036854775808\n", dsc=dsc)
    value = tree.body[0].value
    assert isinstance(value, Constant)
    assert (value.value, value.raw) == (-2 ** 63, "-9223372036854775808")


def test_the_flat_and_chain(tree):
    rule = tree.body[2]
    assert isinstance(rule, Rule)
    where = rule.lhs[0].pattern.body.where
    assert isinstance(where, BoolOp) and len(where.values) == 3
    assert all(isinstance(v, Compare) for v in where.values)


def test_a_log_message_keeps_its_quotes_in_raw(tree):
    log = tree.body[2].actions[0]
    assert isinstance(log, Log) and isinstance(log.level, LogInfo)
    assert (log.message.value, log.message.raw) == ("hi", '"hi"')


def test_a_syntax_error_is_shaped_like_pythons(dsc):
    with pytest.raises(DSSyntaxError) as caught:
        ds_ast.parse("schema\n", "broken.ds", dsc=dsc)
    err = caught.value
    assert isinstance(err, SyntaxError)
    assert err.filename == "broken.ds"
    assert err.lineno is not None and err.offset is not None
    assert err.offset >= 1, "SyntaxError.offset is 1-based"
    assert err.code, "the compiler's code is what a caller branches on"


# @spec [RCLI.1.10]
def test_dump_ast_writes_one_dsasdl_module_counted_in_code_points(dsc):
    """[RCLI.1.10]: `dsc dump-ast -` writes one JSON document to standard
    output, `ds.asdl`'s `Module`, and nothing to standard error. It is read
    here by `from_json`, the reader generated from ds.asdl, which refuses a
    node, field or kind the definition does not have.

    `lineno` is 1-based and `col_offset` 0-based, in code points: the `0x1F`
    sits after a string of three two-byte letters, so a column counted in
    bytes would be 40 and a 1-based one 38."""
    source = ('use default\n\nschema S scope logical:\n    k: String key\n'
              '    v: Int mutable\n\nrule r:\n'
              '    S s where s.k == "\u00e9\u00e9\u00e9" and s.v > 0x1F\n'
              '->\n    log info "hi"\n')
    run = subprocess.run([dsc, "dump-ast", "-"],
                         input=source.encode("utf-8"), capture_output=True,
                         check=False)
    assert run.returncode == 0, run.stderr.decode("utf-8", errors="replace")
    assert run.stderr == b""
    tree = from_json(json.loads(run.stdout.decode("utf-8")))
    assert isinstance(tree, ds_ast.Module)
    [literal] = [n for n in ds_ast.walk(tree)
                 if isinstance(n, Constant) and n.raw == "0x1F"]
    assert (literal.lineno, literal.col_offset) == (8, 37)


def test_a_test_block_is_parsed_not_skipped(dsc):
    """`dsc.parse` used to skip a `test` block's tokens whole, so any block
    that lexed was accepted and nothing could be written. A section the
    grammar does not have ([LTSL.2.3]) is now a syntax error;
    tests/test_tests.py covers the forms it does have."""
    source = 'test "t":\n    given:\n        x\n'
    with pytest.raises(DSSyntaxError):
        ds_ast.parse(source, "t.dstest", dsc=dsc)


def test_a_services_response_line_keeps_its_three_states(dsc):
    """[LGRA.23.1]: `response T`, `no response`, or no line at all. The last
    parses and is the validator's to refuse ([LGRA.23.2]), so the tree has to
    tell it apart from `no response` rather than collapse the two to None."""
    source = ("schema R scope ttl 1_h:\n    corr: String\n\n"
              "service a.one:\n    kwarg n: Int\n    response R\n\n"
              "service a.two:\n    kwarg n: Int\n    no response\n\n"
              "service a.three:\n    kwarg n: Int\n")
    tree = ds_ast.parse(source, "services.ds", dsc=dsc)
    one, two, three = tree.body[1:]
    assert isinstance(one.response, ResponseSchema)
    assert one.response.name == "R"
    assert isinstance(two.response, NoServiceResponse)
    assert three.response is None
    assert ds_ast.unparse(tree).count("    no response\n") == 1


def _corpus():
    sources = []
    for path in sorted((ROOT / "specs/conformance").rglob("*.json")):
        rules = json.loads(path.read_text(encoding="utf-8")).get("rules_ds")
        if isinstance(rules, str):
            sources.append((str(path.relative_to(ROOT)), rules))
    # Each glob must match, or a moved directory silently shrinks the corpus
    # -- the suite's files sit one level down, and `suite/*.ds` read none.
    for pattern in ("runtime/mercury/test/fixtures/*.ds", "stdlib/units/*.ds",
                    "benchmarks/classic/suite/*/*.ds"):
        matched = sorted(ROOT.glob(pattern))
        assert matched, f"{pattern} matched nothing"
        for path in matched:
            sources.append((str(path.relative_to(ROOT)),
                            path.read_text(encoding="utf-8")))
    return sources


def test_every_corpus_program_reads_or_is_refused_as_syntax(dsc):
    """The strict reader against everything the compiler can be handed. A
    `DSTreeError` anywhere is the Mercury writer and ds.asdl disagreeing; a
    syntax refusal is the corpus's business (compiler fixtures refuse on
    purpose). Counted, so an empty glob fails instead of passing."""
    corpus = _corpus()
    parsed = syntax = 0
    unrepresentable = []
    disagreements = []
    for name, source in corpus:
        try:
            ds_ast.parse(source, name, dsc=dsc)
            parsed += 1
        except DSSyntaxError:
            syntax += 1
        except NotImplementedError as refused:
            unrepresentable.append(f"  {name}: {refused}")
        except DSTreeError as err:
            disagreements.append(f"{name}: {err}")
    print(f"corpus: {len(corpus)} programs, {parsed} parsed, {syntax} "
          f"refused as syntax, {len(unrepresentable)} not representable yet")
    # Named, not only counted: a count that moves says nothing about which
    # construct moved it.
    print("\n".join(unrepresentable))
    assert not disagreements, "\n".join(disagreements[:20])
    assert parsed > len(corpus) // 2, (
        f"only {parsed} of {len(corpus)} parsed; the reader is refusing "
        f"something wholesale")


# -- the reader, with no compiler ------------------------------------------

def _name(identifier="x"):
    return {"_type": "Name", "id": identifier, "lineno": 1, "col_offset": 0,
            "end_lineno": None, "end_col_offset": None}


def test_the_reader_builds_a_node_from_its_json():
    node = from_json(_name())
    assert (type(node).__name__, node.id, node.lineno) == ("Name", "x", 1)


@pytest.mark.parametrize("mutate, message", [
    (lambda j: j.update(_type="Nope"), "not a node"),
    (lambda j: j.update(_type="expr"), "not a node"),
    (lambda j: j.update(colour="red"), "has no colour"),
    (lambda j: j.pop("col_offset"), "without col_offset"),
    (lambda j: j.update(id=7), "should be str"),
    (lambda j: j.update(lineno=True), "should be int"),
    (lambda j: j.update(id=None), "is null"),
    (lambda j: j.pop("_type"), "no `_type`"),
])
def test_the_reader_refuses_what_the_schema_does_not_say(mutate, message):
    """Each case is a way the Mercury writer could drift from ds.asdl and
    still produce valid JSON."""
    doc = _name()
    mutate(doc)
    with pytest.raises(DSTreeError, match=message):
        from_json(doc)


def test_the_reader_checks_the_type_of_a_child_node():
    attr = {"_type": "Attribute", "value": {"_type": "Eq"}, "attr": "v",
            "lineno": 1, "col_offset": 0, "end_lineno": None,
            "end_col_offset": None}
    with pytest.raises(DSTreeError, match="should be expr"):
        from_json(attr)

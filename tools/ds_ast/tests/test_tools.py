# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Rung A4: Python's `ast` helpers, on trees built by hand.

Each case is a behaviour of the Python original that a reimplementation
commonly gets wrong, or a place DS's trivia forces a choice Python never had
to make.
"""
import pytest

import ds_ast
from ds_ast import (Attribute, Compare, Constant, Emit, Log, LogInfo, Lt,
                    Module, Name, NodeTransformer, NodeVisitor, Rule, Schema,
                    Slot, TypeName, comment, keyword)


def _rule():
    where = Compare(Attribute(Name("s"), "v"), [Lt()], [Constant(5, "5")])
    return Rule("r", actions=[
        Emit(TypeName("Alert"), args=[keyword("level", Name("level"))]),
        Log(LogInfo(), Constant("hi", '"hi"'))]), where


def test_iter_fields_skips_an_unset_field():
    slot = Slot()
    slot.name = "v"
    assert dict(ds_ast.iter_fields(slot))["name"] == "v"
    assert "type" not in dict(ds_ast.iter_fields(slot))


def test_walk_reaches_every_node_through_lists_and_fields():
    rule, where = _rule()
    names = {n.id for n in ds_ast.walk(Module(body=[rule])) if isinstance(n, Name)}
    assert names == {"level"}
    assert {n.id for n in ds_ast.walk(where) if isinstance(n, Name)} == {"s"}


def test_walk_does_not_visit_riding_comments_but_does_visit_comments_end():
    """Trivia is attributes, like locations (the `_tools` module header);
    `Module.comments_end` is a field."""
    schema = Schema("S", comments_before=[comment("# before")])
    mod = Module(body=[schema], comments_end=[comment("# end")])
    texts = [n.text for n in ds_ast.walk(mod) if isinstance(n, comment)]
    assert texts == ["# end"]


def test_visitor_dispatches_by_class_name_and_falls_back_to_children():
    class Names(NodeVisitor):
        def __init__(self):
            self.seen = []

        def visit_Name(self, node):
            self.seen.append(node.id)

    rule, where = _rule()
    visitor = Names()
    visitor.visit(Module(body=[rule]))
    visitor.visit(where)
    assert visitor.seen == ["level", "s"]


def test_transformer_replaces_removes_and_splices():
    class Rewrite(NodeTransformer):
        def visit_Log(self, node):
            return None

        def visit_Name(self, node):
            return Name(node.id.upper())

        def visit_Emit(self, node):
            self.generic_visit(node)
            return [node, Emit(TypeName("Audit"))]

    rule, _ = _rule()
    out = Rewrite().visit(rule)
    assert [type(a).__name__ for a in out.actions] == ["Emit", "Emit"]
    assert out.actions[0].args[0].value.id == "LEVEL"
    assert out.actions[1].schema.name == "Audit"


def test_transformer_returning_none_for_a_single_field_deletes_it():
    class Drop(NodeTransformer):
        def visit_Name(self, node):
            return None

    attr = Drop().visit(Attribute(Name("s"), "v"))
    assert not hasattr(attr, "value")


def test_dump_is_python_313_shaped():
    assert ds_ast.dump(Name("x")) == "Name(id='x')"
    assert ds_ast.dump(Schema("S")) == "Schema(name='S')", (
        "None and [] are left out unless show_empty")
    assert ds_ast.dump(Schema("S"), show_empty=True) == (
        "Schema(name='S', scope=None, docstring=None, slots=[])")
    assert ds_ast.dump(Name("x"), annotate_fields=False) == "Name('x')"


def test_dump_indents_nested_structure():
    text = ds_ast.dump(Compare(Name("t"), [Lt()], [Constant(5)]), indent=2)
    assert text.splitlines()[0] == "Compare("
    assert "  left=Name(id='t')," in text.splitlines()


def test_dump_include_attributes_writes_locations_and_trivia():
    node = Name("x", lineno=3, col_offset=4)
    assert "lineno=3" in ds_ast.dump(node, include_attributes=True)
    assert "lineno" not in ds_ast.dump(node)


def test_get_docstring_cleans_and_refuses_a_node_without_one():
    rule = Rule("r", docstring="\n    First line.\n      indented\n")
    assert ds_ast.get_docstring(rule) == "First line.\n  indented"
    assert ds_ast.get_docstring(Rule("r")) is None
    with pytest.raises(TypeError, match="can't have docstrings"):
        ds_ast.get_docstring(Name("x"))


def test_copy_location_copies_locations_and_not_trivia():
    old = Schema("S", lineno=5, col_offset=0, end_lineno=None,
                 end_col_offset=None, comments_before=[comment("# c")])
    new = ds_ast.copy_location(Schema("T"), old)
    assert (new.lineno, new.col_offset) == (5, 0)
    assert new.end_lineno is None, "an explicit None end is copied, as Python does"
    assert new.comments_before == []


def test_fix_missing_locations_inherits_from_the_parent():
    rule, _ = _rule()
    rule.lineno, rule.col_offset = 7, 0
    ds_ast.fix_missing_locations(Module(body=[rule]))
    name = rule.actions[0].args[0].value
    assert (name.lineno, name.col_offset) == (7, 0)


def test_increment_lineno_moves_the_riding_comments_too():
    schema = Schema("S", lineno=2, col_offset=0, end_lineno=None,
                    end_col_offset=None,
                    comments_before=[comment("# c", lineno=1, col_offset=0)],
                    comment_after=comment("# t", lineno=2, col_offset=12))
    ds_ast.increment_lineno(schema, 10)
    assert schema.lineno == 12 and schema.end_lineno is None
    assert schema.comments_before[0].lineno == 11
    assert schema.comment_after.lineno == 12

# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Rung A6: `test` declarations ([LTSL]) as a tree.

The corpus has test blocks only in the classic benchmark suite, which uses
five of the ten assertion heads and none of `initial` / `responses` /
`until`. So one program here carries every form the parser builds -- each
section, both cache-seed spellings ([LTSL.5.2]), both coordinate modes, a
stub with every clause, every head -- and must come back byte for byte.
"""
import os
import pathlib

import pytest

import ds_ast
from ds_ast import (Assertion, At, CacheBlock, CacheSeed, DSSyntaxError,
                    Emitted, ForCall, InitialFact, NoResponse, Produces,
                    Quantity, Until, WmCount, WmEmpty)

EVERY_FORM = '''\
test "every form":
    initial:
        Account account_no: 1
        cache "k": 42
        cache:
            "a": "x"
            "b": 2.5
    inputs:
        at 0_s:
            Reading zone: "cellar" celsius: 2.0
        at "2026-06-18T14:00:00Z":
            Reading zone: "attic" celsius: 30.0
    responses:
        for call weather.forecast zone: "cellar" as "c1" after 5_s:
            CallResponse corr: "c1" payload: "{}"
        for call light.turn_on as "c2":
            no response
    until 10_min
    produces:
        activated heat_on
        never emitted HeaterOn zone: "attic"
        emitted TempReading t where t.celsius > 40.0
        published Alarm level: 2
        retracted Reading zone: "cellar"
        recorded Audit
        called weather.forecast as "c1"
        cached "k": 42
        cache_deleted "old"
        logged info "heater"
        wm has Account account_no: 1
        wm count Account == 1
        wm empty
'''


@pytest.fixture(scope="module")
def dsc():
    binary = os.environ.get("DS_AST_DSC")
    if not binary or not pathlib.Path(binary).is_file():
        pytest.fail("DS_AST_DSC must name the Mercury dsc binary; the ds-ast "
                    "gate builds it")
    return binary


@pytest.fixture(scope="module")
def tree(dsc):
    return ds_ast.parse(EVERY_FORM, "every.dstest", dsc=dsc)


def test_every_form_comes_back_byte_for_byte(tree):
    assert ds_ast.unparse(tree) == EVERY_FORM


def test_the_sections_in_source_order(tree):
    [test] = tree.body
    # `ds_ast.Test`, not an imported `Test`: pytest collects any `Test*` name
    # in a test module's namespace and warns that the node class cannot be one.
    assert isinstance(test, ds_ast.Test) and test.name.value == "every form"
    assert [type(s).__name__ for s in test.sections] == [
        "Initial", "Inputs", "Responses", "Until", "Produces"]


def test_both_cache_seed_spellings(tree):
    """[LTSL.5.2] admits `cache "k": v` and a `cache:` block; `ds.lark` has
    only the first."""
    initial = tree.body[0].sections[0]
    fact, seed, block = initial.items
    assert isinstance(fact, InitialFact) and fact.fact.schema.name == "Account"
    assert isinstance(seed, CacheSeed) and seed.value.value == 42
    assert isinstance(block, CacheBlock)
    assert [s.key.value for s in block.seeds] == ["a", "b"]


def test_both_coordinate_modes(tree):
    relative, absolute = tree.body[0].sections[1].blocks
    assert isinstance(relative, At) and isinstance(relative.when, Quantity)
    assert absolute.when.value == "2026-06-18T14:00:00Z"
    assert isinstance(tree.body[0].sections[3], Until)


def test_a_stub_and_no_response(tree):
    replied, silent = tree.body[0].sections[2].stubs
    assert isinstance(replied, ForCall)
    assert replied.service == ["weather", "forecast"]
    assert replied.correlation.value == "c1" and replied.after.raw == "5_s"
    # A service is named bare, in one global namespace ([LGRA.10.1.6]).
    assert silent.library == [] and silent.service == ["light", "turn_on"]
    assert [type(r) for r in silent.replies] == [NoResponse]


def test_the_heads(tree):
    produces = tree.body[0].sections[4]
    assert isinstance(produces, Produces)
    assert all(isinstance(a, Assertion) for a in produces.assertions)
    never = produces.assertions[1]
    assert never.never and isinstance(never.head, Emitted)
    where = produces.assertions[2].head
    assert where.binding == "t" and where.where is not None
    assert isinstance(produces.assertions[11].head, WmCount)
    assert isinstance(produces.assertions[12].head, WmEmpty)
    assert [a.never for a in produces.assertions].count(True) == 1


def test_a_draft_modifier_is_not_built(dsc):
    """`exactly N` is [LTSL.8.7], the language tree's one `draft` clause
    besides `exclusive`; the parser does not admit it."""
    source = 'test "t":\n    produces:\n        emitted A exactly 1\n'
    with pytest.raises(DSSyntaxError):
        ds_ast.parse(source, dsc=dsc)

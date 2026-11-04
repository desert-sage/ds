# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Rung A6: strings as Python's f-strings -- decoded `Constant` values, and
`JoinedStr` / `FormattedValue` for interpolation sites.

The tree's reading of a string is the compiler's: `dsc dump-ast` splits and
decodes with `dsc.strlit`, the reader validation and lowering share. These
cases pin what `ds_ast` shows of it, and that `unparse` writes the author's
spelling back until a value changes.
"""
import os
import pathlib

import pytest

import ds_ast
from ds_ast import (Attribute, Constant, DSSyntaxError, FormattedValue,
                    JoinedStr, Name)


@pytest.fixture(scope="module")
def dsc():
    binary = os.environ.get("DS_AST_DSC")
    if not binary or not pathlib.Path(binary).is_file():
        pytest.fail("DS_AST_DSC must name the Mercury dsc binary; the ds-ast "
                    "gate builds it")
    return binary


def _message(dsc, text):
    source = f'rule r:\n    S s\n->\n    log info {text}\n'
    return ds_ast.parse(source, dsc=dsc), source


def test_an_interpolated_message_is_a_joinedstr(dsc):
    tree, source = _message(dsc, '"v={s.v:.2f} {{x}}"')
    message = tree.body[0].actions[0].message
    assert isinstance(message, JoinedStr)
    head, site, tail = message.values
    assert isinstance(head, Constant) and head.value == "v="
    assert isinstance(site, FormattedValue) and site.format_spec == ".2f"
    assert isinstance(site.value, Attribute) and site.value.attr == "v"
    assert isinstance(tail, Constant) and tail.value == " {x}", (
        "`{{x}}` is a literal brace pair, decoded")
    assert ds_ast.unparse(tree) == source


def test_a_unicode_binding_is_a_site(dsc):
    """[LGRA.2.9.6.1]'s NAME is the lexer's identifier, so `{ñame}` is a
    site, whatever Mercury's own letter set holds."""
    tree, _ = _message(dsc, '"{ñame}"')
    [site] = tree.body[0].actions[0].message.values
    assert isinstance(site, FormattedValue)
    assert isinstance(site.value, Name) and site.value.id == "ñame"


def test_a_json_object_in_a_string_is_text(dsc):
    """A `{` a name cannot follow starts no site: three fixtures pin
    `"{\\"v\\":1}"` as literal text."""
    tree, _ = _message(dsc, '"{\\"v\\":1}"')
    message = tree.body[0].actions[0].message
    assert isinstance(message, Constant) and message.value == '{"v":1}'


def test_a_site_the_grammar_cannot_read_is_text(dsc):
    """`{bad json here}` is literal text where interpolation is not eligible
    (`LEXP.json_parse_error`), and an error `validate` names where it is;
    either way the tree holds it, as text, and writes it back."""
    tree, source = _message(dsc, '"{bad json here} {s.v}"')
    head, site = tree.body[0].actions[0].message.values
    assert isinstance(head, Constant) and head.value == "{bad json here} "
    assert isinstance(site, FormattedValue)
    assert ds_ast.unparse(tree) == source


def test_a_one_level_call_is_a_site(dsc):
    """`dsc` compiles `{len(s.k)}` as a site, where `LGRA.2.9.6.3` reads
    otherwise; the difference is filed with the spec lane."""
    tree, source = _message(dsc, '"n={len(s.k)}"')
    _, site = tree.body[0].actions[0].message.values
    assert type(site.value).__name__ == "Call"
    assert ds_ast.unparse(tree) == source


def test_a_value_is_decoded_and_its_spelling_kept(dsc):
    source = 'const C = "a\\tb\\x41"\n'
    tree = ds_ast.parse(source, dsc=dsc)
    value = tree.body[0].value
    assert (value.value, value.raw) == ("a\tbA", '"a\\tb\\x41"')
    assert ds_ast.unparse(tree) == source
    value.value = "a\tbB"
    assert ds_ast.unparse(value) == '"a\\tbB"', (
        "a changed value is encoded, never written with the stale spelling")


def test_a_bad_escape_is_a_syntax_error_with_compiles_code(dsc):
    with pytest.raises(DSSyntaxError) as caught:
        ds_ast.parse('const C = "a\\qb"\n', "bad.ds", dsc=dsc)
    assert caught.value.code == "DS_PARSE_BAD_ESCAPE"


def test_a_built_joinedstr_encodes_its_text():
    """Braces in a text part are doubled, so they stay text on the way
    back; quotes, backslashes and controls are escaped."""
    node = JoinedStr([Constant('say "{hi}"\n'), FormattedValue(Name("x"))])
    assert ds_ast.unparse(node) == '"say \\"{{hi}}\\"\\n{x}"'

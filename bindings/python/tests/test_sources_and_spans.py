# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""``Engine.sources`` and ``Engine.line_spans``: the loaded program's sources and spans.

The sources are its source files by module id ([RDSC.14.2]); the spans, each
attributed node's source position by node id ([RDSC.14.3]).
"""

from collections.abc import Mapping

import pytest

import pyds

# The rule is on line 8: its terminal's span names that line.
_SRC = (
    "use default\n"
    "schema Reading scope logical:\n"
    "    zone: String key\n"
    "    celsius: Float mutable\n"
    "schema Alert scope logical:\n"
    "    zone: String key\n"
    "\n"
    "rule too_hot:\n"
    "    Reading r where r.celsius > 30.0\n"
    "->\n"
    '    emit Alert logical zone: "cellar"\n'
)
_RULE_LINE = 8


@pytest.fixture
def eng():
    with pyds.Engine() as e:
        e.load_dsc(pyds.compile(_SRC, file="hot.ds"))
        yield e


def test_an_engine_with_no_program_has_no_sources_or_spans():
    with pyds.Engine() as e:
        assert len(e.sources) == 0
        assert len(e.line_spans) == 0
        assert list(e.sources) == []
        assert list(e.line_spans) == []


def test_the_views_are_mappings(eng):
    assert isinstance(eng.sources, Mapping)
    assert isinstance(eng.line_spans, Mapping)


def test_a_one_module_program_has_one_source_holding_its_text(eng):
    (module_id,) = list(eng.sources)
    source = eng.sources[module_id]
    assert isinstance(source, pyds.ProgramSource)
    assert source.module_id == module_id
    # The path as compile() was given it ([RDSC.14.2.3]), and the original
    # text ([RDSC.14.2.1]).
    assert source.file == "hot.ds"
    assert source.text == _SRC


def test_every_span_is_found_by_its_node_and_names_a_known_module(eng):
    spans = dict(eng.line_spans)
    assert spans, "a rule's nodes carry spans"
    for node_id, span in spans.items():
        assert isinstance(span, pyds.LineSpan)
        assert span.node_id == node_id
        assert eng.line_spans[node_id] == span
        assert span.module_id in eng.sources
        # libds.h: a span's file is its module's display path.
        assert span.file == eng.sources[span.module_id].file
        assert span.line >= 1
        assert span.column >= 1


def test_the_terminal_maps_to_its_rule(eng):
    assert _RULE_LINE in {span.line for span in eng.line_spans.values()}


@pytest.mark.parametrize(
    "key",
    [True, "0", 1.0, -1, 2**32, None],
    ids=["bool", "str", "float", "negative", "too-wide", "None"],
)
def test_a_key_no_node_can_have_is_a_key_error(eng, key):
    with pytest.raises(KeyError):
        eng.line_spans[key]
    assert key not in eng.line_spans


def test_a_node_with_no_span_is_a_key_error(eng):
    absent = max(eng.line_spans) + 1_000
    with pytest.raises(KeyError):
        eng.line_spans[absent]


@pytest.mark.parametrize(
    "key",
    [True, "0", 1.0, -1, 2**32, 1_000_000],
    ids=["bool", "str", "float", "negative", "too-wide", "absent"],
)
def test_a_module_id_the_program_lacks_is_a_key_error(eng, key):
    with pytest.raises(KeyError):
        eng.sources[key]
    assert key not in eng.sources


@pytest.mark.parametrize("view", ["sources", "line_spans"])
def test_a_closed_engine_refuses(view):
    e = pyds.Engine()
    e.close()
    with pytest.raises(ValueError, match="closed Engine"):
        len(getattr(e, view))

# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""How ``pyds.compile``, ``compile_file`` and ``from_source`` take their arguments.

The source comes positionally, everything optional by keyword (PY.6), and a
sequence of paths never as one path.
"""

import inspect

import pytest

import pyds

_SRC = "use default\n\nschema S scope logical:\n    k: Int key\n"


# The suite wraps pyds.compile to add a `use` line (conftest.py); this test
# reads the real function's signature, so it opts out.
@pytest.mark.library_source
@pytest.mark.parametrize(
    ("name", "parameters"),
    [
        ("compile", "(source_text, *, file='<input>', search_path=None, dialect_files=())"),
        ("compile_file", "(path, *, search_path=None, dialect_files=())"),
        ("from_source", "(source_text, *, file='<input>', dialect_files=())"),
    ],
)
def test_only_the_source_is_positional(name, parameters):
    signature = inspect.signature(getattr(pyds, name))
    unannotated = signature.replace(
        parameters=[
            p.replace(annotation=inspect.Parameter.empty) for p in signature.parameters.values()
        ],
        return_annotation=inspect.Signature.empty,
    )
    assert str(unannotated) == parameters


def test_compile_refuses_a_positional_file():
    with pytest.raises(TypeError, match="positional argument"):
        pyds.compile(_SRC, "s.ds")


def test_compile_file_refuses_a_positional_search_path(tmp_path):
    src = tmp_path / "s.ds"
    src.write_text(_SRC, encoding="utf-8")
    with pytest.raises(TypeError, match="positional argument"):
        pyds.compile_file(src, [tmp_path])


def test_from_source_refuses_a_positional_file():
    with pytest.raises(TypeError, match="positional argument"):
        pyds.from_source(_SRC, "s.ds")


@pytest.mark.parametrize("one", ["lib", b"lib"], ids=["str", "bytes"])
def test_one_search_path_instead_of_a_sequence_is_refused(one):
    with pytest.raises(TypeError, match="sequence of paths"):
        pyds.compile(_SRC, search_path=one)

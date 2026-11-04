# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""pyds.Engine is a Python class over the extension's private _Engine."""

import pyds
import pyds._pyds


def test_engine_is_a_python_subclass_of_the_extension_type():
    assert pyds.Engine is not pyds._pyds._Engine
    assert issubclass(pyds.Engine, pyds._pyds._Engine)


def test_the_extension_does_not_export_engine():
    assert not hasattr(pyds._pyds, "Engine")


def test_engine_is_named_where_it_is_imported_from():
    assert pyds.Engine.__module__ == "pyds"
    assert pyds.Engine.__qualname__ == "Engine"


def test_closed_is_false_until_close_and_true_after():
    eng = pyds.Engine()
    assert eng.closed is False
    eng.close()
    assert eng.closed is True
    eng.close()
    assert eng.closed is True


def test_closed_is_true_after_a_with_block():
    with pyds.Engine() as eng:
        assert not eng.closed
    assert eng.closed


def test_repr_says_whether_the_engine_is_closed():
    eng = pyds.Engine()
    assert repr(eng) == "<pyds.Engine>"
    eng.close()
    assert repr(eng) == "<pyds.Engine closed>"


def test_a_clone_is_a_pyds_engine():
    with pyds.Engine() as eng, eng.clone() as copy:
        assert type(copy) is pyds.Engine


def test_a_subclass_clones_to_itself_and_reprs_its_own_name():
    class Recording(pyds.Engine):
        pass

    with Recording() as eng, eng.clone() as copy:
        assert type(copy) is Recording
        assert repr(copy) == f"<{__name__}.{Recording.__qualname__}>"

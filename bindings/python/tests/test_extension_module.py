# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The extension module ``pyds._pyds`` as the import system sees it.

It is built for the 3.12 stable ABI (abi3), loaded by multi-phase
initialisation (PEP 489), and refused to a subinterpreter.
"""

import gc
import importlib.util
import sys
from pathlib import Path

import pytest

import pyds
import pyds._pyds

# The subinterpreter API this test drives: public from 3.14 (PEP 734); on 3.12,
# the interpreter certified, the private module it grew from. 3.13 has
# neither name.
try:
    from concurrent import interpreters
except ImportError:
    interpreters = None
try:
    import _xxsubinterpreters
except ImportError:
    _xxsubinterpreters = None

REFUSED = "does not support loading in subinterpreters"


def test_a_subinterpreter_is_refused_the_extension():
    if interpreters is not None:
        interp = interpreters.create()
        try:
            with pytest.raises(interpreters.ExecutionFailed, match=REFUSED):
                interp.exec("import pyds._pyds")
        finally:
            interp.close()
    elif _xxsubinterpreters is not None:
        interp = _xxsubinterpreters.create()
        try:
            with pytest.raises(_xxsubinterpreters.RunFailedError, match=REFUSED):
                _xxsubinterpreters.run_string(interp, "import pyds._pyds")
        finally:
            _xxsubinterpreters.destroy(interp)
    else:
        pytest.skip("this CPython has neither concurrent.interpreters nor _xxsubinterpreters")


def test_a_second_module_from_the_spec_is_complete():
    spec = pyds._pyds.__spec__
    second = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(second)
    for name in (
        "_Engine",
        "EncodedFact",
        "JsonText",
        "_ADMIT_EITHER",
        "next_atom",
        "build_capabilities",
    ):
        assert hasattr(second, name), name


def test_the_extension_is_built_for_the_stable_abi():
    """The extension is ``*.abi3.so``, as ``limited_api: '3.12'`` in ``meson.build`` makes it.

    Meson names a module built against the limited API ``*.abi3.so``, one any
    CPython from 3.12 loads (PY.16). A build for one interpreter's ABI is
    ``_pyds.cpython-312-<platform>.so``.
    """
    name = Path(pyds._pyds.__file__).name
    assert name.endswith(".abi3.so"), name


def test_a_second_load_adds_the_same_types():
    """A second module from the spec carries the same type objects.

    Each heap type is made at the first exec and kept (engine.c,
    ``pyds_init_engine_type``), so ``pyds.Engine``, which subclasses the first
    ``_Engine``, is still an ``_Engine``. A type made afresh at each exec would
    be a different class with the same name.
    """
    spec = pyds._pyds.__spec__
    second = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(second)
    assert second._Engine is pyds._pyds._Engine
    assert second.JsonText is pyds._pyds.JsonText
    assert second.EncodedFact is pyds._pyds.EncodedFact
    assert issubclass(pyds.Engine, second._Engine)


def test_an_engine_gives_back_its_reference_to_its_type():
    """An engine's dealloc gives back the reference it holds to its type.

    An instance of a heap type holds a reference to its type, and its dealloc
    gives it back, a subclass's included (``PydsEngine_dealloc``). Forgetting
    it leaks one reference to ``pyds.Engine`` per engine, which is the
    difference this counts; giving back one too many would free the class.

    BOTH COUNTS ARE TAKEN OUTSIDE THE ``assert``. pytest rewrites an assert to
    bind each subexpression to a temporary, ``pyds.Engine`` included, so a
    count taken inside one carries a reference of the rewrite's own.
    """
    gc.collect()
    before = sys.getrefcount(pyds.Engine)
    for _ in range(200):
        with pyds.Engine():
            pass
    gc.collect()
    after = sys.getrefcount(pyds.Engine)
    assert after == before


def test_an_encoded_fact_is_still_recognised_after_a_second_load():
    """After a second exec, ``assert_external`` still recognises the first module's EncodedFact.

    Recognised, the junk ``data`` reaches libds, which refuses it with a
    status. Not recognised, the tuple itself is read as a buffer, and that is
    a ``TypeError``.
    """
    spec = pyds._pyds.__spec__
    spec.loader.exec_module(importlib.util.module_from_spec(spec))
    encoded = pyds.EncodedFact(("S", None, b"\x00"))
    with pyds.Engine() as e, pytest.raises(pyds.Error):
        e.assert_external(encoded)

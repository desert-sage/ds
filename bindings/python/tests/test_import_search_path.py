# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Imports resolve through pyds, and a bad one fails loudly.

A library beside the importer is found, and an import of a library that does
not exist is `DS_VALIDATE_UNKNOWN_LIBRARY`, through `pyds.compile()` as through
`dsc`.

The two halves are tested separately on purpose: resolution working does not
imply a bad import is reported.
"""

from __future__ import annotations

import pytest

import pyds

_LIB = """
schema Soc scope logical:
    chip: String key
    sdk: String mutable
"""

# compile_file hands dsc the file, so conftest's `use default` cannot reach
# these sources: each program states its own `use` line.
_IMPORTER = """use default

from board_model import Soc

rule sees_it:
    Soc s where s.sdk == "esp-idf"
->
    log critical "{s.chip}"
"""

_BAD_IMPORT = """use default

from no_such_module_anywhere import NoSuchSchemaHere

rule r:
    NoSuchSchemaHere x
->
    log critical "unreachable"
"""


def _refusal_types() -> tuple[type[BaseException], ...]:
    """Return the exception types that are a refusal, and nothing else.

    `pytest.raises(Exception)` would also accept the RuntimeError pyds raises
    when there is no binary -- a refusal test passing on a lane that compiled
    nothing.
    """
    return (pyds.CompileRefusedError,)


def _refusal_text(err: BaseException) -> str:
    """Return the refusal's rendered diagnostics."""
    assert isinstance(err, pyds.CompileRefusedError)
    return err.diagnostics


def _write(tmp_path, name: str, text: str):
    p = tmp_path / name
    p.write_text(text)
    return p


def test_import_resolves_from_the_files_own_directory(tmp_path):
    """A library beside the importer is found.

    Asserts the schema is actually THERE, not merely that the compile
    succeeded — a successful compile producing zero schemas is precisely the
    reported symptom.
    """
    _write(tmp_path, "board_model.ds", _LIB)
    src = _write(tmp_path, "probe.ds", _IMPORTER)

    eng = pyds.Engine()
    eng.load_dsc(pyds.compile_file(src))

    names = set(eng.schemas)
    # A library schema's own name carries the library's path ([LIMP.13.1]).
    assert "board_model.Soc" in names, (
        f"imported schema missing from the artifact; got {sorted(names)}"
    )


def test_nfct_1_4_2__a_schema_is_found_by_its_own_name(tmp_path):
    """A host names a library's schema by its path and NAME, and by nothing else.

    Path: engine.schemas over ds_engine_schema_find and ds_schema_get_name, with
    an alias on the import, which is a spelling in one source file ([LIMP.13.2]).
    """
    _write(tmp_path, "board_model.ds", _LIB)
    src = _write(
        tmp_path,
        "alias.ds",
        "use default\n\nfrom board_model import Soc as Chip\n\n"
        'rule r:\n    Chip c\n->\n    log info "{c.chip}"\n',
    )

    eng = pyds.Engine()
    eng.load_dsc(pyds.compile_file(src))

    assert eng.schemas["board_model.Soc"].name == "board_model.Soc"
    for other in ("Soc", "Chip", "board_model"):
        assert other not in eng.schemas


def test_unresolvable_import_is_reported_not_ignored(tmp_path):
    """The half that matters more: a typo'd import must not compile clean.

    It named a module that exists nowhere and produced no diagnostic at all —
    so a ruleset split across files compiled to an artifact missing everything
    the imports were meant to bring, with a successful exit code.
    """
    src = _write(tmp_path, "bad.ds", _BAD_IMPORT)

    with pytest.raises(_refusal_types()) as exc:
        pyds.compile_file(src)

    msgs = _refusal_text(exc.value)
    assert "no_such_module_anywhere" in msgs, (
        f"the errors do not name the unresolvable module: {msgs}"
    )


def test_explicit_empty_search_path_still_reports(tmp_path):
    """Opting out of the directory default must not restore the silence.

    `search_path=()` is a legitimate request to search nowhere; it is not a
    request to pretend the import succeeded.
    """
    _write(tmp_path, "board_model.ds", _LIB)
    src = _write(tmp_path, "probe.ds", _IMPORTER)

    with pytest.raises(_refusal_types()) as exc:
        pyds.compile_file(src, search_path=())

    msgs = _refusal_text(exc.value)
    assert "board_model" in msgs, msgs

# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""compile_file carries the program's own companion ``.dstest`` ([LTSL.2.4]).

A compile carries the tests of every module it compiles, each module's
companion ``<stem>.dstest`` beside it included. ``compile_file`` once piped
the file's text to ``dsc compile -``. Text on stdin has no directory, so the
program's own companion was never read, while a library's, read off ``-L`` as
a file, was. Each test reads the artefact with ``pyds.atoms``, libds's
framing, and the generated messages, and joins each ``TestCase`` to its
module's ``DsSource`` by ``module_id``.
"""

from pathlib import Path

import pyds
from pyds import AtomKind, atoms

# A library, found beside the program on compile_file's default search path.
_ALPHA = """\
schema Ping scope logical:
    id: Int key

schema Pong scope logical:
    id: Int key

rule answer:
    Ping p
->
    emit Pong logical id: p.id
"""

_ALPHA_TEST = """\
test "alpha answers":
    inputs:
        at 0_s:
            Ping id: 1
    produces:
        emitted Pong o where o.id == 1
"""

_MAIN = """\
use default

import alpha

schema Tick scope logical:
    id: Int key

schema Tock scope logical:
    id: Int key

rule tock:
    Tick p
->
    emit Tock logical id: p.id
"""

_MAIN_TEST = """\
test "main answers":
    inputs:
        at 0_s:
            Tick id: 2
    produces:
        emitted Tock o where o.id == 2
"""


def _project(tmp_path: Path) -> Path:
    """Write ``main.ds`` and ``alpha.ds``, each with its companion; return ``main.ds``."""
    (tmp_path / "alpha.ds").write_text(_ALPHA, encoding="utf-8")
    (tmp_path / "alpha.dstest").write_text(_ALPHA_TEST, encoding="utf-8")
    main = tmp_path / "main.ds"
    main.write_text(_MAIN, encoding="utf-8")
    (tmp_path / "main.dstest").write_text(_MAIN_TEST, encoding="utf-8")
    return main


def _cases(dsc: bytes) -> list[tuple[str, str]]:
    """Return each TestCase's name and its module's DsSource file, in artefact order."""
    found = list(atoms.iter_atoms(dsc))
    sources = [a.message() for a in found if a.kind is AtomKind.DS_SOURCE]
    files = {s.module_id: s.file for s in sources}
    cases = [a.message() for a in found if a.kind is AtomKind.TEST_CASE]
    assert all(c.module_id in files for c in cases), (cases, files)
    return [(c.name, files[c.module_id]) for c in cases]


def test_ltsl_2_4__compile_file_carries_the_programs_own_companion(tmp_path):
    """The program's companion test is in the artefact, under the program's module_id.

    Path: compile_file runs ``dsc compile <path>``, so dsc reads ``main.ds``
    from disk and its companion ``main.dstest`` beside it. The library's
    companion comes as before, off the search path.
    """
    main = _project(tmp_path)
    cases = _cases(pyds.compile_file(main))
    want = [("alpha answers", "alpha.ds"), ("main answers", "main.ds")]
    assert sorted((name, Path(file).name) for name, file in cases) == want, cases
    # The artefact names the program as compile_file was given it ([RDSC.14.2.3]).
    assert ("main answers", str(main)) in cases, cases


def test_ltsl_2_4__source_as_text_has_no_companion(tmp_path):
    """``pyds.compile`` on the same text carries the library's companion and not the program's.

    So the test above is seen to tell the two apart: text has no directory
    for a companion to sit in.
    """
    main = _project(tmp_path)
    cases = _cases(
        pyds.compile(main.read_text(encoding="utf-8"), file=str(main), search_path=[tmp_path])
    )
    assert [name for name, _ in cases] == ["alpha answers"], cases


def test_compile_file_takes_a_relative_path_that_starts_with_a_dash(tmp_path, monkeypatch):
    """A relative path beginning with ``-`` is compiled as a file, not read as an option."""
    monkeypatch.chdir(tmp_path)
    Path("-prog.ds").write_text(
        "use default\n\nschema S scope logical:\n    k: Int key\n", encoding="utf-8"
    )
    eng = pyds.Engine()
    eng.load_dsc(pyds.compile_file("-prog.ds"))
    assert "S" in set(eng.schemas)

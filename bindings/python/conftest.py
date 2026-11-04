# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The pyds suite's pytest configuration: test sources compile as programs.

No test is marked to fail as expected: a failure is fixed or filed, never
recorded as expected, and a gate fails on a mark.
"""

import re

import pytest

# The package source is under src/, so nothing here can shadow the installed
# pyds: the suite imports the pyds a user gets.


# --- A test source with no `use` line is compiled under `use default` ---
# A file with no `use` line is a library ([LDIA.2.10.1]), and dsc refuses to
# build one ([LDIA.2.10.8]). A test harness compiles such an input as though
# it began with `use default`. This is that rule, as the language
# harness applies it (specs/conformance/harness/runner.py, as_program), for the
# sources these tests hand to pyds.compile and from_source. compile_file hands
# dsc the file itself ([LTSL.2.4]), so no text passes through here: a
# file a test compiles with it states its own `use` line.
#
# It wraps pyds.compile for the whole session, so that module- and
# session-scoped fixtures, which run before any per-test fixture, see it too. A
# test that is ABOUT what pyds.compile does with a library opts out with
# @pytest.mark.library_source, which restores the unwrapped function for that
# test. Positions in a source the wrapper changed are one line later than the
# source's own, so a test that checks a position states its own `use` line.
_USE_LINE = re.compile(r"^use\b", re.MULTILINE)


def pytest_configure(config):
    """Register the ``library_source`` marker."""
    config.addinivalue_line(
        "markers", "library_source: compile test sources as given, with no `use default` added"
    )


@pytest.fixture(scope="session", autouse=True)
def _test_sources_are_programs():
    import pyds

    compile_as_given = pyds.compile

    def compile(source_text, *args, **kwargs):
        if not _USE_LINE.search(source_text):
            source_text = "use default\n" + source_text
        return compile_as_given(source_text, *args, **kwargs)

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(pyds, "compile", compile)
        yield compile_as_given


@pytest.fixture(autouse=True)
def _library_source(request, monkeypatch, _test_sources_are_programs):
    if request.node.get_closest_marker("library_source"):
        import pyds

        monkeypatch.setattr(pyds, "compile", _test_sources_are_programs)

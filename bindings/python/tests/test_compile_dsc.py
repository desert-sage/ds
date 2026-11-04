# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`pyds.compile` is the `dsc` binary: source in on stdin, artefact out on stdout.

That is `dsc compile - -o -`.

Pins the contract's edges: a missing binary is a RuntimeError, not a refusal; a
refused source is a CompileRefusedError carrying the diagnostic code; `file` reaches
the artefact as its label; a `realtime` source is refused, real time not being
in this edition.
"""

import pytest

import pyds

_SRC = "schema S scope logical:\n    k: Int key\n"


def test_without_a_binary_it_is_a_runtime_error(monkeypatch):
    monkeypatch.setenv("DS_MERCURY_DSC", "/nonexistent/dsc_cli")
    with pytest.raises(RuntimeError, match="DS_MERCURY_DSC"):
        pyds.compile(_SRC)


def test_it_compiles_to_an_artefact_libds_loads():
    eng = pyds.Engine()
    eng.load_dsc(pyds.compile(_SRC, file="s.ds"))
    eng.assert_("S", k=1)
    assert len(eng.facts) == 1


def test_a_refusal_is_compile_refused_with_its_code():
    # `bogus` is not a declaration keyword, so the front end stops.
    with pytest.raises(pyds.CompileRefusedError) as info:
        pyds.compile("bogus Thing\n", file="bad.ds")
    assert "DS_PARSE" in info.value.diagnostics
    assert "bad.ds" in info.value.diagnostics


def test_file_labels_the_diagnostics():
    # The label is what the refusal cites, so a label that did not reach the
    # compiler reads `<stdin>` here.
    with pytest.raises(pyds.CompileRefusedError) as info:
        pyds.compile("bogus Thing\n", file="named_by_the_caller.ds")
    assert "named_by_the_caller.ds" in info.value.diagnostics


def test_a_rule_the_compiler_cannot_lower_is_refused():
    # RLOW.1.6: `dsc` refuses rather than writing an artefact without
    # the rule, so the exit status says so and nothing here reads stderr for
    # it. `fact::Json` has no defined shape and stays unlowered in 1.0.0;
    # this pins `LCST.4.5_fact_to_json_ok`'s source through pyds.
    src = (
        "schema Sample scope logical:\n    x: String key\n\n"
        "schema Out scope ttl 1_h:\n    payload: Json\n\n"
        "rule r:\n    Sample s\n->\n    emit Out payload: s::Json\n"
    )
    with pytest.raises(pyds.CompileRefusedError) as info:
        pyds.compile(src, file="unlowered.ds")
    assert "DS_VALIDATE_RULE_NOT_LOWERED" in info.value.diagnostics


def test_a_realtime_source_is_refused():
    # [LCAP.2.1.5]: `realtime` is not part of this edition, so `use realtime`
    # is refused at its `use` line, before any contract could matter.
    src = "use realtime\n\n" + _SRC
    with pytest.raises(pyds.CompileRefusedError) as info:
        pyds.compile(src, file="rt.ds")
    assert "DS_VALIDATE_REALTIME_DEFERRED" in info.value.diagnostics


@pytest.mark.library_source
def test_a_source_with_no_use_line_is_a_library_and_is_refused():
    # [LDIA.2.10.1]: no `use` line makes a file a library, and dsc refuses to
    # build one ([LDIA.2.10.8]). Marked so the suite's `use default` is not
    # added: this is what pyds.compile itself does with such a source.
    with pytest.raises(pyds.CompileRefusedError) as info:
        pyds.compile(_SRC, file="lib.ds")
    assert "DS_VALIDATE_NOT_A_PROGRAM" in info.value.diagnostics

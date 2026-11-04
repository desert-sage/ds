# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The fault funnel reaches a Python harness — [NCBK.2.8] through pyds.

`src/engine.c` gained the four fault kinds and their payloads so that "a harness
can observe them". Nothing in Python asked: `test_fault_emission.c` drives the
Rete network directly, building alfa/beta/term atoms by hand, which is the right
shape for classification but says nothing about the pyds seam — the kind NAME
and the payload DICT are written there and were reached by no test at all.

The gap is the ordinary shape of untested C: it is 60 lines that compile, and a
mistake in them (a mis-spelled kind name, a payload key set on the wrong branch,
an enum going over as something other than its proto number) is invisible until
someone writes a fixture against it, which is what a harness observing faults
would be.

DRIVEN FROM DS SOURCE, not from a hand-built network, because that is the seam
under test: a program an author could write, compiled by the real compiler,
loaded by the real engine, observed through `Engine.on_event`.

WHY DIVISION BY A SLOT rather than by a literal: `x // 0` is a COMPILE error
(`DS_VALIDATE_DIV_BY_ZERO`, [LEXP.10.2.2]), so a literal zero never reaches the
runtime that traps on it. Dividing by a slot whose value happens to be zero is
the reachable form, and it is also the realistic one.

WHY `//` AND NOT `/`: true division always yields Float ([LEXP.7.4]), so `/`
into an `Int` slot is a type mismatch and the program never compiles — the
runtime trap is unreachable through it. `//` is the integer division the C test
drives as `DS_RETE_BINOP_IDIV`, and it is the operator an author writing into an
`Int` slot would reach for anyway.
"""

import dataclasses

import pyds

_DIVIDE = (
    "schema Src scope logical:\n"
    "    id: String key\n"
    "    n: Int mutable\n"
    "    d: Int mutable\n"
    "\n"
    "schema Out scope logical:\n"
    "    id: String key\n"
    "    q: Int mutable\n"
    "\n"
    "rule divide:\n"
    "    Src s\n"
    "->\n"
    "    emit Out logical id: s.id q: (s.n // s.d)\n"
)


def _run(src: str, **slots) -> list[pyds.events.Event]:
    """Assert one `Src`, pump, and return the stream events."""
    eng = pyds.Engine()
    eng.load_dsc(pyds.compile(src, file="test.ds"))
    events: list[pyds.events.Event] = []
    eng.on_event = events.append
    eng.assert_("Src", **slots)
    eng.pump()
    return events


def test_a_zero_divisor_reaches_the_harness_as_computation_error():
    """A fault arrives with its kind NAME, which `pyds_event_to_dict` adds.

    Before it, every fault arrived as `unknown` and no fixture could name one.
    """
    events = _run(_DIVIDE, id="a", n=7, d=0)
    kinds = [e.kind for e in events]
    assert pyds.EventKind.COMPUTATION_ERROR in kinds, kinds


def test_the_computation_error_payload_names_the_trap_and_the_rule():
    """The payload, the other half, names the trap and the rule.

    `trap_kind` is the proto's TrapKind, and the rule name is what makes the
    event actionable.
    """
    (ce,) = [
        e for e in _run(_DIVIDE, id="a", n=7, d=0) if isinstance(e, pyds.events.ComputationError)
    ]
    assert ce.trap_kind is pyds.TrapKind.DIVIDE_BY_ZERO, ce
    assert ce.rule_name == "divide", ce
    # Present on every computation_error, and absence is what `None` means —
    # naming the FIELDS separately from their values keeps a payload that
    # silently stopped carrying one from passing on the two it still has.
    fields = {f.name for f in dataclasses.fields(ce)}
    assert fields >= {"timetag", "schema_name", "slot_name", "fact_id", "node_id"}


def test_a_fault_does_not_fail_the_pump():
    """Abandonment is per ACTIVATION, so the pump completes ([LERR.1] rungs 5/6).

    That is the property that makes a fault observable rather than fatal.
    """
    events = _run(_DIVIDE, id="a", n=7, d=0)
    assert events, "no events at all — the pump did not run"


def test_the_faulted_activation_commits_nothing():
    """The `emit` whose value faulted produces no fact.

    That is the claim the C test makes about abandonment, seen from outside. A
    zero delta here would be ambiguous if the rule never fired, so the control
    below pins that it does.
    """
    eng = pyds.Engine()
    eng.load_dsc(pyds.compile(_DIVIDE, file="test.ds"))
    eng.assert_("Src", id="a", n=7, d=0)
    eng.pump()
    # Out was abandoned. The fault itself is a fact.
    assert eng.facts.of("Out") == []
    assert [f.slots["rule"] for f in eng.facts.of("ComputationError")] == ["divide"]


def test_the_fault_is_a_fact_a_rule_matches():
    """A trap leaves one ComputationError fact, and a rule that matches it fires.

    The fact is keyed on (node, rule), and its stream event names the rule.
    """
    src = _DIVIDE + (
        "\n"
        "rule handler:\n"
        '    ComputationError e where e.rule == "divide"\n'
        "->\n"
        '    log info "handled {e.kind}"\n'
    )
    eng = pyds.Engine()
    eng.load_dsc(pyds.compile(src, file="test.ds"))
    logs: list[str] = []
    eng.on_log = lambda r: logs.append(r.message)
    events: list[pyds.events.Event] = []
    eng.on_event = events.append
    eng.assert_("Src", id="a", n=7, d=0)
    eng.pump()
    assert logs == ["handled DIVIDE_BY_ZERO"]
    [fault] = eng.facts.of("ComputationError")
    assert fault.slots["kind"] == "DIVIDE_BY_ZERO"
    assert [e.rule_name for e in events if isinstance(e, pyds.events.ComputationError)] == [
        "divide"
    ]
    # Both fault schemas are in every artefact, whatever the program declares.
    assert "TypeError" in eng.schemas


def test_the_control_fires_and_emits():
    """With a non-zero divisor the same program emits its fact and records NO fault.

    So the assertions above are about the fault and not about a rule that
    never ran ([STYL.5.10.5]).
    """
    events = _run(_DIVIDE, id="a", n=7, d=7)
    faults = [e.kind for e in events if e.kind.endswith("_error")]
    assert faults == [], faults

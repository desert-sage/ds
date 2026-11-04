# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""``Engine.set_admission``: which settings of a capability an engine admits ([NLFC.10.2]).

The admission applies to what the engine loads later.
"""

import pytest

import pyds
from pyds import Admission, Capability

# A program whose `call` setting is true: it calls a service.
_CALLS = """
schema Reading scope logical:
    id: String key

service svc.ping:
    kwarg id: String
    no response

rule ping:
    Reading r
->
    call svc.ping id: r.id nocooldown
"""


@pytest.fixture(scope="module")
def calls_dsc():
    return pyds.compile(_CALLS)


def test_admission_is_libds_s_three_policies():
    assert [(m.name, m.value) for m in Admission] == [
        ("EITHER", 0),
        ("TRUE_ONLY", 1),
        ("FALSE_ONLY", 2),
    ]


def test_a_load_the_policy_does_not_admit_is_refused(calls_dsc):
    """The refusal is a failed load, so it spends the engine ([RDSC.9.8]).

    ``halted`` is ``EngineFault.UNSPECIFIED``: no ``EngineError`` was raised.
    A read of the rules is refused rather than answered.
    """
    with pyds.Engine() as eng:
        eng.set_admission(Capability.CALL, Admission.FALSE_ONLY)
        with pytest.raises(pyds.ArtefactMismatchError) as caught:
            eng.load_dsc(calls_dsc)
        assert caught.value.status is pyds.Status.BND_DIALECT_MISMATCH
        assert eng.halted is pyds.EngineFault.UNSPECIFIED
        with pytest.raises(pyds.Error) as spent:
            len(eng.rules)
        assert spent.value.status is pyds.Status.ENGINE_HALTED


@pytest.mark.parametrize("admission", [Admission.TRUE_ONLY, Admission.EITHER])
def test_a_load_the_policy_admits_loads(calls_dsc, admission):
    with pyds.Engine() as eng:
        eng.set_admission(Capability.CALL, admission)
        eng.load_dsc(calls_dsc)
        assert "ping" in eng.rules


def test_either_lifts_a_policy_set_before_it(calls_dsc):
    with pyds.Engine() as eng:
        eng.set_admission(Capability.CALL, Admission.FALSE_ONLY)
        eng.set_admission(Capability.CALL, Admission.EITHER)
        eng.load_dsc(calls_dsc)
        assert "ping" in eng.rules


def test_a_plain_int_naming_a_member_is_taken(calls_dsc):
    with pyds.Engine() as eng:
        eng.set_admission(int(Capability.CALL), int(Admission.FALSE_ONLY))
        with pytest.raises(pyds.ArtefactMismatchError):
            eng.load_dsc(calls_dsc)


@pytest.mark.parametrize(
    "capability, admission",
    [
        ("call", Admission.EITHER),
        (True, Admission.EITHER),
        (Capability.CALL, "false_only"),
        (Capability.CALL, 1.0),
    ],
    ids=["str-capability", "bool-capability", "str-admission", "float-admission"],
)
def test_a_value_that_is_not_an_int_is_a_type_error(capability, admission):
    with pyds.Engine() as eng, pytest.raises(TypeError):
        eng.set_admission(capability, admission)


@pytest.mark.parametrize(
    "capability, admission",
    [
        (999, Admission.EITHER),
        (Capability.CALL, 7),
    ],
    ids=["capability", "admission"],
)
def test_a_number_no_member_has_is_a_value_error(capability, admission):
    with pyds.Engine() as eng, pytest.raises(ValueError):
        eng.set_admission(capability, admission)


def test_the_arguments_are_positional_only():
    with pyds.Engine() as eng, pytest.raises(TypeError):
        eng.set_admission(
            capability=Capability.CALL,  # type: ignore[call-arg]
            admission=Admission.EITHER,
        )


def test_a_closed_engine_refuses():
    eng = pyds.Engine()
    eng.close()
    with pytest.raises(ValueError, match="closed Engine"):
        eng.set_admission(Capability.CALL, Admission.EITHER)

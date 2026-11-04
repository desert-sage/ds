# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""NLFC.9.6's last sentence through pyds: text before state.

A seed's JSON text is judged as text before the engine's state.
[LSTR.8.5] judges JSON text a host hands the engine in three steps -- its limit
(DS_ERR_JSON_LIMIT), its encoding (DS_ERR_ENCODING), its parse (DS_ERR_PARSE)
-- and only text that passes all three becomes the value [NLFC.9.6]'s order
judges. So a refusal of the text comes before step 1, a halted engine, and
before step 2, the closed seeding window.

Each case has a control: the same engine, valid text, answering its state. A
case that answered the state whatever the text would fail its own assertion,
and one that refused the text whatever the state would fail the control.

pyds takes a `Json` slot as a Python value, never as text (a str is a JSON
string), so [NFCT.2.11]'s sentence has no pyds surface; @ds-lang/ds holds it
(engine.test.mjs).
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

import pyds

_SEAL = Path(__file__).resolve().parents[3] / "specs" / "conformance" / "harness" / "dsc_seal.py"
_spec = importlib.util.spec_from_file_location("dsc_seal", _SEAL)
_dsc_seal = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_dsc_seal)

# The halt test_binding_contracts.py reaches on purpose: an artefact that lies.
# The rule does arithmetic on the Int slot `lied`, and the `.dsc` is edited so
# the slot's Slot atom declares String: ARTEFACT_LIED, an EngineError, a halt.
_HALTS = """
schema P scope logical:
    id: Int key
    lied: Int mutable

rule halt:
    P p where p.lied + 1 > 0
->
    log info "never"
"""

_SLOT_INT = b"\x12\x04lied\x18\x01"
_SLOT_STRING = b"\x12\x04lied\x18\x03"

# [LGRA.5.8.6]'s text limit is 24576 bytes (test_json_runtime.py holds the
# boundary); this is one past it.
_OVER = "0" + " " * 24_576
_ILL = b'"\xc0\xaf"'  # an overlong form: no UTF-8
_VALID = "1"
_MALFORMED = "{not json"


def _halted() -> pyds.Engine:
    """Return an engine whose latch is set, the halt raised by its own assert."""
    dsc = pyds.compile(_HALTS, file="halts.ds")
    assert dsc.count(_SLOT_INT) == 1, "the Slot atom for `lied` is not where this test expects it"
    eng = pyds.Engine()
    eng.load_dsc(_dsc_seal.seal(dsc.replace(_SLOT_INT, _SLOT_STRING)))
    with pytest.raises(pyds.Error) as caught:
        eng.assert_("P", id=1, lied="x")
        eng.pump()
    assert caught.value.status is pyds.Status.ENGINE_HALTED
    assert eng.halted is not None
    return eng


def _window_closed() -> pyds.Engine:
    """Return an engine past its first stream event, not halted."""
    eng = pyds.from_source("schema Q scope logical:\n    id: Int key\n")
    eng.assert_("Q", id=1)
    assert eng.halted is None
    return eng


def _seed_status(eng: pyds.Engine, value) -> pyds.Status:
    with pytest.raises(pyds.Error) as caught:
        eng.cache.seed("k", value)
    return caught.value.status


# @spec [NLFC.9.6]
def test_nlfc_9_6__halted_engine_control_valid_text_is_halted():
    """The control: valid text on a halted engine answers step 1."""
    assert _seed_status(_halted(), _VALID) is pyds.Status.ENGINE_HALTED


# @spec [NLFC.9.6]
@pytest.mark.parametrize(
    ("text", "status"),
    [
        (_MALFORMED, pyds.Status.PARSE),
        (_ILL, pyds.Status.ENCODING),
        (_OVER, pyds.Status.JSON_LIMIT),
    ],
    ids=["malformed", "ill_formed", "over_limit"],
)
def test_nlfc_9_6__text_refusal_before_halted_engine(text, status):
    """Text that fails one of its three steps is refused for the text, not the halt.

    Break: call ds_engine_cache_seed before judging the text (a parse inside
    the engine, after its halt check), and each answers ENGINE_HALTED.
    """
    assert _seed_status(_halted(), text) is status


# @spec [NLFC.9.6]
def test_nlfc_9_6__closed_window_control_valid_text_is_state():
    """The control: valid text past the first stream event answers step 2."""
    assert _seed_status(_window_closed(), _VALID) is pyds.Status.STATE


# @spec [NLFC.9.6]
def test_nlfc_9_6__malformed_text_before_closed_window():
    """Malformed text past the first stream event is the parse, not the window."""
    assert _seed_status(_window_closed(), _MALFORMED) is pyds.Status.PARSE


# @spec [NLFC.9.6]
@pytest.mark.parametrize(
    ("text", "status"),
    [
        (_ILL + b" " * 24_576, pyds.Status.JSON_LIMIT),
        (b"{\xc0\xaf", pyds.Status.ENCODING),
    ],
    ids=["over_limit_and_ill_formed", "ill_formed_and_malformed"],
)
def test_nlfc_9_6__the_text_steps_in_their_order(text, status):
    """The text's own order, on a halted engine: limit, then encoding, then parse."""
    assert _seed_status(_halted(), text) is status

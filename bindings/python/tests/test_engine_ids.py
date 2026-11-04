# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""An engine's run id and tier id ([NLFC.1.2]).

They are given at construction, read back as ``run_id`` and ``tier_id``,
carried by the session header, and kept by a clone.
"""

import pytest

import pyds


def test_an_engine_given_no_ids_has_none():
    with pyds.Engine() as eng:
        assert eng.run_id is None
        assert eng.tier_id is None


def test_the_ids_it_was_given_are_read_back():
    with pyds.Engine(run_id="run-ü-7", tier_id="edge") as eng:
        assert eng.run_id == "run-ü-7"
        assert eng.tier_id == "edge"


def test_the_session_header_carries_the_ids():
    with pyds.Engine(run_id="run-7", tier_id="edge") as eng:
        header = eng.session_header
        assert (header.session_id, header.tier_id) == ("run-7", "edge")


def test_an_empty_id_is_no_id():
    with pyds.Engine(run_id="", tier_id="") as eng:
        assert eng.run_id is None
        assert eng.tier_id is None


def test_a_clone_keeps_its_sources_ids():
    with pyds.Engine(run_id="run-7", tier_id="edge") as eng, eng.clone() as copy:
        assert (copy.run_id, copy.tier_id) == ("run-7", "edge")


def test_the_ids_are_keyword_only():
    with pytest.raises(TypeError):
        pyds.Engine("run-7")  # type: ignore[call-arg]


@pytest.mark.parametrize("name", ["run_id", "tier_id"])
@pytest.mark.parametrize("value", [7, b"edge"], ids=["int", "bytes"])
def test_an_id_that_is_not_a_str_is_a_type_error(name, value):
    with pytest.raises(TypeError):
        pyds.Engine(**{name: value})


@pytest.mark.parametrize("name", ["run_id", "tier_id"])
def test_an_id_holding_a_nul_is_a_value_error(name):
    with pytest.raises(ValueError, match="null character"):
        pyds.Engine(**{name: "run\0id"})


# @spec [NLFC.1.2]
@pytest.mark.parametrize("name", ["run_id", "tier_id"])
def test_an_id_holding_a_lone_surrogate_is_refused_before_libds(name):
    """An id holding a lone surrogate is refused before libds is called.

    A str with a lone surrogate has no UTF-8 form, so pyds cannot hand libds
    the bytes [NLFC.1.2] requires: encoding it for the call raises
    UnicodeEncodeError, and no engine is made. libds refuses the bytes
    themselves with DS_ERR_ENCODING (test_fact_stamps.c).
    """
    with pytest.raises(UnicodeEncodeError):
        pyds.Engine(**{name: "r\ud800"})


@pytest.mark.parametrize("name", ["run_id", "tier_id"])
def test_reading_an_id_of_a_closed_engine_is_a_value_error(name):
    eng = pyds.Engine(run_id="run-7", tier_id="edge")
    eng.close()
    with pytest.raises(ValueError, match="closed Engine"):
        getattr(eng, name)

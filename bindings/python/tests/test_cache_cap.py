# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`Engine.cache.set_cap` bounds the engine-owned cache.

libds refuses a cache write past either bound with DS_ERR_CONTRACT_BREACH and
changes nothing. `cache.seed` is a cache write that reports straight to the
caller, so these tests drive the bounds through it, as @ds-lang/ds's
`setCacheCap` test does.
"""

from __future__ import annotations

import pytest

import pyds

_SRC = """\
schema Trig scope logical:
    v: Int key

rule remember:
    Trig t
->
    cache key: "last" value: t.v
"""


def _engine(**caps: int) -> pyds.Engine:
    eng = pyds.Engine()
    eng.cache.set_cap(**caps)
    eng.load_dsc(pyds.compile(_SRC, file="cap.ds"))
    return eng


def test_a_key_past_the_key_cap_is_a_contract_breach_and_changes_nothing():
    eng = _engine(keys=1)
    eng.cache.seed("a", "1")
    with pytest.raises(pyds.ContractError) as caught:
        eng.cache.seed("b", "2")
    assert caught.value.status is pyds.Status.CONTRACT_BREACH
    eng.cache.seed("a", "3")  # the one key, upserted, is within the cap


def test_a_value_past_the_byte_cap_is_a_contract_breach():
    eng = _engine(bytes=4)
    eng.cache.seed("a", "1")
    with pytest.raises(pyds.ContractError) as caught:
        eng.cache.seed("b", '"a value far longer than four bytes"')
    assert caught.value.status is pyds.Status.CONTRACT_BREACH


def test_zero_is_unbounded():
    eng = _engine(keys=0, bytes=0)
    for i in range(64):
        eng.cache.seed(f"k{i}", str(i))


def test_the_bounds_are_keyword_only():
    eng = pyds.Engine()
    with pytest.raises(TypeError):
        eng.cache.set_cap(1)  # type: ignore[misc]


def test_the_ttl_is_keyword_only():
    eng = pyds.Engine()
    with pytest.raises(TypeError):
        eng.cache.seed("a", "1", 5)  # type: ignore[misc]


def test_the_old_names_are_gone():
    eng = pyds.Engine()
    for name in ("cache_seed", "set_cache_cap", "set_wm_max"):
        assert not hasattr(eng, name), name

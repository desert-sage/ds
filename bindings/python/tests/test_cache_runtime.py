# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for the LGRA cache action.

`cache key: <expr> value: <expr> ttl: <dur>` calls the
integrator's cache_set callback with the resolved key + value
+ TTL. The cache_get / cache_delete paths route through the
matching callbacks.
"""

import pyds

_CACHE_SET = """
schema Trig scope logical:
    v: Int key

rule cache_value:
    Trig t
->
    cache key: "last" value: t.v
"""


def test_cache_set_callback_receives_key_and_value():
    """A `cache key: ... value: ...` action invokes the cache_set callback.

    Its positional args are (key, value_json, ttl_ns).
    """
    eng = pyds.from_source(_CACHE_SET)
    sets: list[tuple] = []
    eng.on_cache_set = lambda key, value_json, ttl_ns: sets.append((key, value_json, ttl_ns))

    eng.assert_("Trig", v=42)
    eng.pump()

    assert len(sets) == 1, f"expected 1 cache_set, got {sets!r}"
    key, value_json, _ttl_ns = sets[0]
    assert key == "last", f"unexpected key: {sets[0]!r}"
    # value_json is the JSON-serialised value; integer 42 serialises as "42".
    assert value_json == "42", f"unexpected value: {sets[0]!r}"


_CACHE_TTL = """
schema Trig scope logical:
    v: Int key

rule cache_with_ttl:
    Trig t
->
    cache key: "last" value: t.v ttl: 5_min
"""


def test_cache_set_callback_receives_ttl_when_specified():
    """`ttl: 5_min` threads a 5*60*1e9 ns ttl into the callback."""
    eng = pyds.from_source(_CACHE_TTL)
    sets: list[tuple] = []
    eng.on_cache_set = lambda key, value_json, ttl_ns: sets.append((key, value_json, ttl_ns))

    eng.assert_("Trig", v=42)
    eng.pump()

    assert len(sets) == 1, f"got {sets!r}"
    assert sets[0][2] == 5 * 60 * 1_000_000_000, f"expected 5min in ns, got {sets[0]!r}"

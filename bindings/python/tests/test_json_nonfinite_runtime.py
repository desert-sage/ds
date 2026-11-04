# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A non-finite Float forced into the JSON data plane is a hard error.

`Inf` is a *valid* value in working memory (only NaN is rejected at assert),
but "inf" is not valid JSON. So the moment an `Inf` Float is forced into a JSON
data-plane body — the `cache` value — the verb is a hard error: the write is
suppressed (no invalid `inf` token reaches the wire) and
`ds.json.nonfinite_total{verb}` increments (DS_ERR_JSON_NONFINITE, -217).

A finite Float still serializes cleanly through the same verb — the guard is
non-finite-only. A `call`'s arguments are typed rather than JSON, so
the guard does not reach them: an `Inf` kwarg is issued.
"""

import math

import pyds


def _nonfinite_metrics(metrics):
    return [m for m in metrics if m.name == "ds.json.nonfinite_total"]


# ---- cache value (ds_json_value, verb="cache") ----------------------------

_CACHE = """
schema Reading scope logical:
    id: String key
    x: Float mutable

rule cache_x:
    Reading r
->
    cache key: "last" value: r.x
"""


def test_cache_inf_value_suppressed_and_counted():
    """An Inf cache value suppresses the cache_set and counts the metric."""
    eng = pyds.from_source(_CACHE)
    sets: list[tuple] = []
    metrics: list[pyds.events.Metric] = []
    eng.on_cache_set = lambda key, value_json, ttl_ns: sets.append((key, value_json))
    eng.on_metric = metrics.append

    eng.assert_("Reading", id="a", x=math.inf)
    eng.pump()

    assert sets == [], f"cache_set must be suppressed for Inf, got {sets!r}"
    hits = _nonfinite_metrics(metrics)
    assert len(hits) == 1, f"expected one nonfinite metric, got {metrics!r}"
    assert hits[0].labels.get("verb") == "cache", hits[0]
    assert hits[0].kind is pyds.MetricKind.COUNTER, hits[0]


def test_cache_finite_value_still_serializes():
    """A finite Float still writes cleanly through the same verb."""
    eng = pyds.from_source(_CACHE)
    sets: list[tuple] = []
    metrics: list[pyds.events.Metric] = []
    eng.on_cache_set = lambda key, value_json, ttl_ns: sets.append((key, value_json))
    eng.on_metric = metrics.append

    eng.assert_("Reading", id="a", x=1.5)
    eng.pump()

    assert sets == [("last", "1.5")], f"finite Float must serialize, got {sets!r}"
    assert _nonfinite_metrics(metrics) == [], "no metric for a finite value"


# ---- call arguments: typed, so an Inf is issued ---------------------------

_CALL = """
service ev.put:
    kwarg entity: String
    kwarg val: Float
    no response

schema Reading scope logical:
    id: String key
    x: Float mutable

rule put:
    Reading r
->
    call ev.put entity: r.id val: r.x nocooldown
"""


def test_an_inf_kwarg_is_issued_with_its_value():
    """An Inf Float kwarg is issued, and the callback receives it as an inf float.

    Nothing is suppressed or counted.
    """
    eng = pyds.from_source(_CALL)
    calls: list = []
    metrics: list[pyds.events.Metric] = []
    eng.set_call_callback(calls.append)
    eng.on_metric = metrics.append

    eng.assert_("Reading", id="a", x=math.inf)
    eng.pump()

    assert [c["args"] for c in calls] == [{"entity": "a", "val": math.inf}], calls
    assert _nonfinite_metrics(metrics) == [], "no metric for a typed argument"

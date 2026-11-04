# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""An engine collected without ``close()`` is freed, and a ``ResourceWarning`` names it.

That is what an unclosed file or socket does (PY.4).
"""

import gc
import warnings

import pytest

import pyds


def _resource_warnings_while_collecting(drop):
    """Return the ResourceWarnings raised while ``drop()`` runs and the collector finishes.

    They are recorded rather than raised: a warning made an error inside a
    finalizer goes to sys.unraisablehook, not to the test. Collecting first
    frees what earlier tests left, so only ``drop()``'s engine is counted.
    """
    gc.collect()
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        drop()
        gc.collect()
    return [w for w in caught if issubclass(w.category, ResourceWarning)]


def test_an_engine_collected_unclosed_warns():
    held = [pyds.Engine()]
    (warning,) = _resource_warnings_while_collecting(held.clear)
    assert str(warning.message) == "unclosed <pyds.Engine>"


def test_an_unclosed_engine_in_a_cycle_warns_when_the_collector_frees_it():
    e = pyds.Engine()
    holder = [e]
    e.on_log = holder.append  # engine -> callback -> list -> engine
    held = [e]
    del e, holder
    (warning,) = _resource_warnings_while_collecting(held.clear)
    assert str(warning.message) == "unclosed <pyds.Engine>"


@pytest.mark.parametrize("release", ["close", "with"])
def test_an_engine_closed_before_collection_does_not_warn(release):
    if release == "close":
        e = pyds.Engine()
        e.close()
    else:
        with pyds.Engine() as e:
            pass
    held = [e]
    del e
    assert _resource_warnings_while_collecting(held.clear) == []

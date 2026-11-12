# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The extension's functions and engine methods show their real parameters (PY.13).

``inspect.signature`` and ``help()`` see them.
"""

import inspect

import pytest

import pyds
from pyds import _pyds


@pytest.mark.parametrize(
    ("name", "signature"),
    [
        ("clone", "()"),
        ("load_dsc", "(dsc, /)"),
        ("assert_", "(schema, /, **slots)"),
        ("assert_external", "(data, /)"),
        ("retract", "(fact_id, /)"),
        ("set_call_callback", "(callback, /)"),
        ("__enter__", "()"),
    ],
)
def test_a_method_shows_its_real_parameters(name, signature):
    with pyds.Engine() as e:
        assert str(inspect.signature(getattr(e, name))) == signature


# Read from the extension's class, because pyds.Engine overrides close and
# __exit__ in Python, and the private primitives are what _pyds.pyi describes.
@pytest.mark.parametrize(
    ("name", "signature"),
    [
        ("close", "(self, /)"),
        ("__exit__", "(self, /, *exc_info)"),
        # `$self` is positional-only in every text signature, so the `/`
        # after it is CPython's rendering, not the method's choice.
        ("_replay", "(self, /, stream, chunk_size=65536)"),
        ("_record_start", "(self, /, path, flush=False)"),
    ],
)
def test_an_extension_method_shows_its_real_parameters(name, signature):
    assert str(inspect.signature(getattr(_pyds._Engine, name))) == signature


def test_the_extension_engine_shows_its_constructor_parameters():
    assert str(inspect.signature(_pyds._Engine)) == "(*, run_id=None, tier_id=None)"


@pytest.mark.parametrize(
    ("name", "signature"),
    [
        ("build_capabilities", "()"),
        ("next_atom", "(buf, pos, partial, /)"),
        ("frame", "(field, body, /)"),
        ("container_of", "(buf, /)"),
        ("wire_fields", "(body, /)"),
        ("visit_atom", "(field, body, /)"),
        ("atom_message_name", "(field, /)"),
    ],
)
def test_an_extension_function_shows_its_real_parameters(name, signature):
    assert str(inspect.signature(getattr(_pyds, name))) == signature

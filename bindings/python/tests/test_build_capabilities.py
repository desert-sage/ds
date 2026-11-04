# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""``pyds.BUILD_CAPABILITIES``: what the linked libds has code for ([NLFC.10.1]).

``pyds.Capability`` itself is generated from ``proto/capabilities.proto``, and
the gate's ``gen_capability_py.py --check`` holds the two together; these tests
hold the constant to libds's own answer.
"""

import pyds
from pyds._pyds import build_capabilities


def test_build_capabilities_is_a_frozenset_of_capability_members():
    assert type(pyds.BUILD_CAPABILITIES) is frozenset
    assert all(type(c) is pyds.Capability for c in pyds.BUILD_CAPABILITIES)


def test_it_is_exactly_what_libds_reports():
    # libds lists them ascending, with no repeats, so nothing is lost in the
    # set and the order can be checked too.
    numbers = build_capabilities()
    assert list(numbers) == sorted(set(numbers))
    assert pyds.BUILD_CAPABILITIES == frozenset(numbers)


def test_this_build_has_code_for_every_capability():
    # The only capability a build can lack is `regex`, on one linking the RE2
    # stub (libds.h, ds_build_capabilities), and pyds links RE2 (meson.build).
    assert pyds.BUILD_CAPABILITIES == frozenset(pyds.Capability)

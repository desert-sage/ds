# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The StrEnums that name libds's enums hold ``ds_names.h``'s names.

``runtime/src/bindings/ds_names.h`` is the one table every binding names
libds's enums by. pyds mirrors its four vocabularies as ``StrEnum`` classes,
and the extension renders the table itself (``pyds._pyds._names``), so each
mirror is held here to the C it mirrors, member for member and in value order.
There is no storage mode or element type: there is no samples plane.
"""

import typing

import pytest

import pyds
from pyds import _pyds

_MIRRORS = [
    ("event_kind", pyds.EventKind),
    ("log_level", pyds.LogLevel),
    ("metric_kind", pyds.MetricKind),
    ("cache_removal", pyds.CacheRemovalReason),
]


@pytest.mark.parametrize(
    ("vocabulary", "enum"), _MIRRORS, ids=[vocabulary for vocabulary, _ in _MIRRORS]
)
def test_each_strenum_is_its_ds_names_vocabulary_in_value_order(vocabulary, enum):
    assert tuple(member.value for member in enum) == _pyds._names()[vocabulary]


def test_the_extension_renders_exactly_the_vocabularies_pyds_mirrors():
    # A vocabulary missing from the rendering would leave its enum compared
    # with nothing, so the set itself is held.
    assert set(_pyds._names()) == {vocabulary for vocabulary, _ in _MIRRORS}


def test_every_kind_libds_emits_has_exactly_one_event_class():
    """``timer_fired`` is the one kind with no class: libds never emits it."""
    kinds = [cls.kind for cls in typing.get_args(pyds.events.Event.__value__)]
    assert len(kinds) == len(set(kinds))
    assert set(kinds) == set(pyds.EventKind) - {pyds.EventKind.TIMER_FIRED}

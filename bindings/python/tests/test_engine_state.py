# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""What an engine reports about itself: values, read as properties.

A read with no argument and no side effect is a property, and its result a
frozen dataclass (PY.3, PY.4). ``memory_usage()`` stays a call because it
walks the network.
"""

import dataclasses

import pytest

import pyds
from pyds import AtomKind, atoms

_SRC = "schema S scope logical:\n    k: Int key\n"


def test_the_platform_signature_is_a_frozen_value_read_as_a_property():
    eng = pyds.Engine()
    sig = eng.platform_signature
    assert isinstance(sig, pyds.PlatformSignature)
    assert isinstance(sig.backends, tuple)
    assert sig == eng.platform_signature
    assert hash(sig) == hash(eng.platform_signature)
    with pytest.raises(dataclasses.FrozenInstanceError):
        sig.libc = "x"  # type: ignore[misc]  # the assignment under test


def test_a_session_header_reports_the_ids_as_the_engine_does():
    # [LFST.4.4]: an engine given no run id reports `session_id` empty, and
    # a single-tier engine's `tier_id` is the empty string it was given.
    # The empty string is the clause's value, so it is reported, not
    # translated.
    header = pyds.Engine().session_header
    assert isinstance(header, pyds.SessionHeader)
    assert header.session_id == ""
    assert header.tier_id == ""
    assert header.dsc_hash is None, "nothing is loaded"
    assert header.capabilities == ()
    assert header.dialect_def_sha256 is None


def test_the_session_header_carries_the_loaded_artefacts_hash():
    header = pyds.from_source(_SRC).session_header
    assert isinstance(header.dsc_hash, bytes)
    assert len(header.dsc_hash) == 32


def test_the_session_header_carries_the_whole_dialect_binding_tuple():
    # [RBND.1.3]: the tuple is dsc_hash, capabilities and dialect_def_sha256,
    # copied from the loaded artefact's header ([RBND.3.1]). `capabilities`
    # is the dialect's enabled set, ascending, so it holds `logical` for a
    # program with a `scope logical` schema, and more besides; which others
    # is the dialect's, and the next test holds them to libds's bytes.
    header = pyds.from_source(_SRC).session_header
    caps = header.capabilities
    assert isinstance(caps, tuple)
    assert all(type(c) is pyds.Capability for c in caps)
    assert pyds.Capability.LOGICAL in caps
    assert list(caps) == sorted(caps)
    assert isinstance(header.dialect_def_sha256, bytes)
    assert len(header.dialect_def_sha256) == 32


def test_the_session_header_is_the_stream_header_libds_records(tmp_path):
    # The C recorder's first atom is the header libds encodes from the same
    # accessor, so what Engine.session_header reports is what the recording
    # carries, field by field: fields 9 and 16 included ([RBND.2]).
    eng = pyds.from_source(_SRC)
    header = eng.session_header
    assert header.capabilities, "field 16 must have something in it"
    path = tmp_path / "s.rfcs"
    with eng.record(path):
        eng.assert_("S", k=1)
    first = next(atoms.iter_atoms(path.read_bytes()))
    assert first.kind is AtomKind.STREAM_HEADER
    recorded = first.message()
    assert recorded.ds_version == header.ds_version
    assert recorded.session_id == header.session_id
    assert recorded.tier_id == header.tier_id
    assert recorded.dsc_hash == header.dsc_hash
    assert tuple(recorded.capabilities) == tuple(int(c) for c in header.capabilities)
    assert recorded.dialect_def_sha256 == header.dialect_def_sha256


def test_the_session_header_names_the_linked_ds_version():
    eng = pyds.Engine()
    assert eng.session_header.ds_version == eng.platform_signature.libds_version


def test_memory_usage_is_a_value_whose_total_sums_its_byte_counts():
    usage = pyds.from_source(_SRC).memory_usage()
    assert isinstance(usage, pyds.MemoryUsage)
    parts = [
        f.name
        for f in dataclasses.fields(usage)
        if f.name.endswith("_bytes") and f.name != "total_bytes"
    ]
    assert usage.total_bytes == sum(getattr(usage, name) for name in parts)


def test_halted_is_none_while_the_engine_runs():
    assert pyds.Engine().halted is None


def test_the_method_spellings_are_gone():
    eng = pyds.Engine()
    assert not hasattr(eng, "get_session_header")
    assert not hasattr(eng, "mem")

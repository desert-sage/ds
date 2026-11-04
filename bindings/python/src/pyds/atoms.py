# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""libds's own atom reader and framing, for Python (PYTHON_BINDING.md §13).

Nothing here decodes. Each function hands bytes to libds and returns what
libds answered, so a Python tool reads a trace or a .dsc the way the C runtime
does rather than through a second codec. The one exception is
``Atom.message()``, which parses a body with protoc's generated class (OQ-6).

    iter_atoms(data, partial=False)  the container's atoms, one Atom per step
    frame(kind, body)                one framed atom
    band(field), disposition(field)  how a reader adjudicates a number
    container_of(data)               DSC or stream, from the first atom

An atom is named by its field number ([RFCS.16.1]). A number this build has no
registry entry for is read like any other and kept as its ``int``, for the
caller to skip or refuse by its band ([RFCS.16.3]). Whether a number is
allocated is ``field in AtomKind``. Malformed input raises
``pyds.InputError`` with ``Status.PARSE``, naming the byte libds stopped at.

``wire_fields()``, ``visit_atom()`` and ``message_name()`` are the
tuple-shaped readers of one atom's body.
"""

from __future__ import annotations

import enum
import functools
from collections.abc import Buffer, Iterator
from dataclasses import dataclass
from typing import TYPE_CHECKING

from pyds import _pyds
from pyds._atom_registry import AtomKind
from pyds._pyds import atom_message_name as message_name
from pyds._pyds import visit_atom, wire_fields

if TYPE_CHECKING:
    from google.protobuf.message import Message

__all__ = [
    "Atom",
    "Band",
    "Container",
    "Disposition",
    "band",
    "container_of",
    "disposition",
    "frame",
    "iter_atoms",
    "message_name",
    "visit_atom",
    "wire_fields",
]


@dataclass(frozen=True, slots=True)
class Atom:
    """One atom of a container, as libds framed it."""

    kind: AtomKind | int
    """An ``AtomKind``, or the plain field number of one this build lacks."""
    body: bytes
    offset: int
    """Where the atom's frame starts in the buffer."""
    end: int
    """Just past its frame: where the next atom starts."""

    def message(self) -> Message:
        """Parse the body as its kind's generated class in ``pyds.proto``.

        A kind this build has no entry for raises ``LookupError``.
        """
        if not isinstance(self.kind, AtomKind):
            raise LookupError(f"atom field {self.kind} has no message in this build")
        return _message_class(self.kind).FromString(self.body)


@functools.cache
def _message_class(kind: AtomKind) -> type[Message]:
    # The body's type is the field's in atom.proto's oneof, the census's own
    # source ([RFCS.3.1]); protoc's class for it is built from that descriptor.
    from google.protobuf import descriptor, message_factory

    from pyds.proto import atom_pb2

    body = atom_pb2.Atom.DESCRIPTOR.fields_by_number[int(kind)].message_type
    # Every member of the oneof is a message; a scalar would have none.
    if not isinstance(body, descriptor.Descriptor):
        raise LookupError(f"atom field {int(kind)} carries no message")
    return message_factory.GetMessageClass(body)


def _kind(field: int) -> AtomKind | int:
    return AtomKind(field) if field in AtomKind else field


def iter_atoms(data: Buffer, /, *, partial: bool = False) -> Iterator[Atom]:
    """Yield the container's atoms, in order, one per step (``ds_pbf_next_atom``).

    A partial trailing atom raises, unless ``partial``: then the iteration
    ends before it, which is how a recording still being written, or cut off
    by a crash, is read to its last complete atom ([RFCS.19.2]). A frame no
    append could repair raises either way.
    """
    view = memoryview(data).cast("B")
    pos, size = 0, len(view)
    while pos < size:
        step = _pyds.next_atom(view, pos, partial)
        if step is None:
            return
        field, body, end = step
        yield Atom(_kind(field), body, pos, end)
        pos = end


def frame(kind: AtomKind | int, body: Buffer, /) -> bytes:
    """One framed atom ([RFCS.19.1], ``ds_rfcs_pack_atom``).

    A number with no registry entry is a ``ValueError``; one outside
    ``0..2**32-1`` an ``OverflowError``.
    """
    return _pyds.frame(kind, body)


class Band(enum.StrEnum):
    """A field number's band ([RFCS.16.2]), from its magnitude alone."""

    NONE = "none"
    INJECT = "inject"
    REJECT = "reject"
    SKIP = "skip"


class Disposition(enum.StrEnum):
    """What a reader does with an atom it does not know ([RFCS.16.3]).

    ``SKIP`` for a known atom is not a dispatch decision: there is nothing to
    refuse about it. Ask ``field in AtomKind`` first; the disposition is the
    whole answer only when that is false.
    """

    SKIP = "skip"
    REJECT_INJECT = "reject_inject"
    REJECT_VERSION = "reject_version"
    MALFORMED = "malformed"


class Container(enum.StrEnum):
    """A container's type, from its first atom's number ([RFCS.19.4])."""

    UNKNOWN = "unknown"
    STREAM = "stream"
    DSC = "dsc"


# libds's enums, in their declared order: ds_atom_band_t, ds_pbf_disposition_t
# and ds_pbf_container_t (dsc/atom_registry.h, dsc/pbf_reader.h).
_BANDS = (Band.INJECT, Band.REJECT, Band.SKIP, Band.NONE)
_DISPOSITIONS = (
    Disposition.SKIP,
    Disposition.REJECT_INJECT,
    Disposition.REJECT_VERSION,
    Disposition.MALFORMED,
)
_CONTAINERS = (Container.UNKNOWN, Container.STREAM, Container.DSC)


def band(field: int, /) -> Band:
    """``field``'s band (``ds_pbf_band``)."""
    return _BANDS[_pyds.atom_band(field)]


def disposition(field: int, /) -> Disposition:
    """Return what a reader does with ``field`` if it does not know it.

    libds answers it (``ds_pbf_disposition``).
    """
    return _DISPOSITIONS[_pyds.atom_disposition(field)]


def container_of(data: Buffer, /) -> Container:
    """Return the container's type (``ds_pbf_container_of``)."""
    return _CONTAINERS[_pyds.container_of(data)]

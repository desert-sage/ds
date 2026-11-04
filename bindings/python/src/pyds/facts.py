# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""How pyds names a fact, and what it reads one as."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from types import MappingProxyType

__all__ = ["Fact", "FactId"]


class FactId(int):
    """A fact's id.

    The engine assigns it when the fact enters working memory; ids increase
    and are never reused, so a FactId names one fact for the engine's life.
    Every call that takes a fact takes its FactId, and one that is not in
    working memory raises KeyError. A FactId is an ``int`` in every other way:
    it hashes, compares, prints and serialises as its number.
    """

    __slots__ = ()

    def __repr__(self) -> str:
        """Show the id as ``FactId(n)``; ``str()`` gives the bare number."""
        return f"FactId({int(self)})"

    __str__ = int.__repr__


@dataclass(frozen=True, slots=True)
class Fact:
    """A fact in working memory, as it was when read.

    A snapshot: it holds nothing of the engine's, so it stays readable after
    the fact is gone, and it does not change when the engine does. Two Facts
    are equal when every field is, and hash alike when they are equal.
    """

    id: FactId
    schema: str
    """The name of the schema it instantiates."""
    slots: Mapping[str, object]
    """Its slot values by name, read-only. A slot that holds nothing reads as
    None; a fact-reference slot as its target's FactId, live or not; a
    ``Json`` slot as its canonical JSON text."""
    asserted_ns: int
    """The engine clock when it was asserted."""
    ttl_deadline_ns: int | None
    """When the TTL sweep retracts it; None for a fact with no deadline, as
    every logical fact is."""

    # The generated hash would hash ``slots``, which a mapping proxy refuses.
    # Every slot value pyds reads out is hashable, so the slots hash as a
    # frozenset of their items, which is equal exactly when the mappings are
    # (data model §3.3.1), as inspect.Signature hashes its parameters.
    def __hash__(self) -> int:
        """Hash every field, the slots as a frozenset of their items."""
        return hash(
            (
                self.id,
                self.schema,
                frozenset(self.slots.items()),
                self.asserted_ns,
                self.ttl_deadline_ns,
            )
        )


def _fact(record: tuple[FactId, str, dict[str, object], int, int]) -> Fact:
    """Build a Fact from the extension's record of one, which spells no deadline 0."""
    fid, schema, slots, asserted_ns, deadline_ns = record
    return Fact(
        id=fid,
        schema=schema,
        slots=MappingProxyType(slots),
        asserted_ns=asserted_ns,
        ttl_deadline_ns=deadline_ns or None,
    )


for _cls in (Fact, FactId):
    _cls.__module__ = "pyds"
del _cls

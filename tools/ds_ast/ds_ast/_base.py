# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The base class every node derives from, shaped like Python's `ast.AST`.

A node is built the way a Python `ast` node is: fields positionally in
`_fields` order or by keyword, attributes by keyword only. A field left out
takes its kind's default -- `None` for an optional (`?`) field, a fresh empty
list for a sequence (`*`) -- as Python 3.13's `ast` does. A required field
left out is left unset, as older Python did, so a tree can be built up
incrementally; `dump` and `unparse` report one still missing.

The trivia attributes default too, so a node built by hand has no comments
and no blank lines before it rather than an unset attribute. Location
attributes do not: `fix_missing_locations` fills them, as in Python.

Equality is identity, as in Python. Compare trees with `dump`.
"""
from __future__ import annotations

_TRIVIA_DEFAULTS = {
    "comments_before": list,
    "comment_after": lambda: None,
    "blank_lines_before": lambda: 0,
}


class AST:
    _fields: tuple[str, ...] = ()
    _attributes: tuple[str, ...] = ()
    _field_kinds: dict[str, str] = {}
    _field_types: dict[str, str] = {}

    def __init__(self, *args: object, **kwargs: object) -> None:
        if len(args) > len(self._fields):
            raise TypeError(f"{type(self).__name__} takes at most "
                            f"{len(self._fields)} positional arguments "
                            f"({len(args)} given)")
        for name, value in zip(self._fields, args):
            setattr(self, name, value)
        for name in self._fields[len(args):]:
            if name in kwargs:
                setattr(self, name, kwargs.pop(name))
            elif self._field_kinds.get(name) == "?":
                setattr(self, name, None)
            elif self._field_kinds.get(name) == "*":
                setattr(self, name, [])
        for name in self._attributes:
            if name in kwargs:
                setattr(self, name, kwargs.pop(name))
            elif name in _TRIVIA_DEFAULTS:
                setattr(self, name, _TRIVIA_DEFAULTS[name]())
        if kwargs:
            unknown = ", ".join(sorted(kwargs))
            raise TypeError(f"{type(self).__name__} got unexpected keyword "
                            f"argument(s): {unknown}")

    def __repr__(self) -> str:
        parts = ", ".join(f"{name}={getattr(self, name, '<unset>')!r}"
                          for name in self._fields)
        return f"{type(self).__name__}({parts})"

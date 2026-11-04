# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Python's `ast` helpers, with the same names and the same meanings.

`iter_fields`, `iter_child_nodes`, `walk`, `dump`, `get_docstring`,
`NodeVisitor`, `NodeTransformer`, `copy_location`, `fix_missing_locations`
and `increment_lineno` behave as their `ast` namesakes do. Where DS's tree
carries something Python's does not -- the trivia attributes -- the choice is
stated beside the function it affects.

⚠ TRIVIA IS ATTRIBUTES, NOT FIELDS, as locations are. `comments_before` and
`comment_after` ride on the node they precede or trail, so `walk`,
`iter_child_nodes` and the visitors do not visit them, exactly as they do not
visit `lineno`. The one exception is `Module.comments_end`, which is a FIELD
(`ds.asdl`), so `walk` does reach the comments at the end of a file. A
transformer that drops a node drops the comments riding on it; one that
replaces a node should move them, since `copy_location` copies locations only.
"""
from __future__ import annotations

import inspect
from collections import deque
from collections.abc import Iterator
from typing import Any

from ._base import AST

_LOCATIONS = ("lineno", "col_offset", "end_lineno", "end_col_offset")
_TRIVIA_COMMENTS = ("comments_before", "comment_after")


def iter_fields(node: AST) -> Iterator[tuple[str, Any]]:
    """Yield `(name, value)` for every field set on `node`."""
    for name in node._fields:
        try:
            yield name, getattr(node, name)
        except AttributeError:
            pass


def iter_child_nodes(node: AST) -> Iterator[AST]:
    """Yield every direct child node: fields holding a node, and the nodes in
    fields holding a list."""
    for _, value in iter_fields(node):
        if isinstance(value, AST):
            yield value
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, AST):
                    yield item


def walk(node: AST) -> Iterator[AST]:
    """Yield `node` and every descendant, breadth first, in no order a caller
    should rely on -- as Python's does."""
    todo = deque([node])
    while todo:
        current = todo.popleft()
        todo.extend(iter_child_nodes(current))
        yield current


def get_docstring(node: AST, clean: bool = True) -> str | None:
    """The docstring of a node that can carry one -- `Schema`, `Slot`,
    `Rule`, `Series`, `Service` -- or None. With `clean`, indentation is
    removed with `inspect.cleandoc`, as Python does. A node that cannot
    carry one raises `TypeError`, as Python's does."""
    if "docstring" not in node._fields:
        raise TypeError(f"{type(node).__name__!r} can't have docstrings")
    text = getattr(node, "docstring", None)
    if text is None:
        return None
    return inspect.cleandoc(text) if clean else text


def dump(node: Any, annotate_fields: bool = True,
         include_attributes: bool = False, *, indent: int | str | None = None,
         show_empty: bool = False) -> str:
    """A formatted string of the tree, as Python 3.13's `ast.dump`.

    `None` and `[]` values are left out unless `show_empty`, and a field left
    unset is left out always; once one is left out, later fields are written
    by keyword even when `annotate_fields` is false, so a positional reading
    stays correct. `include_attributes` adds locations and trivia."""
    if isinstance(indent, int):
        indent = " " * indent

    def fmt(value: Any, level: int) -> tuple[str, bool]:
        if indent is not None:
            level += 1
            prefix = "\n" + indent * level
            sep = ",\n" + indent * level
        else:
            prefix = ""
            sep = ", "
        if isinstance(value, AST):
            args: list[str] = []
            simple = True
            keywords = annotate_fields
            names = list(value._fields)
            if include_attributes:
                names += list(value._attributes)
            for name in names:
                try:
                    item = getattr(value, name)
                except AttributeError:
                    keywords = True
                    continue
                if not show_empty and (item is None or item == []):
                    keywords = True
                    continue
                text, item_simple = fmt(item, level)
                simple = simple and item_simple
                args.append(f"{name}={text}" if keywords or
                            name in value._attributes else text)
            head = type(value).__name__
            if simple and len(args) <= 3:
                return f"{head}({', '.join(args)})", not args
            return f"{head}({prefix}{sep.join(args)})", False
        if isinstance(value, list):
            if not value:
                return "[]", True
            parts = [fmt(item, level)[0] for item in value]
            return f"[{prefix}{sep.join(parts)}]", False
        return repr(value), True

    if not isinstance(node, AST):
        raise TypeError(f"expected AST, got {type(node).__name__!r}")
    return fmt(node, 0)[0]


class NodeVisitor:
    """Calls `visit_<ClassName>` for each node, or `generic_visit`, which
    visits the children. As Python's."""

    def visit(self, node: AST) -> Any:
        visitor = getattr(self, "visit_" + type(node).__name__,
                          self.generic_visit)
        return visitor(node)

    def generic_visit(self, node: AST) -> Any:
        for _, value in iter_fields(node):
            if isinstance(value, list):
                for item in value:
                    if isinstance(item, AST):
                        self.visit(item)
            elif isinstance(value, AST):
                self.visit(value)
        return None


class NodeTransformer(NodeVisitor):
    """A visitor whose `visit_*` return value replaces the node: `None`
    removes it, a list splices several in its place. As Python's."""

    def generic_visit(self, node: AST) -> AST:
        for name, old in iter_fields(node):
            if isinstance(old, list):
                new: list[Any] = []
                for item in old:
                    if isinstance(item, AST):
                        item = self.visit(item)
                        if item is None:
                            continue
                        if not isinstance(item, AST):
                            new.extend(item)
                            continue
                    new.append(item)
                old[:] = new
            elif isinstance(old, AST):
                replacement = self.visit(old)
                if replacement is None:
                    delattr(node, name)
                else:
                    setattr(node, name, replacement)
        return node


def copy_location(new_node: AST, old_node: AST) -> AST:
    """Copy the location attributes from `old_node` to `new_node`, and
    nothing else -- not the trivia, as Python's copies no comments either."""
    for name in _LOCATIONS:
        if name in old_node._attributes and name in new_node._attributes:
            value = getattr(old_node, name, None)
            if value is not None or (hasattr(old_node, name)
                                     and name.startswith("end_")):
                setattr(new_node, name, value)
    return new_node


def fix_missing_locations(node: AST) -> AST:
    """Give every node without a location its parent's, starting from line 1
    column 0, as Python does. `dsc` writes no end positions yet, so after a
    parse this fills every `end_*` from the parent's too."""
    def fix(current: AST, lineno: int, col: int, end_lineno: int,
            end_col: int) -> None:
        if "lineno" in current._attributes:
            if not hasattr(current, "lineno"):
                current.lineno = lineno
            else:
                lineno = current.lineno
        if "end_lineno" in current._attributes:
            if getattr(current, "end_lineno", None) is None:
                current.end_lineno = end_lineno
            else:
                end_lineno = current.end_lineno
        if "col_offset" in current._attributes:
            if not hasattr(current, "col_offset"):
                current.col_offset = col
            else:
                col = current.col_offset
        if "end_col_offset" in current._attributes:
            if getattr(current, "end_col_offset", None) is None:
                current.end_col_offset = end_col
            else:
                end_col = current.end_col_offset
        for child in iter_child_nodes(current):
            fix(child, lineno, col, end_lineno, end_col)

    fix(node, 1, 0, 1, 0)
    return node


def increment_lineno(node: AST, n: int = 1) -> AST:
    """Add `n` to every line number in the tree, as Python's does -- and to
    the comments riding on each node, which `walk` does not reach, so a
    moved block keeps its comments beside it."""
    for child in walk(node):
        _shift(child, n)
        for name in _TRIVIA_COMMENTS:
            riding = getattr(child, name, None)
            for comment in riding if isinstance(riding, list) else [riding]:
                if isinstance(comment, AST):
                    _shift(comment, n)
    return node


def _shift(node: AST, n: int) -> None:
    if "lineno" in node._attributes:
        node.lineno = getattr(node, "lineno", 0) + n
    if "end_lineno" in node._attributes:
        end = getattr(node, "end_lineno", 0)
        if end is not None:
            node.end_lineno = end + n

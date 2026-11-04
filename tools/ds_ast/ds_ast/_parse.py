# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`parse`: DS source to a tree, by way of the Mercury compiler; `compile`: a
tree to a `.dsc`, the same way.

`ds_ast` contains no parser. [LTSL.1.2] makes the compiler "the only parser in
the system", so `parse` runs `dsc dump-ast -`, hands it the source on standard
input, and builds nodes from the JSON it writes (tools/ds_ast/DESIGN.md
section 4). `compile` runs `dsc compile -` on `unparse`'s text, and reports
what `dsc` says about that text at the nodes it was written for.

The reader is STRICT, in both directions: a `_type` the schema does not name,
a key a node does not have, a field or attribute the writer left out, and a
value of the wrong kind are all refused. That strictness is what makes the
Mercury writer's names checkable against `ds.asdl` -- a name that drifted is
a `DSTreeError` here, not a silently dropped key.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import warnings
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from . import _nodes
from ._base import AST
from ._tools import iter_child_nodes
from ._unparse import string_state, unparse

_NODE_CLASSES: dict[str, type[AST]] = {
    name: getattr(_nodes, name) for name in _nodes.__all__}
_SCALARS = {"str": (str,), "int": (int,), "bool": (bool,),
            "object": (int, float, str, bool, type(None))}
# The attributes' types, which the generator does not emit because every
# node shares them (ds.asdl's `attributes (...)` lists).
_ATTRIBUTE_TYPES = {"lineno": "int", "col_offset": "int",
                    "end_lineno": "int | None", "end_col_offset": "int | None",
                    "comments_before": "list[comment]",
                    "comment_after": "comment | None",
                    "blank_lines_before": "int"}
_LOCATION = re.compile(r'^File "(?P<file>.*)", line (?P<line>\d+), '
                       r'column (?P<col>\d+)$', re.MULTILINE)
_CODE = re.compile(r"^(?P<code>[A-Z][A-Z0-9_]*): (?P<msg>.*)$", re.MULTILINE)


class DSSyntaxError(SyntaxError):
    """A program `dsc` stopped in its front end, shaped like `SyntaxError`.

    `lineno` is 1-based and `offset` is the 1-based column, as Python's are;
    `code` is the compiler's diagnostic code, which is what a caller should
    branch on -- the wording is free to change, the code is not.

    From `compile`, also: `node`, the node the diagnostic was reported at
    (None when no node on its line has a `lineno`); `generated`, the line
    and column `dsc` named in `unparse`'s text; and `diagnostics`, every
    diagnostic of the refusal in `dsc`'s order, this one first, each a
    `DSSyntaxError` or a `DSSyntaxWarning`."""

    node: AST | None = None
    generated: tuple[int, int] | None = None
    diagnostics: tuple[SyntaxError | SyntaxWarning, ...] = ()

    def __init__(self, msg: str, filename: str, lineno: int | None,
                 offset: int | None, text: str | None, code: str | None):
        super().__init__(msg, (filename, lineno, offset, text))
        self.code = code


class DSSyntaxWarning(SyntaxWarning):
    """A warning `dsc` gave about a program it accepted, as `compile` issues
    it through `warnings`. `code`, `node` and `generated` are
    `DSSyntaxError`'s; `filename` and `lineno` are where it is reported."""

    def __init__(self, msg: str, filename: str, lineno: int | None,
                 offset: int | None, code: str, node: AST | None,
                 generated: tuple[int, int]):
        super().__init__(msg)
        self.msg = msg
        self.filename = filename
        self.lineno = lineno
        self.offset = offset
        self.code = code
        self.node = node
        self.generated = generated


class DSTreeError(ValueError):
    """`dsc` wrote a tree this library does not accept: a name or a shape
    `ds.asdl` does not have. A disagreement between the compiler and the
    library, never a problem with the program."""


def parse(source: str, filename: str = "<unknown>", *,
          dsc: str | os.PathLike[str] | None = None) -> _nodes.Module:
    """Parse DS source into a `Module`, as `ast.parse` parses Python.

    Syntax only: nothing is resolved or validated, so a program that does not
    compile yet still parses. `filename` names the source in a
    `DSSyntaxError`. `dsc` is the Mercury compiler binary; without it,
    `$DS_AST_DSC`, then `$DS_MERCURY_DSC`, then `dsc` on `PATH`.

    Raises `DSSyntaxError` for a syntax error, `NotImplementedError` for a
    construct the tree cannot represent yet (a `test` declaration), and
    `DSTreeError` if the compiler's output does not match the schema."""
    binary = _find_dsc(dsc)
    run = subprocess.run(
        [binary, "dump-ast", "-", "--filename", filename],
        input=source.encode("utf-8"), capture_output=True, check=False)
    stderr = run.stderr.decode("utf-8", errors="replace")
    if run.returncode == 1:
        _raise_refusal(stderr, filename)
    if run.returncode != 0:
        raise RuntimeError(f"`{binary} dump-ast` exited {run.returncode}: "
                           f"{stderr.strip()}")
    tree = from_json(json.loads(run.stdout.decode("utf-8")))
    if not isinstance(tree, _nodes.Module):
        raise DSTreeError(f"the root is {type(tree).__name__}, not Module")
    return tree


# A plain alias, not a `type` statement: the package runs on Python 3.11.
_Paths = Iterable["str | os.PathLike[str]"]


def compile(node: AST, filename: str = "<unknown>", *,
            dsc: str | os.PathLike[str] | None = None,
            search_path: _Paths = (), dialect_files: _Paths = ()) -> bytes:
    """The `.dsc` artefact for `node`, as Python's `compile` builds a code
    object: `unparse`, then `dsc compile`, with the text on standard input
    and the artefact on standard output, so nothing is written to disk.

    ⚠ A DIAGNOSTIC IS REPORTED AT A NODE, NOT AT THE TEXT'S LINE. `dsc` names
    a line of `unparse`'s text, which is nobody's source. Each diagnostic is
    reported instead at the deepest node written on that line that has a
    `lineno`, at that node's `lineno` and `col_offset`, under `filename`: a
    generator that sets `lineno` from its own source sees `dsc` refuse the
    program at the line its author wrote. Where no node on the line
    has a `lineno`, the location is None; `generated` keeps `dsc`'s.

    `filename` names the program in what is reported, and to `dsc`.
    `search_path` is where imports resolve, `-L`; `dialect_files` are
    dialect definitions to register first, `-d`, in order (both as
    `pyds.compile` takes them). `dsc` is found as `parse` finds it.

    Raises `DSSyntaxError` for the first error when `dsc` refuses the
    program, every diagnostic on its `diagnostics`. Issues each warning of an
    accepted program as a `DSSyntaxWarning`, through `warnings`. Raises
    `ValueError` for a tree `unparse` cannot write, `TypeError` for one path
    where a sequence of paths belongs, and `RuntimeError` when `dsc` fails
    any other way."""
    for name, paths in (("search_path", search_path),
                        ("dialect_files", dialect_files)):
        if isinstance(paths, (str, bytes, os.PathLike)):
            raise TypeError(f"{name} takes a sequence of paths, not one path")
    text, lines = unparse(node, line_map=True)
    binary = _find_dsc(dsc)
    argv = [binary, "compile", "-", "-o", "-", "--filename", filename,
            "--diagnostics", "json"]
    for d in dialect_files:
        argv += ["-d", str(Path(d).resolve())]
    for p in search_path:
        argv += ["-L", str(Path(p).resolve())]
    run = subprocess.run(argv, input=text.encode("utf-8"),
                         capture_output=True, check=False)
    stderr = run.stderr.decode("utf-8", errors="replace")
    if run.returncode not in (0, 1):
        raise RuntimeError(f"`{binary} compile` exited {run.returncode}: "
                           f"{stderr.strip()}")
    try:
        # [RCLI.3.2]: one document whenever there is a diagnostic, none
        # when there is not.
        written = json.loads(stderr)["diagnostics"] if stderr.strip() else []
    except (ValueError, KeyError, TypeError) as err:
        raise RuntimeError(f"`{binary} compile` wrote no diagnostics "
                           f"document: {stderr.strip()}") from err
    depth = _depths(node)
    reported = [_reported(d, lines, depth, filename) for d in written]
    if run.returncode == 0:
        for w in reported:
            if isinstance(w, DSSyntaxWarning):
                warnings.warn_explicit(w, DSSyntaxWarning, filename,
                                       w.lineno or 0)
        return run.stdout
    errors = [e for e in reported if isinstance(e, DSSyntaxError)]
    if not errors:
        raise RuntimeError(f"`{binary} compile` refused the program and "
                           f"reported no error: {stderr.strip()}")
    for e in errors:
        e.diagnostics = tuple(reported)
    raise errors[0]


def _depths(root: AST) -> dict[int, int]:
    """How deep each node of `root` is, by identity: a diagnostic goes to the
    deepest located node on its line."""
    depth = {id(root): 0}
    todo = [root]
    while todo:
        parent = todo.pop()
        for child in iter_child_nodes(parent):
            depth[id(child)] = depth[id(parent)] + 1
            todo.append(child)
    return depth


def _reported(diagnostic: dict[str, Any], lines: list[tuple[AST, ...]],
              depth: dict[int, int], filename: str) -> Any:
    """One `dsc --diagnostics json` diagnostic, at the node its line was
    written for: a `DSSyntaxError`, or a `DSSyntaxWarning`. The deepest
    located node wins, and of two as deep, the first written."""
    start = diagnostic["span"]["start"]
    line, column = start["line"], start["column"]
    on_line = lines[line - 1] if 0 < line <= len(lines) else ()
    node = None
    for candidate in on_line:
        if getattr(candidate, "lineno", None) is None:
            continue
        if node is None or \
                depth.get(id(candidate), -1) > depth.get(id(node), -1):
            node = candidate
    lineno = node.lineno if node is not None else None
    col = getattr(node, "col_offset", None) if node is not None else None
    offset = col + 1 if col is not None else None
    message, code = diagnostic["message"], diagnostic["code"]
    if diagnostic["severity"] == "warning":
        return DSSyntaxWarning(message, filename, lineno, offset, code, node,
                               (line, column))
    err = DSSyntaxError(message, filename, lineno, offset, None, code)
    err.node = node
    err.generated = (line, column)
    return err


def _find_dsc(dsc: str | os.PathLike[str] | None) -> str:
    for candidate in (dsc, os.environ.get("DS_AST_DSC"),
                      os.environ.get("DS_MERCURY_DSC")):
        if candidate:
            return os.fspath(candidate)
    found = shutil.which("dsc")
    if found is None:
        raise FileNotFoundError(
            "no Mercury `dsc`: pass dsc=, or set DS_AST_DSC")
    return found


def _raise_refusal(stderr: str, filename: str) -> None:
    location = _LOCATION.search(stderr)
    code = _CODE.search(stderr)
    if location is None:
        raise NotImplementedError(stderr.strip().removeprefix("dsc: "))
    text = None
    rest = stderr[location.end():].lstrip("\n").split("\n")
    if rest and rest[0].startswith("    "):
        text = rest[0][4:]
    raise DSSyntaxError(
        code.group("msg") if code else stderr.strip(), filename,
        int(location.group("line")), int(location.group("col")), text,
        code.group("code") if code else None)


def from_json(value: Any) -> Any:
    """Build nodes from the JSON `dsc dump-ast` writes. Public so a caller
    holding a dump already (a cache, a fixture) need not run `dsc` again."""
    if isinstance(value, list):
        return [from_json(item) for item in value]
    if not isinstance(value, dict):
        return value
    if "_type" not in value:
        raise DSTreeError(f"an object with no `_type`: {sorted(value)}")
    type_name = value["_type"]
    cls = _NODE_CLASSES.get(type_name)
    # A class with constructors under it is an ASDL type (`decl`, `expr`),
    # never a node that can be written.
    if cls is None or cls.__subclasses__():
        raise DSTreeError(f"`{type_name}` is not a node in ds.asdl")
    expected = set(cls._fields) | set(cls._attributes)
    written = set(value) - {"_type"}
    if written - expected:
        raise DSTreeError(f"{type_name} has no "
                          f"{', '.join(sorted(written - expected))}")
    if expected - written:
        raise DSTreeError(f"{type_name} was written without "
                          f"{', '.join(sorted(expected - written))}")
    node = cls.__new__(cls)
    for name in cls._fields + cls._attributes:
        built = from_json(value[name])
        declared = cls._field_types.get(name) or _ATTRIBUTE_TYPES.get(name)
        if declared is not None:
            _check(type_name, name, declared, built)
        setattr(node, name, built)
    # A string's `raw` is written back only while the node still says what
    # it said when read (`_unparse.string_state`): the check that needs no
    # second reader of the escape grammar.
    state = string_state(node)
    if state is not None:
        node._read_as = state
    return node


def _check(type_name: str, name: str, declared: str, built: Any) -> None:
    """`built` is a value of the generated type string `declared`."""
    optional = declared.endswith(" | None")
    base = declared.removesuffix(" | None")
    if built is None:
        if optional or base == "object":
            return
        raise DSTreeError(f"{type_name}.{name} is null, and is required")
    if base.startswith("list[") and base.endswith("]"):
        if not isinstance(built, list):
            raise DSTreeError(f"{type_name}.{name} is not a list")
        for item in built:
            _check(type_name, name, base[5:-1], item)
        return
    if base in _SCALARS:
        # `bool` is an `int` in Python; an `int` field holding one is still
        # the wrong kind.
        if isinstance(built, bool) and base == "int" or \
                not isinstance(built, _SCALARS[base]):
            raise DSTreeError(f"{type_name}.{name} should be {base}, "
                              f"got {type(built).__name__}")
        return
    expected = _NODE_CLASSES.get(base)
    if expected is None or not isinstance(built, expected):
        raise DSTreeError(f"{type_name}.{name} should be {base}, "
                          f"got {type(built).__name__}")

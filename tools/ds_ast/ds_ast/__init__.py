# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The DS syntax tree, shaped like Python's `ast`.

Every node class is generated from `tools/ds_ast/ds.asdl`. `parse` reads a
program through the Mercury `dsc`; the helpers are Python's, by name and by
meaning; `unparse` writes a tree back as source, and `compile` builds it
through `dsc` (tools/ds_ast/DESIGN.md).
"""
from ._base import AST
from ._nodes import *  # noqa: F401,F403
from ._nodes import __all__ as _node_names
from ._parse import (DSSyntaxError, DSSyntaxWarning, DSTreeError, compile,
                     from_json, parse)
from ._tools import (NodeTransformer, NodeVisitor, copy_location, dump,
                     fix_missing_locations, get_docstring, increment_lineno,
                     iter_child_nodes, iter_fields, walk)
from ._unparse import unparse

# ⚠ `compile` IS PUBLIC AND NOT IN `__all__`: a star import must not shadow
# the builtin it is named after (tests/test_nodes.py). Call it as
# `ds_ast.compile`.
__all__ = ["AST", "DSSyntaxError", "DSSyntaxWarning", "DSTreeError",
           "NodeTransformer", "NodeVisitor", "copy_location", "dump",
           "fix_missing_locations", "from_json", "get_docstring",
           "increment_lineno", "iter_child_nodes", "iter_fields", "parse",
           "unparse", "walk", *_node_names]

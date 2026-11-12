<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `ds_ast`

## Nodes

### `AST`

**`class AST`**

The base class of every node.

A node is built as a Python `ast` node is: fields positionally in `_fields` order or by keyword, and attributes by keyword only. A field left out is `None` when it is optional and a new empty list when it is a sequence; a required field left out stays unset. The attributes `comments_before`, `comment_after` and `blank_lines_before` default to `[]`, `None` and `0`, and the locations `lineno`, `col_offset`, `end_lineno` and `end_col_offset` stay unset. An unknown keyword, or more positional arguments than fields, raises `TypeError`.

Two nodes are equal only when they are the same object.

*(Source: tools/ds_ast/ds_ast/_base.py)*

### Node classes

Every node class is generated from `tools/ds_ast/ds.asdl`: one class per constructor, with the fields and attributes the constructor declares.

An ASDL type with constructors under it, such as `expr`, is an abstract base class of them, and no tree holds one. Comments and blank lines are attributes, as locations are, except `Module.comments_end`, which is a field. Every node class is in `__all__`. The tree's JSON form is that of [`dsc dump-ast`](inv:author:std:doc#tools/dsc).

*(Source: tools/ds_ast/ds.asdl, tools/ds_ast/ds_ast/__init__.py, Spec: [RCLI.1.10])*

## Reading

### `parse`

**`def parse(source: str, filename: str = "<unknown>", *, dsc: str | os.PathLike[str] | None = None) -> Module`**

Parses DS source into a `Module`, by running `dsc dump-ast` on it.

It reads syntax only: nothing is resolved or validated, and a program that does not compile still parses. `filename` names the source to `dsc` and in a `DSSyntaxError`. `dsc` is found as [Which `dsc` runs](#which-dsc-runs) states.

| Raises | Condition |
|---|---|
| [`DSSyntaxError`](#dssyntaxerror) | `dsc` refuses the source, naming its location |
| `NotImplementedError` | `dsc` refuses the source naming no location: a construct the tree does not represent, a `test` declaration among them |
| [`DSTreeError`](#dstreeerror) | the tree `dsc` writes does not match `ds.asdl`, or its root is not a `Module` |
| `RuntimeError` | `dsc` exits with a status other than `0` or `1` |
| `FileNotFoundError` | no `dsc` is found |

*(Source: tools/ds_ast/ds_ast/_parse.py, Spec: [RCLI.1.10])*

### `from_json`

**`def from_json(value: Any) -> Any`**

Builds nodes from the decoded JSON `dsc dump-ast` writes.

A list builds a list, and a value that is neither a list nor an object is returned as it is. An object's `_type` names its node class. It raises [`DSTreeError`](#dstreeerror) for an object with no `_type`, a `_type` that names no node class or names an abstract one, a key the node does not have, a field or attribute left out, and a value of the wrong kind.

*(Source: tools/ds_ast/ds_ast/_parse.py, Spec: [RCLI.1.10])*

### Which `dsc` runs

`parse` and `compile` run the first of:

1. the `dsc` argument, if given and not empty;
2. the path in the environment variable `DS_AST_DSC`, if set and not empty;
3. the path in the environment variable `DS_MERCURY_DSC`, if set and not empty;
4. `dsc` on `PATH`.

`ds-lang-ast` bundles no `dsc`. The search differs from [`pyds`'s](../pyds/compile.md#which-dsc-runs).

*(Source: tools/ds_ast/ds_ast/_parse.py)*

## Writing

### `unparse`

**`def unparse(node: AST, *, line_map: bool = False) -> Any`**

Writes `node` as DS source: a `Module`, one declaration or statement, or an expression.

With `line_map=True` it returns `(source, lines)`, where `lines[i]` is the tuple of nodes that line `i + 1` of `source` was written for, outermost first. A comment or blank line belongs to the node it precedes, and an expression's source is one line. A tree it cannot write raises `ValueError`.

*(Source: tools/ds_ast/ds_ast/_unparse.py)*

### `compile`

**`def compile(node: AST, filename: str = "<unknown>", *, dsc: str | os.PathLike[str] | None = None, search_path: Iterable[str | os.PathLike[str]] = (), dialect_files: Iterable[str | os.PathLike[str]] = ()) -> bytes`**

Returns the `.dsc` artefact for `node`, by running `dsc compile` on the text `unparse` writes, with nothing written to disk.

`compile` is not in `__all__`, and is called as `ds_ast.compile`.

| Argument | Holds |
|---|---|
| `filename` | the program's name, to `dsc` and in what is reported |
| `search_path` | the directories imports resolve in, in order |
| `dialect_files` | dialect definitions registered first, in order |
| `dsc` | the compiler, as [Which `dsc` runs](#which-dsc-runs) states |

Each diagnostic is reported at a node: the deepest node with a `lineno` written on the diagnostic's line of the text, at that node's `lineno` and `col_offset`, under `filename`. Where no node on the line has a `lineno`, the location is `None`. Each warning of a program `dsc` accepts is issued through `warnings` as a [`DSSyntaxWarning`](#dssyntaxwarning).

| Raises | Condition |
|---|---|
| [`DSSyntaxError`](#dssyntaxerror) | `dsc` refuses the program: the first error, with every diagnostic on its `diagnostics` |
| `ValueError` | a tree `unparse` cannot write |
| `TypeError` | one path stands where a sequence of paths belongs |
| `RuntimeError` | `dsc` exits with a status other than `0` or `1`, writes no diagnostics document, or refuses the program and reports no error |
| `FileNotFoundError` | no `dsc` is found |

*(Source: tools/ds_ast/ds_ast/_parse.py, Spec: [RCLI.3.2])*

## Errors

### `DSSyntaxError`

**`class DSSyntaxError(SyntaxError)`**

A program `dsc` refused, shaped like `SyntaxError`.

`lineno` is 1-based, and `offset` is the 1-based column. `code` is the compiler's diagnostic code. From `compile` it also carries `node`, the node the diagnostic is reported at, or `None`; `generated`, the line and column `dsc` named in the text `unparse` wrote; and `diagnostics`, every diagnostic of the refusal in `dsc`'s order, this one first.

*(Source: tools/ds_ast/ds_ast/_parse.py)*

### `DSSyntaxWarning`

**`class DSSyntaxWarning(SyntaxWarning)`**

A warning `dsc` gave about a program it accepted, issued by `compile`.

It carries `msg`, `filename`, `lineno`, `offset`, `code`, `node` and `generated`, as `DSSyntaxError` does.

*(Source: tools/ds_ast/ds_ast/_parse.py)*

### `DSTreeError`

**`class DSTreeError(ValueError)`**

A tree `dsc` wrote that `ds.asdl` does not describe.

It reports a disagreement between `dsc` and `ds_ast`, and never a defect in the program.

*(Source: tools/ds_ast/ds_ast/_parse.py)*

## Helpers

### `iter_fields`

**`def iter_fields(node: AST) -> Iterator[tuple[str, Any]]`**

Yields `(name, value)` for every field set on `node`, in `_fields` order.

*(Source: tools/ds_ast/ds_ast/_tools.py)*

### `iter_child_nodes`

**`def iter_child_nodes(node: AST) -> Iterator[AST]`**

Yields every direct child of `node`: each field holding a node, and each node in a field holding a list.

Attributes are not visited, so neither are the comments in `comments_before` and `comment_after`. `Module.comments_end` is a field, and is visited.

*(Source: tools/ds_ast/ds_ast/_tools.py)*

### `walk`

**`def walk(node: AST) -> Iterator[AST]`**

Yields `node` and every node under it.

The order is unspecified.

*(Source: tools/ds_ast/ds_ast/_tools.py)*

### `dump`

**`def dump(node: Any, annotate_fields: bool = True, include_attributes: bool = False, *, indent: int | str | None = None, show_empty: bool = False) -> str`**

Formats the tree as a string, as Python 3.13's `ast.dump` does.

A `None` or `[]` value is left out unless `show_empty`, and an unset field always is. Once one is left out, the fields after it are written by keyword, `annotate_fields` false included. `include_attributes` adds the locations, comments and blank lines. A `node` that is not an `AST` raises `TypeError`.

*(Source: tools/ds_ast/ds_ast/_tools.py)*

### `get_docstring`

**`def get_docstring(node: AST, clean: bool = True) -> str | None`**

Returns the docstring of a `Schema`, `Slot`, `Rule`, `Series` or `Service` node, or `None` when it has none.

With `clean`, indentation is removed with `inspect.cleandoc`. A node of another class raises `TypeError`.

*(Source: tools/ds_ast/ds_ast/_tools.py)*

### `NodeVisitor`

**`class NodeVisitor`**

Calls `visit_<ClassName>` for a node, or `generic_visit`, which visits its children.

*(Source: tools/ds_ast/ds_ast/_tools.py)*

### `NodeTransformer`

**`class NodeTransformer(NodeVisitor)`**

A `NodeVisitor` whose `visit_*` return value replaces the node visited.

`None` removes the node, and a list puts its items in the node's place in a list field. A node removed takes the comments in its `comments_before` and `comment_after` with it.

*(Source: tools/ds_ast/ds_ast/_tools.py)*

### `copy_location`

**`def copy_location(new_node: AST, old_node: AST) -> AST`**

Copies `lineno`, `col_offset`, `end_lineno` and `end_col_offset` from `old_node` to `new_node`, and returns `new_node`.

It copies no comments or blank lines.

*(Source: tools/ds_ast/ds_ast/_tools.py)*

### `fix_missing_locations`

**`def fix_missing_locations(node: AST) -> AST`**

Gives every node in the tree that has no location its parent's, the root taking line 1 and column 0, and returns `node`.

An `end_lineno` or `end_col_offset` that is `None` is filled the same way.

*(Source: tools/ds_ast/ds_ast/_tools.py)*

### `increment_lineno`

**`def increment_lineno(node: AST, n: int = 1) -> AST`**

Adds `n` to every line number in the tree, those of the comments on each node included, and returns `node`.

*(Source: tools/ds_ast/ds_ast/_tools.py)*

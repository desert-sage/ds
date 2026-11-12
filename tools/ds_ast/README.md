<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# ds-lang-ast

Desert Sage (DS) programs as syntax trees, shaped like Python's `ast`.

## Contents

The package `ds_ast`: a node class for every construct of the DS syntax tree, `parse` from source to a tree, `unparse` from a tree back to source, `compile` from a tree to a `.dsc` artefact, and Python's `ast` helpers under their own names (`walk`, `dump`, `NodeVisitor`, `NodeTransformer` and the rest).

## Install

```sh
pip install ds-lang-ast
```

It runs on Python 3.11 or later, and needs no other package. It contains no parser of its own: `parse` and `compile` run the DS compiler, `dsc`, which it does not bundle. It runs the first of `$DS_AST_DSC`, `$DS_MERCURY_DSC` and `dsc` on `PATH`. The `dsc` of the same DS release writes the trees it reads.

## Reference

The API is [`ds_ast` in The DS Bindings Reference](https://ds-lang.org/docs/latest/bindings/ds_ast/ds_ast.html).

## Project

- [ds-lang.org](https://ds-lang.org)
- [github.com/desert-sage/ds](https://github.com/desert-sage/ds)

## Licence

`BSD-4-Clause OR AGPL-3.0-or-later`: either licence, at the user's choice. `LICENSE` holds both texts.

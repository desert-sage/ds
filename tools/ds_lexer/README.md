<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# ds-lang-lexer

The Pygments lexer for Desert Sage (DS) rule source.

## Contents

One module, `ds_lexer`, holding `DSLexer`. Installing the package registers it with Pygments under the alias `ds`, so a `ds` code fence highlights wherever Pygments runs: Sphinx, Jupyter Book, MkDocs and the `pygmentize` command among them. `ds_lexer.setup` also loads it as a Sphinx extension.

## Install

```sh
pip install ds-lang-lexer
```

It runs on Python 3.11 or later, and needs Pygments 2.10 or later.

## Reference

The API is [`ds_lexer` in The DS Bindings Reference](https://ds-lang.org/docs/latest/bindings/ds_lexer/ds_lexer.html).

## Project

- [ds-lang.org](https://ds-lang.org)
- [github.com/desert-sage/ds](https://github.com/desert-sage/ds)

## Licence

`BSD-4-Clause OR AGPL-3.0-or-later`: either licence, at the user's choice. `LICENSE` holds both texts.

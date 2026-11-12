<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `ds_lexer`

## Lexer

### `DSLexer`

**`class DSLexer(pygments.lexer.RegexLexer)`**

The Pygments lexer for DS source.

| Attribute | Value |
|---|---|
| `name` | `"DS"` |
| `aliases` | `["ds"]` |
| `filenames` | `["*.ds"]` |
| `mimetypes` | `["text/x-ds"]` |

*(Source: tools/ds_lexer/ds_lexer.py)*

### Reserved word tokens

The words DS reserves are those of [LLEX.9.6], and each class of them takes one token type.

| Words | Token type |
|---|---|
| the words that open a file-level declaration, such as `schema`, `rule` and `import` | `Keyword.Declaration` |
| the words that head an action, such as `emit`, `publish` and `call` | `Keyword.Reserved` |
| `and`, `or`, `not`, `in`, `is`, `contains`, `overlaps` | `Operator.Word` |
| `true`, `false`, `null`, `inf`, `nan`, `NaN` | `Keyword.Constant` |
| the type names, such as `Int`, `Duration` and `Json` | `Keyword.Type` |
| the builtins and aggregations, and `p1` to `p99` | `Name.Builtin` |
| the reserved kwargs `filter`, `limit`, `nocooldown`, `retain` and `value` | `Keyword.Pseudo` |
| every other reserved word | `Keyword` |

A name after `.` is `Name.Attribute`, whatever word it spells.

*(Source: tools/ds_lexer/ds_lexer.py, Spec: [LLEX.9.6], [LLEX.9.8])*

### Other tokens

| Source | Token type |
|---|---|
| a `#` comment | `Comment.Single` |
| a triple-quoted string | `String.Doc` |
| a string | `String.Double` |
| a regex literal after a match operator | `String.Regex` |
| a hexadecimal, binary or octal literal | `Number.Hex`, `Number.Bin`, `Number.Oct` |
| a unit literal | `Number` |
| a float literal | `Number.Float` |
| a decimal integer literal | `Number.Integer` |
| any other name | `Name` |
| `;` | `Error` |

*(Source: tools/ds_lexer/ds_lexer.py, Spec: [LLEX.4.1], [LLEX.11.1], [LLEX.11.2], [LLEX.12], [LLEX.13], [LLEX.16.5], [LREG.5.1])*

### Pygments registration

**`[project.entry-points."pygments.lexers"] ds = "ds_lexer:DSLexer"`**

Installing `ds-lang-lexer` registers `DSLexer` with Pygments under the alias `ds`, so a `ds` code fence highlights wherever Pygments runs.

*(Source: tools/ds_lexer/pyproject.toml)*

## Sphinx

### `setup`

**`def setup(app)`**

Registers a `DSLexer` as Sphinx's lexer for `ds` when `ds_lexer` is loaded as a Sphinx extension.

It returns `{"version": "0.1", "parallel_read_safe": True, "parallel_write_safe": True}`. It imports `sphinx`, which `ds-lang-lexer` does not depend on.

*(Source: tools/ds_lexer/ds_lexer.py)*

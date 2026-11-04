<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Diagnostics

## Reporting

### `--diagnostics`

**`--diagnostics text`**, **`--diagnostics json`**

`--diagnostics` chooses how `compile` and `dump-ast` write their diagnostics to stderr: `text`, the default, renders them for a person, and `json` writes one document.

The format moves no [exit code](dsc.md#dsc-exit-codes).

*(Spec: [RCLI.3.2])*

### Multiple errors

A compile reports every error it finds within one stage of analysis, each as a separate diagnostic.

It may stop before a later stage once an earlier stage has failed.

*(Spec: [RCLI.5.3])*

### Diagnostic codes

Every `DS_VALIDATE_*` code a compiler emits is allocated in the registry `specs/registry/validate.ebnf`, and is matched by name.

The code's number is a registry key and never leaves a compiler. A code keeps its name and is never reused.

*(Spec: [RCLI.5.1], [RCLI.5.2])*

### Lexer errors

A lexer error is reported with its [position](../lang/lexical.md#lexer-error-position) and kind; recovery after it is implementation-defined.

*(Spec: [LLEX.15.3.1])*

## The JSON form

### JSON document

**`{"diagnostics": [ <diagnostic>... ]}`**

Under `json`, the compiler writes one document whenever it reports a diagnostic, holding every diagnostic the text form would render, in that order.

A refused program's errors and an accepted program's warnings are both reported. When the compiler reports none, it writes no document. A usage error and an internal compiler error are no diagnostics of the program, so the document carries neither, and a compiler that exits `3` writes none. Every object admits no other member.

*(Spec: [RCLI.3.2], Source: compiler/dsc_diagnostics.schema.json)*

### Diagnostic object

| Member | Type | Required | Meaning |
|---|---|---|---|
| `code` | string | yes | the code by name, matching `^DS_[A-Z0-9_]+$` |
| `severity` | `"error"` or `"warning"` | yes | |
| `message` | string | yes | wording, which a compiler may change |
| `hint` | non-empty string | no | wording, absent when there is none |
| `span` | span | yes | where the diagnostic points |
| `related` | array of `{message, span}` | yes | further locations, in the order named; empty when there are none |

A reader keys on `code` and `span`.

*(Spec: [RCLI.3.2], Source: compiler/dsc_diagnostics.schema.json)*

### Span

| Member | Type | Meaning |
|---|---|---|
| `file` | string | the [name](dsc.md#input-name) the compiler gives the source |
| `start` | `{line, column}` | the range's first code point |
| `end` | `{line, column}` | the position after its last |

`line` is 1-based, and `column` is 1-based in Unicode code points. A `dump-ast` node's `col_offset` is one less than the `column` of the same point.

*(Spec: [RCLI.1.10], [RCLI.3.2], Source: compiler/dsc_diagnostics.schema.json)*

## Catalogue

### Diagnostic catalogue

```{include} ../_generated/diagnostics.md
```

*(Spec: [RCLI.5.1], Source: specs/registry/validate.ebnf)*

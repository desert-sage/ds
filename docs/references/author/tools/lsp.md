<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `ds lsp`

## Server

### Command

**`ds lsp [-L DIR]...`**

`ds lsp` is a language server on stdin and stdout, for an editor.

`-L DIR`, or `--search-path DIR`, adds a library directory to every compile, after the document's own and any the editor gives. Accumulates. `-h` prints the usage.

The exit status is `0` after `shutdown`, and `1` if `exit` or the end of input comes without one.

*(Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/lsp/server.js)*

### Transport

Messages are framed by a `Content-Length` header, with a body of at most 64 MiB and a header of at most 8 KiB. Bytes past either limit, or a header with no `Content-Length`, end the session.

Requests are answered one at a time, in order. Document sync is full.

*(Source: tools/dsdb/lib/lsp/framing.js, tools/dsdb/lib/lsp/server.js)*

### Errors

| Code | When |
|---|---|
| `-32700` | a message that is not JSON |
| `-32600` | a message that is neither request nor notification, or a request after `shutdown` |
| `-32601` | a request the server does not answer |
| `-32002` | a request before `initialize` |
| `-32803` | a `textDocument/rename` refused |
| `-32603` | a failure while answering |

*(Source: tools/dsdb/lib/lsp/server.js)*

## Lifecycle

### `initialize`

**`initialize`**

`initialize` gives the server's capabilities.

The position encoding is `utf-32` where `general.positionEncodings` offers it, else `utf-16`.

| `initializationOptions` | Value |
|---|---|
| `libs` | library directories for every compile; a relative one is the root's |
| `docs` | where the rendered documentation is, a URL or a path; a relative path is the root's |

*(Source: tools/dsdb/lib/lsp/server.js, tools/dsdb/lib/lsp/positions.js)*

### `shutdown`

**`shutdown`**

`shutdown` answers null, and every later request is refused with `-32600`.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `exit`

**`exit`**

`exit` ends the server.

*(Source: tools/dsdb/lib/lsp/server.js)*

## Documents

### `textDocument/didOpen`

**`textDocument/didOpen`**

This holds the document and analyses it at once.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `textDocument/didChange`

**`textDocument/didChange`**

This replaces the text, and analyses it once 200 ms pass with no later change.

Any request but completion and signature help first analyses what is waiting. Until a source parses again, the last tree that parsed answers.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `textDocument/didSave`

**`textDocument/didSave`**

This analyses the document at once.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `textDocument/didClose`

**`textDocument/didClose`**

This drops the document and clears its diagnostics.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `workspace/didChangeWatchedFiles`

**`workspace/didChangeWatchedFiles`**

This analyses every open document, on the same wait as a change.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `textDocument/publishDiagnostics`

**`textDocument/publishDiagnostics`**

The server sends the compiler's diagnostics after each analysis, each with severity error, its code, source `ds lsp`, and a hint in its message.

An empty span is widened to one character. The codes are the [diagnostic catalogue](diagnostics.md#diagnostic-catalogue).

*(Source: tools/dsdb/lib/lsp/server.js)*

## Requests

### `textDocument/hover`

**`textDocument/hover`**

This gives Markdown for the name the program declares at the position, or for a builtin where it is called.

A builtin's hover gives each overload's signature, its summary and the clauses that define it, linked under `docs` where given.

*(Source: tools/dsdb/lib/lsp/server.js, tools/dsdb/lib/lsp/builtins.js)*

### `textDocument/definition`

**`textDocument/definition`**

This gives the declaration of the name at the position, in the same document.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `textDocument/references`

**`textDocument/references`**

This gives every site of the name at the position, in the program rooted at the document and every library it imports.

`context.includeDeclaration` false leaves the declaration out. An open library is read from the editor's text.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `textDocument/rename`

**`textDocument/rename`**

This gives a workspace edit of every site of the name at the position.

It is refused for a name that is not a DS name, a reserved word, a position that names nothing the program declares, or a site outside the workspace folders.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `textDocument/completion`

**`textDocument/completion`**

This gives completions at the position, from the last tree that parsed and the line's text.

The trigger characters are `.` and `:`.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `textDocument/signatureHelp`

**`textDocument/signatureHelp`**

This gives the signature of the call at the position, from the last tree that parsed and the line's text.

The trigger characters are `(` and `,`.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `textDocument/documentSymbol`

**`textDocument/documentSymbol`**

This gives the document's outline.

*(Source: tools/dsdb/lib/lsp/server.js)*

### `workspace/symbol`

**`workspace/symbol`**

This gives the matching symbols of every file an open document's program reaches.

A name matches when it holds the query's characters in order, in any case. An empty query matches every name.

*(Source: tools/dsdb/lib/lsp/server.js, tools/dsdb/lib/lsp/symbols.js)*

### `textDocument/semanticTokens/full`

**`textDocument/semanticTokens/full`**

This gives the document's tokens, one per line. A document that has not parsed still has its reserved words, literals and comments coloured.

| Legend | Values |
|---|---|
| `tokenTypes` | `namespace`, `type`, `struct`, `interface`, `function`, `variable`, `property`, `keyword`, `operator`, `string`, `number`, `comment` |
| `tokenModifiers` | `declaration`, `readonly`, `defaultLibrary`, `action`, `clause`, `constant` |

*(Source: tools/dsdb/lib/lsp/semantic.js, tools/dsdb/lib/lsp/server.js)*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Installing

## Release assets

A release's assets are on its release page. Verifying them is `SECURITY.md`'s.

*(Source: README.md, SECURITY.md)*

## `ds-tools-<version>.tgz`

```text
npm install -g --offline ./ds-tools-<version>.tgz
```

The DS tools package is one npm package, `@ds-lang/tools`, holding [dsdb](dsdb.md) on the wasm build of `@ds-lang/ds`, with the compiler and the standard library. The same package installs from npm with `npm install -g @ds-lang/tools`.

With `-g`, the install puts the command `ds` on `PATH`. Without it, the install puts the package at `node_modules/@ds-lang/tools` and `ds` at `node_modules/.bin/ds`, under the install prefix, where `npx ds` runs it. `ds` carries its [subcommands](dsdb.md#subcommands). The package bundles every dependency, and the install of the tarball fetches nothing. `ds` needs no `dsc` on `PATH` and no environment variable.

The package needs Node 20 or later. npm installs it on an older Node without refusing it, and `ds` then writes `ds: this is Node <v>; ds is tested on Node 20 and later, and may fail here` to stderr and runs.

*(Source: tools/dsdb/package.json, tools/dsdb/lib/cli/main.js, scripts/dsdb/pack.mjs, Release: ds-tools-<version>.tgz)*

## `ds-textmate-<version>.tar.gz`

The TextMate grammar for DS.

The archive holds `ds-textmate-<version>/`, with `ds.tmLanguage.json`, `LICENSE` and `PROVENANCE.txt`. The grammar's scope name is `source.ds`, and it declares the file type `ds`.

*(Source: tools/textmate-ds/ds.tmLanguage.json, Release: ds-textmate-<version>.tar.gz)*

## `ds-tree-sitter-<version>.tar.gz`

The tree-sitter grammar for DS.

The archive holds `ds-tree-sitter-<version>/`, with `grammar.js`, `tree-sitter.json`, `queries/highlights.scm`, `src/`, `test/corpus/`, `LICENSE` and `PROVENANCE.txt`. `src/` holds the generated parser `parser.c`, with `scanner.c`, `grammar.json`, `node-types.json` and `tree_sitter/`. The grammar's name is `ds`, its scope `source.ds`, and its file type `ds`.

*(Source: tools/tree-sitter-ds/tree-sitter.json, tools/tree-sitter-ds/grammar.js, Release: ds-tree-sitter-<version>.tar.gz)*

## `bin/dsc`

**`bin/dsc`, `share/ds/stdlib/`**

`bin/dsc` is the [DS compiler](dsc.md), shipped in a libds tarball. Not every libds tarball carries it: [Header and linking](inv:integrator:std:doc#conventions/linking) names the one that doesn't.

The library the compiler ships with sits beside it, as `.ds` files under `share/ds/stdlib/`, where [`dsc` finds it](dsc.md#bundled-library). The tarball's other contents and its link line are [Linking](inv:integrator:std:doc#conventions/linking). The `ds-lang` wheel also installs a `dsc` command, as [`pyds`](inv:bindings:std:doc#index) states.

*(Spec: [LIMP.3.3.1], [RCLI.1.11], [NGST.1.4], Source: bindings/c/Makefile, Release: ds-libds-<version>-<os>-<arch>.tar.gz)*

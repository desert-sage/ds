<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# @ds-lang/ds

The JavaScript binding to libds, the DS rule engine: one C glue
(`src/ds.c`), written to Node-API, compiled natively into a `.node`
module and by Emscripten into wasm32, under one ES module (`lib/`). Its
design is `../JS_BINDING.md`, its style canon `JS_STYLE.md`, and its parity
with the other bindings `../README.md`. Its wasm build ships inside the DS
tools package (`DISTRIBUTION.md`).

Requires Node 20 or later. Licensed under `BSD-4-Clause OR
AGPL-3.0-or-later`, at your choice.

## Building and testing from source

One script builds the module and runs its suite, from anywhere in the tree,
and reads nothing outside the public tree:

```sh
python3 scripts/js/check.py --libds runtime/src/libds/libds.a
python3 scripts/js/check.py --target wasm
```

Both targets need Node 20 or later, Python 3.12 or later, and the Mercury
`dsc` to compile the test fixtures: `--dsc PATH`, else `DS_MERCURY_DSC`, else
`dsc` on `PATH`.

**The native target** (the default) also needs a C compiler and a C++ driver
(`gcc`, `g++`), `pkg-config` with RE2's and protobuf-c's `.pc` files, and a
`libds.a` built from this tree, as `PORTING.md` at the repository root
describes.

**The wasm target** builds its own `libds.a`, so it needs what that takes:
emsdk 3.1.74, activated; `cmake`, GNU `make`, `curl`, `pkg-config` and
`cosign`, which verifies RE2's signature; and a native `protoc-c`
(protobuf-c 1.x), by `--protoc-c PATH`, else `PROTOC_C`, else `protoc-c` on
`PATH`.

The script, in order:

1. type-checks `lib/` with the pinned TypeScript, strict, and holds the
   declarations it writes to the committed `types/`;
2. compiles `test/fixtures/*.ds` with the `dsc`;
3. builds the module: on the native target, `build/ds.node` from the
   glue and `libds.a`, against the pinned Node-API headers; on the wasm
   target, Abseil, RE2 and protobuf-c at `vendor/deps.lock`'s pins, then
   `libds.a` and the same glue for wasm32, into `build/ds_wasm.mjs`;
4. runs every `test/*.test.mjs` under `node --test` on that target.

Each pinned package (the Node-API headers, emnapi, TypeScript and the Node
types, and the tokenizer and CLI the editor-grammar checks use) is fetched
and refused unless its digest matches. A verified one is kept in the
directory `DS_NPM_STORE` names and read from there first. Everything the
script writes goes under `.build/js/` and `bindings/js/build/`.

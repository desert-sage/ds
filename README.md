<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# Desert Sage

Desert Sage, DS for short, is a rule language for reactive orchestration over a bounded fact base. This
repository holds its specification, its compiler, its two runtimes, and its
bindings.

## Layout

```
specs/              the specification's source, one JSON file per clause
  language/         the DS language
  runtime/          the reference runtime
  impl/             libds's implementation
  integration/      the integrator contract
  conformance/      the conformance corpus
proto/              the status dictionary and the artefact formats
compiler/mercury/   dsc, the compiler
runtime/src/libds/  libds, the C runtime
runtime/mercury/    the Mercury runtime
bindings/           the language bindings, each with its design beside it
stdlib/             the standard library
tools/              the tools a user runs, dsdb, ds_lexer and ds_ast among them
formal/             the formal models
vendor/             third-party sources and the dependency pins
```

The documentation is five books:

| Directory | Book |
|---|---|
| `docs/specs/` | The DS Specification, its pages generated from `specs/` |
| `docs/references/author/` | The DS Author's Reference: writing `.ds` rules |
| `docs/references/integrator/` | The DS Integrator's Reference: the libds C API |
| `docs/references/bindings/` | The DS Bindings Reference: the Mercury, Python and JavaScript bindings |
| `docs/references/internals/` | The DS Internals Reference: the engine, artefact formats, the atom registry |

## Installing a release

| Who | Takes | Page |
|---|---|---|
| A rule author | `ds-tools-<version>.tgz`, or `bin/dsc` in a libds tarball | [Installing](https://ds-lang.org/docs/latest/author/tools/install.html) |
| A C integrator | `ds-libds-<version>-<os>-<arch>.tar.gz` | [Header and linking](https://ds-lang.org/docs/latest/integrator/conventions/linking.html) |
| A Python program | `ds_lang-<version>-cp312-abi3-<platform>.whl` | [The DS Bindings Reference](https://ds-lang.org/docs/latest/bindings/index.html) |
| A JavaScript program | `@ds-lang/ds`, from npm | [The DS Bindings Reference](https://ds-lang.org/docs/latest/bindings/index.html) |

A release's assets are on its release page, and verifying them is `SECURITY.md`'s.

## Building

The source bundle, `ds-src-<version>.tar.gz`, builds with make and each
language's own build system. It unpacks to `ds-<version>/`; every command below
runs from there. Every release is built with these commands on amd64 Linux, in
the images below, and the result recorded.

### Prerequisites

The Dockerfiles in `runtime/docker/` are the statement of what the build needs.
Their `COPY` paths are relative to the bundle's root. In `FROM` order:

| Image | Dockerfile | `FROM` | Installs |
|---|---|---|---|
| `ds-base` | `ds-base.Dockerfile` | `python:3.14-slim`, by digest | gcc and g++ 14.2.0, binutils 2.44 and the packages it lists, from a Debian snapshot; glibc 2.41's link-time half, built; meson, meson-python, ninja and the Python packages it lists; clang 22.1.8; cosign; Mercury 22.01.8, grade `hlc.gc` |
| `ds-deps` | `ds-deps.Dockerfile` | `BASE`, default `ds-base:latest` | Abseil, RE2, protobuf and protobuf-c, by `scripts/vendor/vendor.py`, in `/opt/ds-deps/vendor`; Abseil and RE2 shared on the default paths; the `google-re2` binding |
| `ds-python` | `ds-python.Dockerfile` | `BASE`, default `ds-deps:latest` | CPython 3.12.15 as `python3`, and its Python toolchain |
| `ds-build` | `ds-build.Dockerfile` | `BASE=ds-python:latest` | setuptools, wheel, jupyter-book |
| `ds-emsdk` | `ds-emsdk.Dockerfile` | `BASE=ds-python:latest` | Emscripten 3.1.74; wasm32 Abseil and RE2 in `/opt/ds-wasm32`; wasm32 Mercury, grade `hlc`, in `/opt/mercury-wasm32`; setuptools, wheel. amd64 and arm64 only |

`ds-build` and `ds-emsdk` default to `BASE=ds-deps:latest`, which leaves out
`ds-python`; pass `--build-arg BASE=ds-python:latest`. `ds-emsdk`'s `EM_CACHE`
names a directory under `/ds-cache`, which must be writable when it runs.

`ds-build` builds every part below but the last, and `ds-emsdk` builds the last.
Without Docker, install what the Dockerfiles for that part install.

### Commands

`<protobuf-c>` is the fifth column of protobuf-c's row in `manifest.tsv`, which
`python3 scripts/vendor/vendor.py --write-manifest` writes in the vendor store: in the images
`/opt/ds-deps/vendor`, otherwise `DS_VENDOR_STORE`, or `/ds-cache/vendor` where
`/ds-cache` exists.

libds, to `runtime/src/libds/libds.a`:

```sh
make -j "$(nproc)" -C runtime/src/libds \
    PROTOC_C=<protobuf-c>/bin/protoc-c CFLAGS_EXTRA=-I<protobuf-c>/include
```

`dsc` to `.build/mdsc/dsc_cli`, the standard library to
`.build/share/ds/stdlib`, and the Mercury suites to `.build/mdsc/test_dsc` and
`.build/mercury/runtime/test_ds`:

```sh
make -j "$(nproc)" -f mercury.mk all test_dsc test_ds
```

The C binding's example, built and run, where `<tarball>` is the unpacked
`ds-libds-<version>-linux-glibc-amd64.tar.gz`:

```sh
make -j "$(nproc)" -C bindings/c DS=<tarball> check
```

pyds, after libds and `dsc`, and its harness:

```sh
PKG_CONFIG_PATH=<protobuf-c>/lib/pkgconfig python3 -m pip install \
    --no-build-isolation --no-deps --target <dir> bindings/python
PYTHONPATH=<dir> DS_MERCURY_DSC="$PWD/.build/mdsc/dsc_cli" \
    python3 bindings/python/examples/harness.py
```

The Mercury binding and runtime, installed under `.build/mercury_ds/prefix/` and
`.build/mercury/prefix/`; a program's build against them is in
`bindings/mercury/README.md`:

```sh
make -j "$(nproc)" -f mercury.mk all mercury
```

The wasm32 libds, the JavaScript binding's glue, the wasm32 `dsc`, and
`ds-tools-<version>.tgz` in `<dir>`, in `ds-emsdk`:

```sh
python3 scripts/dsdb/check.py --target wasm \
    --protoc-c <protobuf-c>/bin/protoc-c \
    --mmc-wasm32 /opt/mercury-wasm32/bin/mmc --pack <dir>
```

### build-unit

build-unit is needed only to reproduce DS's own builds byte for byte. It is
published at `github.com/desert-sage/build-unit`.

### Build files

| What | Build file |
|---|---|
| `libds.a` | `libds.build`, or `runtime/src/libds/Makefile` |
| the `pyds` Python binding | `bindings/python/meson.build` |
| the formal models | `formal/formal.build` |

Building on a platform with no release asset: `PORTING.md`.

## Versions

A release is `<major>.<minor>.<patch>`, and each `<major>.<minor>` series is a
**release line**.

- **Within a line, artefacts carry over.** A runtime accepts a `.dsc` or a
  `.dstrace` whose recorded version begins with its own `<major>.<minor>.`, and
  refuses every other ([LDET.1.10]). So a patch release fixes; it does not
  change what a compiled program or a recorded stream means.
- **Across lines, nothing carries.** A new line may change the language or a
  format, and moving to it means recompiling programs and recording streams
  afresh. This holds from 1.0.0 on as it did before it.

## Release signing

Releases are signed. The current signing key's fingerprint is

```
A1FF 7995 2433 37AE 056D  3FCD 2F31 8A97 E9CA E307
```

and its public half is in `KEYS`. How to verify a release, and what an expired
key means for an older one: `SECURITY.md`.

## Scope

- **In scope:** the DS language (grammar, semantics, type rules, formal models)
  and its runtimes (the Rete engine, lowering, storage integration, debugging,
  testing, metrics).
- **Out of scope:** what `specs/language/SCOPE/` lists under "What DS is not
  for".

## Who reads what

- **Rule authors:** `docs/references/author/`.
- **Integrators:** `docs/references/integrator/`, and
  `docs/references/bindings/` for a binding.
- **Implementers:** `specs/language/` states what DS guarantees, and
  `specs/runtime/` how the reference runtime delivers it.

## Reading order

The specification, by `specs/` directory:

1. `language/SCOPE`: what DS is for and what it is not.
2. `language/DETERMINISM`: the same rules and fact stream give the same output,
   bit for bit, on any conforming platform.
3. `language/TESTING`: testing as a language concern.
4. `language/DEBUGGING`: what a rule author can observe.
5. `language/FACT_MODEL`, `LOGICAL_FACTS`, `EXPRESSIONS`, `SERIES`, `STORAGE`
   and `CALL_RESPONSE`: the semantic core.
6. `runtime/ARCHITECTURE`: the reference runtime's shape.

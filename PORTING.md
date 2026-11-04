<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Porting DS to a new platform

This describes the cold start: how to build `libds.a`, then `pyds`, then the
compiler, on a machine that has no DS toolchain.

## First, check whether you need it

**If a release asset matches your platform, you do not.** Each release ships a
`libds` tarball per supported platform row (`libds.a`, the headers and, on most
rows, the compiler as `bin/dsc`), and a `ds-lang` wheel per build host, which
installs `pyds` and carries the same compiler at `pyds/bin/dsc`. If the wheel
matches your platform and interpreter:

    pip install ds_lang-<version>-*.whl

That is the whole bring-up. The rest of this document is for the case where
nothing matches: a platform DS does not publish for, an interpreter it does not
build for, or a tree you need to build entirely from source.

## Why there is a cold start at all

DS's own builds are driven by build-unit, a build system that is itself a DS
program: it runs in a `pyds` engine, and `pyds` links `libds.a`. So building
`libds.a` that way requires `libds.a` to already exist. build-unit is released
separately, on its own cycle, and no build in this document needs it.

One artifact breaks that circle: `runtime/src/libds/Makefile`. It is **generated
from `libds.build`**, the same graph build-unit builds, and committed,
because at cold start there is nothing that could generate it. Every compile
option in it is read out of that graph, so there is one description of how to
build `libds.a`, not two. DS's release rows build the archive with build-unit,
not with this Makefile. The release build checks the Makefile from the source
bundle: the archive it makes must carry the bundle's `VERSION`, a second `make`
must find nothing to rebuild, and a program linked against it must run. No gate
compares the two archives' bytes.

Do not edit it. If it is wrong on your platform, report it: a local edit is
erased the next time it is regenerated.

## What you need

* **GNU Make** (3.81 or newer).
* **A C compiler** supporting C99.
* **A C++ compiler** supporting C++17, for the one C++ translation unit
  (`ds_re2.cc`, which wraps RE2).
* **`ld` and `ar`**.
* **`protoc-c`**, the protobuf-c compiler, plus the protobuf-c headers and
  runtime it pairs with. Take both from one place: the generated `.pb-c.c`
  carries version guards against the `libprotobuf-c.h` it is compiled against,
  and mixing a system compiler with a vendored runtime (or the reverse) fails in
  ways that are hard to read.
* **RE2 and its Abseil dependency**, headers and library. RE2 *is* the regex
  language DS specifies, so this is not an optional backend (but see
  [Without RE2](#without-re2)).
* **`python3`**, optionally, for the version stamp (below).

For `pyds` you will also need **Python 3.12 or newer**
(`bindings/python/pyproject.toml`; the base image `ds-base.Dockerfile` starts
from carries 3.14, and `ds-python.Dockerfile` makes 3.12.15 `python3` above it),
**meson** (1.4 or newer), **meson-python** (0.18 or newer), **ninja**, **pkg-config**, and
**`protoc`**, the protobuf compiler, of a version the pip `protobuf` package
beside it accepts: the generated Python modules check it at import.

## Building `libds.a`

Run Make **from the libds directory**. The recipes use paths relative to it:

    cd runtime/src/libds
    make

That writes `libds.a` beside the sources.

**The archive stamps its version.** `VERSION` defaults to what
`scripts/build/ds-version.py` derives: the repository's `VERSION` file, followed by
`+` and the commit's sha in a git checkout. Without `python3` it is the
`VERSION` file alone. A runtime loads only the artefacts a compiler of its own
`<major>.<minor>.` series wrote, so the stamp is not cosmetic: a `libds.a`
built with no version loads nothing a released compiler writes.

## The knobs

Every option the graph exposes reaches the Makefile as a Make variable. Set them
on the command line or in the environment; either wins over the built-in default.

| Variable       | What it sets                                              |
|----------------|-----------------------------------------------------------|
| `CC`           | the C compiler                                            |
| `CXX`          | the C++ compiler                                          |
| `LD`           | the linker, used for partial links (`ld -r`)              |
| `AR`           | the archiver                                              |
| `AR_FLAGS`     | its flags                                                 |
| `PROTOC_C`     | the protobuf-c compiler, absolute path if it is not on PATH |
| `CFLAGS_EXTRA` | extra compile flags — where `-I` for out-of-tree headers goes |
| `ALLOC_MODE`   | the allocation-routing mode                               |
| `ALLOC_HEADER` | an integrator header the allocation macros resolve to     |
| `VERSION`      | the version string compiled into the archive              |

A cross build sets the toolchain together, archiver included:

    make CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ \
         LD=aarch64-linux-gnu-ld AR=aarch64-linux-gnu-ar

If RE2 and protobuf-c live somewhere the compiler does not look:

    make CFLAGS_EXTRA="-I/opt/re2/include -I/opt/abseil/include" \
         PROTOC_C=/opt/protobuf-c/bin/protoc-c

## Without RE2

`Makefile.re2-stub`, beside the Makefile and generated from the same graph,
builds `libds.a` with `port/ds_re2_stub.c` in place of the RE2 wrapper, and
links no C++:

    cd runtime/src/libds
    make -f Makefile.re2-stub

**That archive declines the `regex` form.** It is conformant only for a dialect
that disables the form, under which the compiler refuses `~` and `!~`. Use it
for a target without a C++ toolchain or without RE2; do not ship it as a
general `libds.a`.

## Building `pyds`

From the repository root, once `libds.a` is built:

    pip install ./bindings/python

It finds the archive in `runtime/src/libds`, and RE2 and protobuf-c through
**pkg-config**. So if you built either into a prefix the system does not know
about, put that prefix on `PKG_CONFIG_PATH` — the same one you passed as `-I`
above. This matters more than it looks: `_pyds.so` links RE2 into itself, so
resolving those symbols against a different RE2 than `libds.a` was compiled
against is a header and library skew, not merely an unpinned choice.

If those are static, position-independent builds rather than your
distribution's shared libraries, say so:

    pip install -Csetup-args=-Dvendored=true ./bindings/python

## The compiler

`dsc`, the DS compiler, is a Mercury program. The simplest course is to take
`bin/dsc` from a release `libds` tarball of the **same release** as your tree:
it is linked statically against everything but the C library, and a runtime
loads only what a compiler of its own `<major>.<minor>.` series wrote.

To build it from source, `mercury.mk` at the repository root is the build,
generated from `mercury.build`. That needs, besides the C and C++ toolchain and
RE2 above:

* **Mercury 22.01.8** with `hlc.gc` as its default grade, `mmc` and the rest of
  its `bin/` on `PATH`.
* **`python3`**, for `scripts/build/gen_version_module.py`.
* **GNU Make**, and C and C++ compilers as `cc` and `g++`.

Then, from the repository root:

    make -f mercury.mk all

That writes the compiler to `.build/mdsc/dsc_cli`, linked against the system's
RE2 rather than statically, and the standard library to
`.build/share/ds/stdlib`. The target `test_ds` builds the second runtime's test
program (`.build/mercury/runtime/test_ds`). The target `mercury` installs the
Mercury runtime as the library `mercury_ds_runtime` under
`.build/mercury/prefix/`
(`.build/mercury/prefix/lib/mercury/lib/hlc.gc/libmercury_ds_runtime.a`), for
a Mercury program to link with `--mld .build/mercury/prefix/lib/mercury --ml
mercury_ds_runtime`.

`pyds.compile()` runs the compiler `DS_MERCURY_DSC` names, then one bundled in
the package, then `dsc` on `PATH`. To bundle it, as the release wheels do:

    pip install -Csetup-args=-Ddsc=/abs/path/to/dsc ./bindings/python

## What this does not cover

**Embedded targets.** The embedded ports name the sources in their own build
files and compile only the C, with `port/ds_re2_stub.c` for the RE2 wrapper,
the configuration `Makefile.re2-stub` builds.

**Reproducibility is not claimed.** No gate compares the bytes of two builds.
What the release build checks of a build from the source bundle is in
[Why there is a cold start at all](#why-there-is-a-cold-start-at-all).

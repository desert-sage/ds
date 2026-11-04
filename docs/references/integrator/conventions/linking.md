<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Header and linking

## Release tarball

**`ds-libds-<version>-<os>-<arch>.tar.gz`**

The native libds archive for one platform, with its header.

`<os>` names the operating system, and on Linux its C library as well: `linux-glibc`, `linux-musl`. `<arch>` names the instruction set the archive is compiled for, not the machine's name: `rv64gc`, not `riscv64`. A program takes the tarball whose `<os>` and `<arch>` name the platform it is built for.

The tarball unpacks to one directory, `ds-libds-<version>-<os>-<arch>`. It holds `include/` ([`libds.h`](#libdsh)), `lib/` ([Linking](#linking-libdsa)) and `PROVENANCE.txt`. A tarball that ships the compiler holds `bin/dsc`, as in [Installing](inv:author:std:doc#tools/install).

*(Spec: [NGST.1.1], Source: bindings/c/Makefile, build.ini, Release: ds-libds-<version>-<os>-<arch>.tar.gz)*

## Debug pack

**`ds-libds-<version>-<os>-<arch>-debug.tar.gz`**

A libds tarball with its debug information kept.

A release ships one beside each libds tarball, named as the tarball is with `-debug` before `.tar.gz`. It comes from the same build and differs from the tarball only in this: its `lib/libds.a`, and its `bin/dsc` where the tarball has one, keep their debug information. The tarball's are stripped of it and keep their symbols, and both link and run alike. A program links against the one or the other, not both.

*(Spec: [NGST.1.4])*

## wasm32 tarball

**`ds-libds-<version>-emscripten-wasm32-regex.tar.gz`**

The libds archive for wasm32, linked into a module.

It carries no `bin/dsc` and no standard library. The compiler comes from a native tarball.

*(Spec: [NGST.1.4])*

## `libds.h`

The one public header of libds, and the whole of its stable surface.

A release tarball ships it as `include/libds.h`. Four internal headers ship under `include/internal/` (`sha256.h`, `rfcs/rfcs.h`, `rfcs/atoms.h`, `ds_re2.h`) and carry no API-stability guarantee. No other libds header is on the integrator include path.

*(libds.h: opening comment, Spec: [IARC.1.4], [NGST.1.1], [NTST.12.3])*

## Version macros

**`DS_VERSION_MAJOR`, `DS_VERSION_MINOR`, `DS_VERSION_PATCH`, `DS_VERSION_STRING`**

The release the header belongs to, in its clean form: three numbers, with no pre-release or build suffix.

| Macro | Value |
|---|---|
| `DS_VERSION_MAJOR` | the major number, a decimal integer literal |
| `DS_VERSION_MINOR` | the minor number, a decimal integer literal |
| `DS_VERSION_PATCH` | the patch number, a decimal integer literal |
| `DS_VERSION_STRING` | a string literal: the three numbers, in that order, joined by `.` |

The three numbers are usable in a preprocessor `#if`.

In a libds a release ships, the `libds_version` from [`ds_engine_get_platform_signature`](../determinism/provenance.md#ds_engine_get_platform_signature) and the `ds_version` in a recording's [header](../determinism/provenance.md#ds_session_header_t) begin with `DS_VERSION_STRING` followed by `+`. What follows the `+` names the build.

*(libds.h: version block, Spec: [NDET.2.4])*

## Use from C++

Under `__cplusplus`, `libds.h` declares its API inside `extern "C"`, and `DS_OK_R` and `DS_ERR_R` expand to `ds_result_t{ … }` in place of a compound literal.

*(libds.h: `extern "C"` block, Result type)*

## Linking `libds.a`

A program compiles against `include/libds.h` and links `lib/libds.a` and `lib/libprotobuf-c.a`, plus the platform libraries the tarball names for its row, in the `[link]` section of its `PROVENANCE.txt`, as the link line the row was tested with.

Link with a C++ driver: `libds.a` carries C++ objects, and a C driver leaves their runtime unresolved.

[`ds_engine_load_dsc`](../engine/loading.md#ds_engine_load_dsc) requires `libprotobuf-c.a`. A `pthread` in the row's list is a libc or toolchain need: libds makes no `pthread_*` call. Test binaries link the same artefacts as production binaries. `libds.a` is built with `-fPIC`, and links into a shared object.

*(Spec: [NGST.1.1], [NGST.3.1], [NTST.12.1], [IARC.7.1.1], [IARC.7.6])*

## Building `libds.a` from source

The generated `runtime/src/libds/Makefile` builds `runtime/src/libds/libds.a`, the archive a tarball ships as `lib/libds.a`.

Run it from that directory, with a C compiler, a C++17 compiler and `protoc-c` on the path and RE2's headers available. It takes its version from the tree's `VERSION` file, and the archive loads artefacts compiled by the same release.

*(Spec: [NGST.1.2])*

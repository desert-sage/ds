# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# ds-emsdk — ds-python plus the Emscripten SDK, for the wasm release rows.
#
# Its own image because emsdk exists for amd64 and arm64 only. A host that
# cannot have it has no `ds-emsdk` row in build.ini's [caps], and placement keeps
# the wasm rows off it.
#
# The toolchain comes to the supported image, not the other way round: the wasm
# rows run this repository's tooling on ds-python's 3.12, and emscripten's own
# image is Ubuntu 22.04 with Python 3.10.
#
# Above ds-deps because a cross build needs the native set too. The wasm rows
# build their own prefixes with emcc, but `protoc-c` is a build-host tool: the
# wasm protobuf-c is configured --disable-protoc, so `vendor.protoc_c()` takes
# the generator from DS_VENDOR_NATIVE_STORE, ds-deps' /opt/ds-deps/vendor.
ARG BASE=ds-python:latest
FROM ${BASE}

# ── Emscripten ───────────────────────────────────────────────────────────────
#
# Pinned to the 3.1.74 ds-website builds with, so the release asset and the
# website's build use one toolchain.
#
# Pinned by COMMIT, not by tag: `emsdk install <version>` reads the SDK manifest
# out of the checkout, so the checkout decides what a version string resolves
# to. A tag is a moving reference to that manifest; a commit is not.
ARG EMSDK_VERSION=3.1.74
# `refs/tags/3.1.74` in emscripten-core/emsdk, resolved through the GitHub API.
# Verify with:
#   curl -fsSL https://api.github.com/repos/emscripten-core/emsdk/git/ref/tags/3.1.74
ARG EMSDK_COMMIT=3d6d8ee910466516a53e665b86458faa81dae9ba
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64|aarch64) ;; \
        *) echo "ds-emsdk: emsdk publishes no toolchain for $(uname -m) — this image is amd64/arm64 only, which is why it is not ds-build" >&2; exit 1 ;; \
    esac; \
    git clone --filter=blob:none https://github.com/emscripten-core/emsdk.git /emsdk; \
    git -C /emsdk checkout --detach "$EMSDK_COMMIT"; \
    test "$(git -C /emsdk rev-parse HEAD)" = "$EMSDK_COMMIT" || { echo "emsdk: HEAD is not the pinned $EMSDK_COMMIT" >&2; exit 1; }; \
    /emsdk/emsdk install "$EMSDK_VERSION"; \
    /emsdk/emsdk activate "$EMSDK_VERSION"; \
    rm -rf /emsdk/.git

# The activation script sets EMSDK, PATH and the tool variables. Sourced into
# ENV rather than left to a shell profile because build-unit direct-execs each
# step's argv with no login shell, so a profile would reach nothing.
ENV EMSDK=/emsdk
ENV PATH=/emsdk:/emsdk/upstream/emscripten:/emsdk/node/current/bin:${PATH}

# `wasm-ld` is not on PATH after activation, and libds.build needs it by name:
# the graph combines each subdirectory with `$(LD) -r`, and the host `ld` cannot
# read wasm objects.
ENV DS_WASM_LD=/emsdk/upstream/bin/wasm-ld

# emcc builds its system libraries (libc, libc++, compiler-rt for wasm) on first
# use and caches them. Steps run as the ssh user (`[docker] run-as = ssh-user`),
# who cannot write inside the image, so the cache is the host's /ds-cache, which
# every step mounts and the ssh user owns: built once per host and emsdk
# version, shared by every wasm step. emcc locks the cache, so two steps filling
# it at once wait for each other.
ENV EM_CACHE=/ds-cache/emscripten/${EMSDK_VERSION}

# The cmake toolchain file. `scripts/vendor/vendor.py` cross-compiles only for a step that
# names it (the wasm rows set it per step in release.build); it then adds
# -DCMAKE_TOOLCHAIN_FILE and -DCMAKE_FIND_ROOT_PATH to the cmake rows and
# --host/--disable-protoc to the autotools one.
ENV EMSDK_TOOLCHAIN=/emsdk/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake

# The packaging tools ds-build carries: a wasm row packs its artifact with the
# same `scripts/private/release/build_libds_tarball.py` every libds row runs.
RUN pip install --no-cache-dir setuptools wheel

# ── the wasm32 `dsc`'s toolchain ─────────────────────────────────────────────
#
# The cross toolchain comes with the image, as ds-base brings the native
# Mercury and ds-deps the native RE2, and mercury.build's wasm32 `dsc` steps
# take it by their knobs (`mmc_wasm32`, `wasm32_deps`). So the graph states
# DS's own build and flags, and this file is the statement of what that build
# needs.
#
# Both builds compile with emcc, whose cache is the host's /ds-cache at run
# time (EM_CACHE above). Here nothing is mounted, so each RUN gives emcc a
# cache of its own and removes it: the objects installed do not depend on it.
COPY scripts/vendor/vendor.py      /wasm32-src/scripts/vendor/
COPY vendor/deps.lock                   /wasm32-src/vendor/
COPY scripts/vendor/mercury-wasm32.py   /wasm32-src/

# Abseil and RE2 for wasm32, from deps.lock's pinned and verified sources,
# through vendor.py's own cross recipe (DS_VENDOR_TOOLCHAIN_FILE), into a store
# of their own: the native set's store key cannot be shared with a cross one.
# `re2` and `abseil` beside the store name each prefix by a path that does not
# move with a key. `re2-link.rsp` is the static link line, as a wasm-ld
# response file (`-Wl,@re2-link.rsp`): libre2.a and every Abseil archive in one
# group, so wasm-ld resolves their mutual references without pkg-config's
# order, whose `-pthread` a wasm32 link without threads refuses. wasm-ld's
# form, not emcc's: `mmc` reads an argument beginning `@` as a response file of
# its own, so the link names it inside `-Wl,` where `mmc` passes it through.
RUN set -eu; \
    cd /wasm32-src; \
    export EM_CACHE=/opt/ds-wasm32/build/emcache; \
    export DS_VENDOR_STORE=/opt/ds-wasm32/vendor; \
    export DS_VENDOR_WORK=/opt/ds-wasm32/build/vendor-work; \
    export DS_VENDOR_TOOLCHAIN_FILE="$EMSDK_TOOLCHAIN"; \
    export CC=emcc CXX=em++ AR=emar; \
    mkdir -p /opt/ds-wasm32/build; \
    for d in abseil re2; do \
        python3 scripts/vendor/vendor.py "$d" "/opt/ds-wasm32/build/$d.stamp"; \
    done; \
    for d in abseil re2; do \
        set -- "$DS_VENDOR_STORE/$d"-*; \
        test "$#" -eq 1 || { echo "ds-emsdk: expected one wasm32 $d prefix, found $#" >&2; exit 1; }; \
        test -f "$1/.vendor-ok" || { echo "ds-emsdk: $1 is not installed" >&2; exit 1; }; \
        ln -s "$1" "/opt/ds-wasm32/$d"; \
    done; \
    test -f /opt/ds-wasm32/re2/lib/libre2.a; \
    { echo "--start-group"; \
      echo /opt/ds-wasm32/re2/lib/libre2.a; \
      ls /opt/ds-wasm32/abseil/lib/*.a | LC_ALL=C sort; \
      echo "--end-group"; } > /opt/ds-wasm32/re2-link.rsp; \
    test "$(grep -c 'libabsl_' /opt/ds-wasm32/re2-link.rsp)" -gt 0; \
    rm -rf /opt/ds-wasm32/build

# Mercury for wasm32-unknown-emscripten, grade `hlc` (no collector), into a
# prefix that borrows ds-base's native executables (Mercury's README.cross).
# The SAME Mercury as ds-base's: its version and digest, repeated here because
# an ARG does not cross a FROM. README.cross's configure answers for an
# emscripten host follow: emcc is clang, and the LLDS-only answers are "no".
# `mercury-wasm32.py` makes the Boehm rule a no-op and admits clang to four
# boxing guards (its header says why), and refuses if any edit does not match
# exactly once. The in-tree build uses the bootstrap grade whatever configure
# says, so the grade is passed to every mmake.
#
# THE HEAP IS CHECKED. `hlc` has no collector: every allocation bumps one fixed
# heap zone, 32 MB on wasm32, and nothing is freed. The zone's only guard is an
# mprotect'd redzone, and WebAssembly has no page protection, so unchecked, a
# compile past the zone writes over whatever lies beyond it.
# `MR_CHECK_FOR_OVERFLOW` is Mercury's own switch (mercury_conf_param.h). It
# makes `MR_heap_overflow_check()`, which every no-GC allocation runs before
# the new object is written, a fatal "heap overflow" (mercury_overflow.h). It
# is a C compile flag and no grade component, so it covers exactly the code
# compiled with it: the runtime and library here, through `EMCC_CFLAGS` on
# every emcc the build runs, and `dsc_cli`'s own C, through mercury.build's
# wasm32 link. The image refuses to build unless the installed library carries
# the check.
ARG MERCURY_VERSION=22.01.8
ARG MERCURY_SHA256=a097e8cc8eca0152ed9527c1caf73e5c9c83f6ada1d313a25b80fe79072fbad8
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) build=x86_64-pc-linux-gnu ;; \
        aarch64) build=aarch64-unknown-linux-gnu ;; \
        *) echo "ds-emsdk: no Mercury build triple for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    work=/opt/ds-wasm32/build; src="$work/mercury-src"; \
    mkdir -p "$src"; \
    export EM_CACHE="$work/emcache"; \
    curl -fsSL "https://dl.mercurylang.org/release/mercury-srcdist-${MERCURY_VERSION}.tar.gz" \
        -o "$work/mercury.tar.gz"; \
    echo "${MERCURY_SHA256}  $work/mercury.tar.gz" | sha256sum -c -; \
    tar -xzf "$work/mercury.tar.gz" -C "$src" --strip-components=1; \
    cd "$src"; \
    export CC=emcc AR=emar RANLIB=emranlib MMAKE_DIR="$src/scripts"; \
    export mercury_cv_cc_type=clang mercury_cv_siginfo_t=no mercury_cv_pc_access=no \
           mercury_cv_is_bigender=no mercury_cv_is_littleender=yes \
           mercury_cv_normal_system_retval=yes mercury_cv_can_do_pending_io=no \
           mercury_cv_gcc_labels=no mercury_cv_asm_labels=no \
           mercury_cv_gcc_model_fast=no mercury_cv_gcc_model_reg=no \
           mercury_cv_cannot_use_structure_assignment=no; \
    sh configure --build="$build" --host=wasm32-unknown-emscripten --with-cc=emcc \
        --enable-libgrades=hlc --with-default-grade=hlc \
        --disable-gc-mmap --disable-gc-munmap --prefix=/opt/mercury-wasm32; \
    python3 /wasm32-src/mercury-wasm32.py "$src"; \
    export EMCC_CFLAGS=-DMR_CHECK_FOR_OVERFLOW; \
    mmake GRADE=hlc dep_library; \
    mmake -j"$(nproc)" GRADE=hlc library; \
    mmake GRADE=hlc install_scripts install_runtime install_library install_config; \
    unset EMCC_CFLAGS; \
    sh tools/copy_mercury_binaries /opt/mercury /opt/mercury-wasm32; \
    cd /; rm -rf "$work" /wasm32-src; \
    test -x /opt/mercury-wasm32/bin/mmc; \
    std="$(find /opt/mercury-wasm32 -name libmer_std.a | head -n 1)"; \
    test -n "$std" || { echo "ds-emsdk: no libmer_std.a installed" >&2; exit 1; }; \
    grep -aq 'heap overflow' "$std" \
        || { echo "ds-emsdk: $std carries no heap check: MR_CHECK_FOR_OVERFLOW did not reach the library" >&2; exit 1; }

RUN set -eu; \
    emcc --version; \
    test -x "$DS_WASM_LD"; \
    test -f "$EMSDK_TOOLCHAIN"; \
    python3 --version; \
    /opt/mercury-wasm32/bin/mmc --version; \
    test -f /opt/ds-wasm32/re2-link.rsp

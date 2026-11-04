# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# ds-deps — the vendored set (abseil, re2, protobuf, protobuf-c) for the glibc
# lineage, built once and inherited by everything that links it.
#
# ── EDITING THIS FILE REBUILDS NOTHING
#
# The image's tag is the id in runtime/docker/ds-deps.pin and nothing else: not
# this file, not the scripts it copies. A change here reaches a host only when
# that id changes, or on a host building ds-deps for the first time. To make a
# change reach the image, give it a new id in ds-deps.pin, which says how. A
# ds-base change is refused until the pin names it, because ds-base is what this
# image and everything on it compile with.
#
# From ds-base, so the set is compiled by the gcc that builds and ships DS. In
# the chain base -> deps -> build, so every descendant has the prefixes.
ARG BASE=ds-base:latest
FROM ${BASE}

# ── THE BUILD CONTEXT
#
# The only image with a context: `images.py` pipes a small tarball for it. The
# files keep their repo-relative paths, because vendor.py finds the lock
# relative to itself. `ADD <git-url>#<commit>:<subdir>` is not used: older
# BuildKit daemons in the fleet do not support the subdir form.
COPY scripts/vendor/vendor.py        /deps-src/scripts/vendor/
COPY vendor/deps.lock                     /deps-src/vendor/

# The store every descendant finds. `/ds-cache/vendor` is vendor.py's default
# where there is no image.
ENV DS_VENDOR_STORE=/opt/ds-deps/vendor

# The same path under a second name. A cross step repoints `DS_VENDOR_STORE` at
# its own mounted store but still needs the native set: `protoc-c` is a
# build-host tool, and a cross protobuf-c ships none. This one is never
# repointed; `vendor.native_store_dir()` is its only reader.
ENV DS_VENDOR_NATIVE_STORE=/opt/ds-deps/vendor

# vendor.py's order: re2 and protobuf need abseil, protobuf-c needs protobuf.
# `all` re-checks every prefix and refuses its stamp when one is missing.
#
# The manifest is what consumers read instead of recomputing a store key with
# their own compiler. It is written last, so a half-built store has none.
#
# No /tmp, inside containers either: scratch goes under /opt/ds-deps/build and
# is removed in the same RUN.
RUN set -eu; \
    mkdir -p /opt/ds-deps/build; \
    cd /deps-src; \
    for d in abseil re2 protobuf protobuf-c; do \
        python3 scripts/vendor/vendor.py "$d" "/opt/ds-deps/build/$d.stamp" "/opt/ds-deps/build/$d.attest.tsv"; \
    done; \
    python3 scripts/vendor/vendor.py all /opt/ds-deps/build/all.stamp; \
    python3 scripts/vendor/vendor.py --write-manifest; \
    cat /opt/ds-deps/build/*.attest.tsv > /opt/ds-deps/vendor-attest.tsv; \
    cat /opt/ds-deps/vendor/manifest.tsv; \
    rm -rf /deps-src /opt/ds-deps/build vendor-work

# Four rows plus a header, every named prefix installed, checked in the layer
# that produced them.
RUN set -eu; \
    test "$(grep -c . /opt/ds-deps/vendor/manifest.tsv)" -eq 5; \
    cut -f5 /opt/ds-deps/vendor/manifest.tsv | tail -n +2 | while read -r p; do \
        test -f "$p/.vendor-ok" || { echo "ds-deps: $p not installed" >&2; exit 1; }; \
    done; \
    echo "ds-deps: 4 prefixes installed and manifested"

# ── the google-re2 binding, built here because the pins are here ─────────────
#
# RE2 decides the DS regex language ([LREG.7.1]), so the binding is built
# against deps.lock's RE2, once, and inherited by ds-build and ds-test.
#
# There is no cp314 wheel, so it is compiled: only the binding, against the
# static PIC prefixes above. Pinned by version and by the sdist's digest
# (--no-binary=:all: forces the source build); `--require-hashes` refuses
# anything else.
ARG GOOGLE_RE2_VERSION=1.1.20251105
ARG GOOGLE_RE2_SHA256=1db14a292ee8303b91e91e7c37e05ac17d3c467f29416c79ac70a78be3e65bda
#
# The link order. setuptools links as `LDSHARED → objects → -L dirs →
# libraries`, google-re2 declares only `libraries=['re2']`, and static archives
# resolve left to right, so Abseil and the C++ runtime have to come after the
# objects. A linker wrapper appends them after "$@"; re2.pc's `Requires:` is the
# list and its order, expanded by pkg-config, so a pin bump re-derives it.
#
# The wrapper is bound to CXX, because setuptools picks the linker for a C++
# extension from CXX; LDSHARED and CC alone are ignored for the link. CC is bound
# too, so the same wrapper compiles the .cc.
RUN set -eu; \
    re2_prefix="$(set -- "$DS_VENDOR_STORE"/re2-*; \
        test "$#" -eq 1 || { echo "ds-deps: expected one re2 prefix, found $#" >&2; exit 1; }; \
        echo "$1")"; \
    absl_prefix="$(set -- "$DS_VENDOR_STORE"/abseil-*; \
        test "$#" -eq 1 || { echo "ds-deps: expected one abseil prefix, found $#" >&2; exit 1; }; \
        echo "$1")"; \
    export PKG_CONFIG_PATH="$re2_prefix/lib/pkgconfig:$absl_prefix/lib/pkgconfig"; \
    re2_libs="$(pkg-config --libs --static re2)"; \
    test -n "$re2_libs" || { echo "ds-deps: pkg-config gave no libs for re2" >&2; exit 1; }; \
    printf '#!/bin/sh\nexec g++ "$@" %s\n' "$re2_libs" > /usr/local/bin/ds-re2-link; \
    chmod 0755 /usr/local/bin/ds-re2-link; \
    echo "ds-deps: linking google-re2 against $re2_prefix"; \
    pip install --no-cache-dir pybind11 setuptools wheel; \
    printf '%s\n' \
      "google-re2==${GOOGLE_RE2_VERSION} --hash=sha256:${GOOGLE_RE2_SHA256}" \
      > /opt/ds-deps/re2.req; \
    CC=/usr/local/bin/ds-re2-link \
    CXX=/usr/local/bin/ds-re2-link \
    CPPFLAGS="-I$re2_prefix/include -I$absl_prefix/include" \
    pip install --no-cache-dir --no-binary=:all: --no-build-isolation \
        --require-hashes -r /opt/ds-deps/re2.req; \
    rm -f /opt/ds-deps/re2.req

# Imported, not merely installed: a wheel that installs cleanly can still fail
# `from . import _re2`.
RUN set -eu; \
    python3 -c "import re2; assert re2.compile(r'^a(b+)c$').match('abbbc'), 'RE2 did not match'; print('ds-deps: google-re2 imports and matches')"

# ── Abseil and RE2 on the default paths, for the non-vendored build ──────────
#
# The gates build libds and pyds non-vendored: `libds.build` compiles
# `ds_re2.cc` with no include flags and links a bare `-lre2 -lstdc++`, and
# `pyds/meson.build` asks pkg-config for the same library. Every image that runs
# a build gate has to satisfy both, so Abseil and RE2 are installed shared on
# the default paths, from vendor.py's digest-checked tarballs
# (scripts/vendor/vendor_shared.py).
#
# After the binding on purpose: a system libre2.so on the default paths would
# give the binding's link a second candidate for `-lre2`.
#
# The files are copied again because the first RUN removed /deps-src; folding
# this into that layer would rebuild the vendored set on every edit here.
COPY scripts/vendor/vendor.py scripts/vendor/vendor_shared.py  /deps-src/scripts/vendor/
COPY vendor/deps.lock                                   /deps-src/vendor/
RUN set -eu; \
    cd /deps-src; \
    python3 scripts/vendor/vendor_shared.py /deps-src/shared-work; \
    rm -rf /deps-src

# Two consumers, two checks. libds.build's: an unflagged compile and link,
# with no -I, -L or pkg-config, outside the source tree, so it proves the
# default paths resolve.
RUN set -eu; \
    mkdir -p /opt/ds-deps/re2-check; \
    cd /opt/ds-deps/re2-check; \
    printf '%s\n' \
      '#include <re2/re2.h>' \
      '#include <cstdio>' \
      'int main() {' \
      '  if (!RE2::FullMatch("abbbc", "^a(b+)c$")) { std::puts("no match"); return 1; }' \
      '  if (RE2::FullMatch("abx", "^a(b+)c$")) { std::puts("matched a non-match"); return 1; }' \
      '  std::puts("ds-deps: re2 resolves on the default paths");' \
      '  return 0;' \
      '}' > check.cc; \
    g++ -std=c++17 -o check check.cc -lre2 -lstdc++; \
    ldd ./check | grep -q 'libre2\.so' \
      || { echo "ds-deps: check did not link the shared re2" >&2; ldd ./check >&2; exit 1; }; \
    ldd ./check | grep -q 'libabsl' \
      || { echo "ds-deps: libre2.so carries no Abseil NEEDED entry — abseil was not installed shared, so re2.pc's Requires will not resolve" >&2; ldd ./check >&2; exit 1; }; \
    ./check; \
    cd /; rm -rf /opt/ds-deps/re2-check

# pyds's: pkg-config. `--print-errors` names the `Requires:` that did not
# resolve. cmake is checked too, because meson's `dependency('re2')` tries both
# and `re2Config.cmake` needs Abseil's cmake config.
RUN set -eu; \
    pkg-config --print-errors --exists re2 \
      || { echo "ds-deps: pkg-config cannot resolve re2 — this is what pyds/meson.build asks, and dependency('re2') will fail in scripts/private/gate/bootstrap.py before any gate runs" >&2; exit 1; }; \
    echo "ds-deps: pkg-config --libs re2 -> $(pkg-config --libs re2)"; \
    test -f /usr/local/lib/cmake/re2/re2Config.cmake \
      || { echo "ds-deps: re2Config.cmake missing" >&2; exit 1; }; \
    test -d /usr/local/lib/cmake/absl \
      || { echo "ds-deps: absl cmake config missing — re2Config.cmake's find_dependency(absl) fails, and meson reports it as re2 not found" >&2; exit 1; }; \
    echo "ds-deps: re2 resolves through pkg-config AND cmake"

# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# ds-python — the CPython every DS image above it runs: 3.12, built from source,
# with the DS Python toolchain and the google-re2 binding for it.
#
# ABOVE ds-deps. ds-base and ds-deps are not rebuilt for Python: ds-base
# carries the pinned compilers, LLVM and Mercury, ds-deps the vendored set. A
# Python change rebuilds this image and the ones built on it (ds-build,
# ds-test, ds-emsdk, ds-mcu, and ds-bench through ds-test).
#
# ds-base's own Python (the 3.14 of its pinned base image) stays where it is:
# `python3`, `pip3` and their friends in /usr/local/bin are 3.12's from here
# on, and `python3.14` is still 3.14.
#
# NOTHING BELOW MOVES. No apt pin, no snapshot, no compiler changes here: the
# headers CPython needs come from the same frozen DEBIAN_SNAPSHOT ds-base set,
# so they are the versions that snapshot already fixes.
ARG BASE=ds-deps:latest
FROM ${BASE}

# ── CPython, from its signed source ──────────────────────────────────────────
#
# python.org's source tarball, pinned by digest AND verified against its
# sigstore bundle with the cosign and trusted root ds-base installed: the 3.12
# release manager's identity, thomas@python.org, through Google's OIDC.
#
# No PGO and no LTO: they double a build that takes about an hour on the riscv64
# host, and nothing DS measures depends on the interpreter's speed. The
# interpreter is static (no --enable-shared), as pyds's extension needs only the
# headers.
#
# No /tmp: scratch is /opt/ds-python/build, removed in the same RUN.
ARG CPYTHON_VERSION=3.12.15
ARG CPYTHON_SHA256=c2c4321961fab0fb999d66e0cecf521c2ab3994c7992873ea99e306c1094fd5a
RUN set -eu; \
    apt-get update && apt-get install -y --no-install-recommends \
        libssl-dev libffi-dev libbz2-dev liblzma-dev libsqlite3-dev \
        libreadline-dev libncurses-dev uuid-dev libgdbm-dev libexpat1-dev \
        && rm -rf /var/lib/apt/lists/*; \
    mkdir -p /opt/ds-python/build; \
    cd /opt/ds-python/build; \
    url="https://www.python.org/ftp/python/${CPYTHON_VERSION}/Python-${CPYTHON_VERSION}.tar.xz"; \
    curl -fsSL "$url" -o cpython.tar.xz; \
    echo "${CPYTHON_SHA256}  cpython.tar.xz" | sha256sum -c -; \
    curl -fsSL "$url.sigstore" -o cpython.tar.xz.sigstore; \
    cosign verify-blob --bundle cpython.tar.xz.sigstore \
        --trusted-root "$DS_SIGSTORE_ROOT" \
        --certificate-identity thomas@python.org \
        --certificate-oidc-issuer https://accounts.google.com \
        cpython.tar.xz; \
    mkdir src; \
    tar -xJf cpython.tar.xz -C src --strip-components=1; \
    cd src; \
    ./configure --prefix=/usr/local --with-ensurepip=install --with-system-expat; \
    make -j"$(nproc)"; \
    make install; \
    cd /; \
    rm -rf /opt/ds-python/build; \
    ln -sf python3.12 /usr/local/bin/python; \
    ln -sf pip3.12 /usr/local/bin/pip; \
    ln -sf pip3.12 /usr/local/bin/pip3; \
    for exe in python python3 pip pip3; do \
        got="$("$exe" --version 2>&1)"; \
        case "$got" in \
            *3.12*) echo "ds-python: $exe -> $got" ;; \
            *) echo "ds-python: '$exe' is not 3.12's: $got" >&2; exit 1 ;; \
        esac; \
    done; \
    python3 -c 'import ssl, ctypes, bz2, lzma, sqlite3, zlib, readline, uuid, pyexpat; print("ds-python: CPython", __import__("sys").version.split()[0], "with its stdlib modules")'

# ── the DS Python toolchain, pinned ──────────────────────────────────────────
#
# ds-base's set (meson, meson-python, hatchling, pytest and the rest) and
# ds-deps' build tools (pybind11, setuptools, wheel), each pinned, with every
# transitive dependency pinned too. `--no-deps` makes
# the list the whole closure: a dependency 3.12 needs that is not on it is a
# `pip check` failure here, not a version chosen silently.
RUN set -eu; \
    python3 -m pip install --no-cache-dir --no-deps \
        meson==1.12.1 ninja==1.13.2 meson-python==0.22.1 \
        hatchling==1.32.4 editables==0.6 \
        pytest==9.1.1 pytest-asyncio==1.4.0 pytest-timeout==2.4.0 \
        lark==1.3.1 protobuf==7.36.2 PyYAML==6.0.3 msgpack==1.2.3 hypothesis==6.169.0 \
        pybind11==3.1.0 setuptools==84.2.1 wheel==0.48.0 \
        iniconfig==2.3.1 packaging==26.3 pathspec==1.1.1 pluggy==1.6.0 \
        pyproject-metadata==0.12.1 sortedcontainers==2.4.0 \
        trove-classifiers==2026.9.21.13 typing_extensions==4.16.0 \
        tomlkit==0.15.1 Pygments==2.21.0; \
    python3 -m pip check

# ── google-re2 for 3.12, built as ds-deps builds it for 3.14 ─────────────────
#
# The same version and sdist digest as ds-deps (GOOGLE_RE2_*), compiled from
# source against ds-deps' own pinned static RE2 and Abseil prefixes, through the
# `ds-re2-link` wrapper ds-deps installed. ds-deps' comments say why each part is
# there; none of it changes.
#
# ONE DIFFERENCE, AND IT IS WHY THE CHECK BELOW EXISTS. ds-deps built its binding
# BEFORE it put a shared libre2.so on the default paths; here that libre2.so is
# already there, and setup.py's bare `-lre2` would find it. `-L` to the static
# prefixes in LDFLAGS is searched before the default paths, so `-lre2` resolves
# to the static archive as it did in ds-deps, and the `ldd` check proves it: the
# binding must NEED no libre2.so.
ARG GOOGLE_RE2_VERSION=1.1.20251105
ARG GOOGLE_RE2_SHA256=1db14a292ee8303b91e91e7c37e05ac17d3c467f29416c79ac70a78be3e65bda
RUN set -eu; \
    re2_prefix="$(set -- "$DS_VENDOR_STORE"/re2-*; \
        test "$#" -eq 1 || { echo "ds-python: expected one re2 prefix, found $#" >&2; exit 1; }; \
        echo "$1")"; \
    absl_prefix="$(set -- "$DS_VENDOR_STORE"/abseil-*; \
        test "$#" -eq 1 || { echo "ds-python: expected one abseil prefix, found $#" >&2; exit 1; }; \
        echo "$1")"; \
    test -x /usr/local/bin/ds-re2-link \
      || { echo "ds-python: ds-deps' ds-re2-link wrapper is missing" >&2; exit 1; }; \
    mkdir -p /opt/ds-python; \
    printf '%s\n' \
      "google-re2==${GOOGLE_RE2_VERSION} --hash=sha256:${GOOGLE_RE2_SHA256}" \
      > /opt/ds-python/re2.req; \
    CC=/usr/local/bin/ds-re2-link \
    CXX=/usr/local/bin/ds-re2-link \
    CPPFLAGS="-I$re2_prefix/include -I$absl_prefix/include" \
    LDFLAGS="-L$re2_prefix/lib -L$absl_prefix/lib" \
    python3 -m pip install --no-cache-dir --no-binary=:all: --no-build-isolation \
        --require-hashes -r /opt/ds-python/re2.req; \
    rm -f /opt/ds-python/re2.req; \
    so="$(python3 -c 'import re2._re2 as m; print(m.__file__)')"; \
    if ldd "$so" | grep -q 'libre2\.so'; then \
        echo "ds-python: google-re2 linked the shared libre2.so, not ds-deps' static RE2:" >&2; \
        ldd "$so" >&2; exit 1; \
    fi; \
    python3 -c "import re2; assert re2.compile(r'^a(b+)c$').match('abbbc'), 'RE2 did not match'; print('ds-python: google-re2 imports, matches, and carries the static RE2')"

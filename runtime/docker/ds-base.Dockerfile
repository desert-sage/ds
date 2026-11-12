# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# ds-base — the DS toolchain image. Every python-based DS image derives from it.
# It is the native build toolchain (libds, pyds and dsc build from source
# against it) and the Python build and test dependencies, so no downstream image
# re-declares them.
#
# It builds nothing of DS. The gates build the DS tree from a fresh clone
# against this image, so the engine under test matches the commit. What it
# builds is toolchain: glibc's link-time half and Mercury.
#
# Digest-pinned: `python:3.14-slim` is a moving tag, and dsdev.core.images tags
# an image by its Dockerfile chain, not by what it installed, so an unpinned base
# would give two different environments the same tag.
#
# To bump:
#     docker buildx imagetools inspect python:3.14-slim | grep '^Digest:'
# and paste. Take the digest of the index, not of one architecture: this image
# builds on amd64, arm64 and riscv64.
#
# dev/dsdev/tests/test_base_images_pinned.py fails if any FROM here loses its
# digest.
FROM python:3.14-slim@sha256:cea0e6040540fb2b965b6e7fb5ffa00871e632eef63719f0ea54bca189ce14a6

# ── APT POINTS AT snapshot.debian.org ────────────────────────────────────────
#
# The digest-pinned base fixes only the initial package set; `apt-get update`
# would otherwise reach whatever deb.debian.org serves today. The snapshot fixes
# every package this file installs, the compiler that builds the shipped glibc
# artifacts included.
#
# The timestamp is the base image's own: Debian's images record the snapshot
# they were built from in `debian.sources`, so the packages below are consistent
# with what the base carries:
#
#     gcc  4:14.2.0-1     binutils  2.44-3     libc6-dev  2.41-12+deb13u3
#
# To bump: change DEBIAN_SNAPSHOT to the new base's recorded timestamp and the
# versions below in the same commit, and re-measure.
#
# http, not https: `ca-certificates` is installed by the apt call below, so an
# https source cannot bootstrap. apt verifies the Release signature either way.
#
# `Check-Valid-Until false` because a snapshot's Release file ages out by
# design.
#
# APT_PROXY, when given, is an http proxy apt fetches through, in this image and
# every image built on it: a caching proxy such as apt-cacher-ng, so a fleet
# fetches each package from the snapshot once and a snapshot outage reaches only
# a package no build has fetched before. The sources stay the snapshot's, so the
# versions below bind and apt verifies the Release signature as before. Empty,
# apt fetches directly. It is a build argument, not a line of this file, so the
# image's tag does not depend on it.
#
# `Acquire::Retries "0"`: apt's own retry of a failed download is off. apt 3.0.3
# can leave a retried download queued and never started, and then spins in its
# download loop, storing a warning on every pass until it exhausts memory
# (Debian #1111554). A failed download fails the step instead, and every apt
# step below runs under `timeout`, so a fetch that never completes fails it too.
ARG DEBIAN_SNAPSHOT=20260713T000000Z
ARG APT_PROXY=
RUN set -eu; \
    sed -i \
      -e "s|^URIs: http://deb.debian.org/debian$|URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}|" \
      -e "s|^URIs: http://deb.debian.org/debian-security$|URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}|" \
      /etc/apt/sources.list.d/debian.sources; \
    grep -q "snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}" /etc/apt/sources.list.d/debian.sources || { \
      echo "ds-base: apt sources were not rewritten to the snapshot — the base image's" >&2; \
      echo "         debian.sources no longer matches the expected URI form, and a" >&2; \
      echo "         silent no-op here would leave the build floating on deb.debian.org." >&2; \
      exit 1; }; \
    printf 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "0";\n' \
      > /etc/apt/apt.conf.d/99snapshot; \
    apt-config dump | grep -qx 'Acquire::Retries "0";'; \
    if [ -n "$APT_PROXY" ]; then \
      printf 'Acquire::http::Proxy "%s";\n' "$APT_PROXY" > /etc/apt/apt.conf.d/98proxy; \
      apt-config dump | grep -qxF "Acquire::http::Proxy \"$APT_PROXY\";"; \
    fi

# node, git and ca-certificates: the runner's actions/checkout runs `node` and
# `git` before any workflow step.
#
# cmake and autotools build the vendored set here: Abseil and RE2 are cmake,
# protobuf-c is autotools.
#
# No libre2-dev and no libprotobuf-c-dev: every row that compiles here links the
# vendored set (`DS_VENDORED`, wired in release.build), and with no distro copy
# installed, a build that reaches for one fails instead of silently linking it.
#
# `protobuf-compiler` stays: `protoc` generates the `*_pb2.py` the wheel ships,
# and generated Python is version-checked at import against the pip `protobuf`
# runtime installed below, so it pairs with this image. `protoc-c` comes from the
# vendored prefix, because `.pb-c.c` carries version guards against the
# `libprotobuf-c.h` it compiles with.
#
# The compile toolchain is version-pinned, and the snapshot is what makes the pin
# bind. `build-essential` is a metapackage with no version constraint on its
# members, and so is `gcc`:
#
#     gcc     = 4:14.2.0-1      <- the metapackage, what you can name here
#     gcc-14  = 14.2.0-19       <- the actual compiler, what produces the bytes
#
# `gcc=4:14.2.0-1` constrains a pointer, not a compiler. The snapshot is the
# binding constraint on `gcc-14`, `cpp-14` and `binutils-<triple>-linux-gnu`: a
# frozen archive offers one version of each, so the whole closure is fixed. The
# list below declares what is expected and fails the build if the snapshot stops
# offering it.
#
# `gcc-14` and `g++-14` are pinned too, since their names are arch-independent.
# `binutils-<triple>-linux-gnu` is not one literal across architectures, so the
# snapshot carries it.
#
# `test_toolchain_pins.py` reads these from this file and from ds-musl's and
# asserts the two lineages agree on gcc and binutils, so only the libc varies.
RUN timeout 600 apt-get update \
    && timeout 600 apt-get install -y --no-install-recommends \
        build-essential \
        gcc=4:14.2.0-1 \
        g++=4:14.2.0-1 \
        gcc-14=14.2.0-19 \
        g++-14=14.2.0-19 \
        binutils=2.44-3 \
        libc6-dev=2.41-12+deb13u3 \
        cmake \
        autoconf automake libtool \
        protobuf-compiler \
        pkg-config \
        zlib1g-dev \
        git \
        ca-certificates \
        nodejs \
        gnupg \
        flex bison \
        gawk \
    && rm -rf /var/lib/apt/lists/*

# The DS Python toolchain: meson/meson-python (pyds native ext), hatchling,
# pytest (all suites), lark/protobuf/pyyaml/msgpack (runtime deps).
# pytest-timeout gives suites whose fixtures await a server a per-test cap, so a
# wedged await is a named failure rather than a hung gate.
RUN pip install --no-cache-dir \
        meson ninja meson-python hatchling editables \
        pytest pytest-asyncio pytest-timeout "lark>=1.2" protobuf pyyaml msgpack hypothesis

# ── the pinned validation clang ──────────────────────────────────────────────
#
# One clang, identical on amd64 and arm64, from LLVM's release tarballs. It is
# the compiler DS validates against, never the one it ships with: the release
# compiler is gcc.
#
# riscv64 has none: LLVM publishes no tarball for it, and nothing placed on
# build-rv64gc-linux compiles with clang. $DS_CLANG names no file there.
#
# From the tarball, not apt, which floats within a distro's packaging. Only the
# driver and its resource headers are extracted; the full toolchain would put
# gigabytes into the image every gate pulls.
#
# Reachable as `clang-22` and via $DS_CLANG, not as plain `clang`: ds-check's
# `clang` is clang-17 and must stay so (SAW parses its bitcode and kore needs
# the LLVM-17 runtime).
ARG LLVM_VERSION=22.1.8
# A GitHub release asset can be replaced in place, so each tarball is pinned by
# digest, one per architecture because the URL is arch-selected. The download
# is also verified against its sigstore bundle with cosign, below.
# dev/dsdev/tests/test_downloads_are_checksummed.py holds every download to a
# digest.
ARG LLVM_SHA256_X64=df0e1ecf16caf3489a272a5eea4eec9b0d82878f6477fa309504f918a0006384
ARG LLVM_SHA256_ARM64=805efad2bb91cb4967fa569e0881d10c0f69c04461cf671cccbae19f547acc34
# curl and xz-utils, for the downloads below.
RUN timeout 600 apt-get update && timeout 600 apt-get install -y --no-install-recommends curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# ── glibc: DS builds the C library every image links against ────────────────
#
# DS patches no single glibc file: it builds the whole of glibc from one pin,
# with the right options. The pin is vendor/deps.lock's `[glibc]`, which these
# ARGs copy because an image build cannot read the lock;
# scripts/private/tests/pins/test_vendor.py holds the two equal, and the CFI
# switches equal to scripts/private/gate/buildlib.py's `CFI`.
#
# WHY: Debian 13's x86_64 crti.o and crtn.o carry no CET note, and `gcc -shared`
# links them into every shared object, so a shared object linked against them
# (`_pyds`, `js_plusds.node`) has no IBT/SHSTK however it was compiled, and
# loading it turns CET off for the whole process. glibc's own configure is what
# puts the note on its assembly start files: `--enable-cet` on x86_64; on
# aarch64 the compiler's -mbranch-protection does (2.41 has no configure switch
# for it).
#
# THE LINK-TIME HALF IS INSTALLED, the runtime half stays Debian's.
# runtime/docker/glibc_link_install.py replaces every file `libc6-dev`
# installed (headers, start files, libc_nonshared.a, the static archives, the
# linker scripts) with this build's, and leaves libc6
# (libc.so.6, ld.so: the same 2.41 ABI, with Debian's security fixes, never
# shipped) byte for byte as it was. It fails the build if a start file or a
# shared object linked here lacks the note, or if a program linked here does
# not run.
#
# The 2.41 release tarball, not a release/2.41/master state: deps.lock pins
# release tarballs only, and the shipped bytes this build contributes are the
# start files and libc_nonshared.a, which no fix since 2.41 touches.
#
# Signed by Andreas K. Huettel, whose key (expired since, which an archived
# release's signature does not mind: the pass condition is VALIDSIG naming it)
# is committed as vendor/glibc/glibc-release-key.asc. GNU's keyring at
# ftp.gnu.org changes whenever any maintainer's key does, so a digest of it
# would break this build within days; the one key that signed is pinned instead,
# as node-release-keys.asc pins Node's. Regenerating it (a new glibc release
# with a new signer is the only reason to):
#     gpg --import gnu-keyring.gpg
#     gpg --armor --export-options export-clean --export <signer> > glibc-release-key.asc
ARG GLIBC_VERSION=2.41
ARG GLIBC_SHA256=a5a26b22f545d6b7d7b3dd828e11e428f24f4fac43c934fb071b6a7d0828e901
ARG GLIBC_SIGNER=35B17DF5752577CA0C541CEB94BFDF4484AD142F
ARG GLIBC_CFI_X86_64=-fcf-protection=full
ARG GLIBC_CFI_AARCH64=-mbranch-protection=standard
COPY vendor/glibc/glibc-release-key.asc /var/tmp/glibc-release-key.asc
COPY runtime/docker/glibc_link_install.py /var/tmp/glibc_link_install.py
RUN set -eu; \
    machine="$(uname -m)"; triple="$(gcc -dumpmachine)"; \
    case "$machine" in \
        x86_64)  cfi="$GLIBC_CFI_X86_64";  cet=--enable-cet ;; \
        aarch64) cfi="$GLIBC_CFI_AARCH64"; cet= ;; \
        riscv64) cfi=;                     cet= ;; \
        *) echo "ds-base: no glibc build for $machine" >&2; exit 1 ;; \
    esac; \
    url="https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VERSION}.tar.xz"; \
    curl -fsSL "$url" -o /var/tmp/glibc.tar.xz; \
    curl -fsSL "$url.sig" -o /var/tmp/glibc.tar.xz.sig; \
    echo "$GLIBC_SHA256  /var/tmp/glibc.tar.xz" | sha256sum -c -; \
    export GNUPGHOME=/var/tmp/glibc-gpg; mkdir -m 700 "$GNUPGHOME"; \
    gpg --batch --import /var/tmp/glibc-release-key.asc; \
    test "$(gpg --batch --with-colons --list-keys | grep -c '^pub:')" -eq 1; \
    gpg --batch --with-colons --fingerprint "$GLIBC_SIGNER" | grep -q "^fpr:::::::::$GLIBC_SIGNER:"; \
    gpg --batch --status-fd 1 --verify /var/tmp/glibc.tar.xz.sig /var/tmp/glibc.tar.xz \
        > /var/tmp/glibc.status 2>/dev/null || true; \
    grep -q "^\[GNUPG:\] VALIDSIG .* $GLIBC_SIGNER\$" /var/tmp/glibc.status; \
    if grep -Eq '^\[GNUPG:\] (BADSIG|ERRSIG|REVKEYSIG)' /var/tmp/glibc.status; then \
        echo "ds-base: glibc's signature is refused:" >&2; cat /var/tmp/glibc.status >&2; exit 1; \
    fi; \
    mkdir -p /var/tmp/glibc-src /var/tmp/glibc-build /var/tmp/glibc-dest; \
    tar -xJf /var/tmp/glibc.tar.xz -C /var/tmp/glibc-src --strip-components=1; \
    cd /var/tmp/glibc-build; \
    python3 /var/tmp/glibc_link_install.py configparms "$triple" > configparms; \
    cat configparms; \
    # Each stage logs to a file, and a failing one prints its tail: glibc's
    # make writes more than BuildKit keeps of a step's output, so the error
    # would otherwise be clipped away.
    /var/tmp/glibc-src/configure --prefix=/usr \
        --libdir="/usr/lib/$triple" --libexecdir="/usr/lib/$triple" \
        --enable-stack-protector=strong --enable-bind-now $cet --disable-werror \
        CFLAGS="-O2 -g $cfi" CXXFLAGS="-O2 -g $cfi" \
        > /var/tmp/glibc-configure.log 2>&1 \
        || { tail -n 60 /var/tmp/glibc-configure.log >&2; exit 1; }; \
    make -j"$(nproc)" > /var/tmp/glibc-make.log 2>&1 \
        || { grep -n -B2 -A8 -E 'Error [0-9]|error:' /var/tmp/glibc-make.log | tail -n 120 >&2; exit 1; }; \
    make install DESTDIR=/var/tmp/glibc-dest > /var/tmp/glibc-install.log 2>&1 \
        || { tail -n 80 /var/tmp/glibc-install.log >&2; exit 1; }; \
    cd /; \
    python3 /var/tmp/glibc_link_install.py install /var/tmp/glibc-dest "$triple" "$machine" "$cfi" \
        "glibc $GLIBC_VERSION sha256:$GLIBC_SHA256 cfi:${cfi:-none}"; \
    apt-mark hold libc6 libc6-dev; \
    rm -rf /var/tmp/glibc*

# ── cosign and the trust anchor, before the things they verify ──────────────
#
# cosign is pinned by digest, not by signature: a verifier cannot verify itself,
# so its digest is where the chain stops. The digests agree with the release's
# cosign_checksums.txt.
ARG COSIGN_VERSION=3.1.3
ARG COSIGN_SHA256_X64=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
ARG COSIGN_SHA256_ARM64=c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a
ARG COSIGN_SHA256_RISCV64=9736177c6be33e4493304fc34feb8aa29209d531b3d40142d7e2a40bbe2f542f
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64)  cosign_arch=amd64;   cosign_sha="$COSIGN_SHA256_X64" ;; \
        aarch64) cosign_arch=arm64;   cosign_sha="$COSIGN_SHA256_ARM64" ;; \
        riscv64) cosign_arch=riscv64; cosign_sha="$COSIGN_SHA256_RISCV64" ;; \
        *) echo "ds-base: no cosign build for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${cosign_arch}"; \
    curl -fsSL "$url" -o /usr/local/bin/cosign; \
    echo "$cosign_sha  /usr/local/bin/cosign" | sha256sum -c -; \
    chmod +x /usr/local/bin/cosign; \
    cosign version

# Sigstore's trusted root: who is believed, as against what runs the check. A
# second copy of deps.lock's `[sigstore-trust-root]` row, because an image build
# cannot read deps.lock; `test_vendor.py` holds the two equal.
#
# The URL contains the digest (TUF serves targets content-addressed); the
# `sha256sum -c` catches a truncated transfer.
ARG SIGSTORE_ROOT_SHA256=6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66
RUN set -eu; \
    mkdir -p /opt/sigstore; \
    curl -fsSL "https://tuf-repo-cdn.sigstore.dev/targets/${SIGSTORE_ROOT_SHA256}.trusted_root.json" \
         -o /opt/sigstore/trusted_root.json; \
    echo "$SIGSTORE_ROOT_SHA256  /opt/sigstore/trusted_root.json" | sha256sum -c -
ENV DS_SIGSTORE_ROOT=/opt/sigstore/trusted_root.json

# `set -eu`: with `-u`, a deleted or misspelled LLVM_SHA256_* aborts the build
# at its cause.
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64)  llvm_arch=X64;   llvm_sha="$LLVM_SHA256_X64" ;; \
        aarch64) llvm_arch=ARM64; llvm_sha="$LLVM_SHA256_ARM64" ;; \
        riscv64) echo "ds-base: no validation clang on riscv64"; exit 0 ;; \
        *) echo "ds-base: no LLVM tarball for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/LLVM-${LLVM_VERSION}-Linux-${llvm_arch}.tar.xz"; \
    mkdir -p /opt/llvm; \
    curl -fsSL "$url" -o /tmp/llvm.tar.xz; \
    echo "$llvm_sha  /tmp/llvm.tar.xz" | sha256sum -c -; \
    curl -fsSL "$url.jsonl" -o /tmp/llvm.jsonl; \
    cosign verify-blob --bundle /tmp/llvm.jsonl \
        --trusted-root "$DS_SIGSTORE_ROOT" \
        --certificate-identity "https://github.com/llvm/llvm-project/.github/workflows/release-binaries.yml@refs/tags/llvmorg-${LLVM_VERSION}" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        /tmp/llvm.tar.xz; \
    rm -f /tmp/llvm.jsonl; \
    tar -xJf /tmp/llvm.tar.xz -C /opt/llvm --strip-components=1 --wildcards \
        '*/bin/clang-*' '*/bin/clang' '*/bin/clang++' '*/lib/clang/*'; \
    rm -f /tmp/llvm.tar.xz; \
    ln -sf /opt/llvm/bin/clang "/usr/local/bin/clang-${LLVM_VERSION%%.*}"; \
    "/usr/local/bin/clang-${LLVM_VERSION%%.*}" --version

ENV DS_CLANG=/opt/llvm/bin/clang

# ── Mercury: the second DS runtime's toolchain ──────────────────────────────
#
# `runtime/mercury` is a full DS runtime, a peer of `runtime/src/libds`, built
# with `mmc`. It is in this image so that every descendant can build both
# runtimes, and the cross-runtime differential is a single-image gate.
#
# From source, because upstream's apt repository publishes no arm64 packages.
# Upstream signs no release tarball, so the pin is a digest: it attests the
# bytes, not who published them. The `.sha512` upstream serves beside the
# tarball is not the pin; it is recorded so the pin can be cross-checked by
# hand:
#
#     sha512 7a3f40c8876bec059842d133b50be9c19d60739ba320ce5f0df160b2e3473077
#            f4394e794a45e23d35f4088dc04f23a24c8f6e0f724bbcf4b3822e15e5d3bf72
#
# `MERCURY_SHA256` is what the build enforces, computed from the same bytes.
#
# The grade is pinned to `hlc.gc` on every architecture. Left to configure, x86_64
# would pick `asm_fast.gc` and aarch64 `hlc.gc`, compiling the runtime through
# different backends, and the differential needs one construction everywhere.
# `hlc.gc` is also the bootstrap's grade (the srcdist's pre-generated
# `compiler/mercury_compile.c` declares `HIGHLEVEL_CODE=yes`), so nothing
# cross-grade happens.
#
# One library grade, not the default set, which takes hours to build.
#
# `flex` and `bison` are in the apt layer above for this: the srcdist ships no
# generated lexer or parser. DEBIAN_SNAPSHOT fixes their versions.
#
# On riscv64, configure is told that gcc labels are unusable. Its probe, the
# `mercury_cv_gcc_labels` test at configure:9534, runs a conftest that jumps
# between functions by computed `goto`, and on riscv64 that conftest never
# exits. `hlc.gc` uses no gcc labels, so the answer does not change the build.
# A "no" also skips the asm labels and global registers probes that depend on
# it.
ARG MERCURY_VERSION=22.01.8
ARG MERCURY_SHA256=a097e8cc8eca0152ed9527c1caf73e5c9c83f6ada1d313a25b80fe79072fbad8
ARG MERCURY_GRADE=hlc.gc
# The whole bin/ goes on PATH, not a symlink to `mmc`: `mmc` runs `mkinit`,
# `mgnuc`, `ml` and c2init by bare name. Set before the RUN below creates it;
# a PATH entry that does not exist is skipped.
ENV PATH=/opt/mercury/bin:$PATH
RUN set -eu; \
    url="https://dl.mercurylang.org/release/mercury-srcdist-${MERCURY_VERSION}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/mercury.tar.gz; \
    echo "${MERCURY_SHA256}  /tmp/mercury.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/mercury-src; \
    tar -xzf /tmp/mercury.tar.gz -C /tmp/mercury-src --strip-components=1; \
    cd /tmp/mercury-src; \
    case "$(uname -m)" in \
        riscv64) export mercury_cv_gcc_labels=no ;; \
    esac; \
    ./configure --prefix=/opt/mercury \
        --enable-libgrades="${MERCURY_GRADE}" \
        --with-default-grade="${MERCURY_GRADE}"; \
    make PARALLEL=-j"$(nproc)"; \
    make install PARALLEL=-j"$(nproc)"; \
    cd /; \
    rm -rf /tmp/mercury-src /tmp/mercury.tar.gz; \
    mmc --version; \
    mmc --output-grade-string

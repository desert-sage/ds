# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# ds-check — the formal-methods image: every formal lane (formal.build) runs here.
#
# The toolchains, one image for all of them:
#   * spec  — the spec-corpus audits (Python 3 + duckdb + mypy). mypy, not
#             pyright: pyright's PyPI wrapper fetches Node.js at first run.
#   * alloy — solve formal/alloy/*.als (Alloy jar)
#   * tla   — model-check formal/tla/*.tla (tla2tools jar)
#   * saw   — prove formal/saw/*.saw, C ⊨ spec (clang + z3 + SAW)
#   * k     — run formal/k/*.k executable DS semantics (K Framework)
#   * souffle — the Soufflé derivation for the `logical` relation fragment
#             (Soufflé, built from source with a 64-bit domain, the last layer)
#
# Ubuntu-based, not derived from ds-base: K Framework ships only as Ubuntu .debs
# pinned to an Ubuntu LLVM runtime. K's .deb pulls clang, which SAW parses the
# bitcode of, so one clang serves every tool. The JDK is installed in `base`,
# because the alloy harness needs `javac`.
#
# Noble, not jammy: the harness runs on a published pyds wheel, which needs
# glibc >= 2.38. Noble's K .deb depends on LLVM 17. SAW 1.3 has no 24.04 build;
# its 22.04 tarball runs on noble and parses clang-17 bitcode.
#
# It also carries the DS build toolchain (gcc, protobuf-c, zlib, Python 3.14),
# because build-unit schedules formal.build in this image; each lane is a stamp
# step, so a warm cache reuses passing lanes. The recipes are
# `python3 scripts/formal/check_*.py`.
#
# Copies nothing: recipes, harnesses and models arrive on the /ds mount. Bump an
# ARG to move a pin.
#
# TARGETARCH selects the arch stage below. A global ARG, because only those are
# usable in a `FROM` line; dsdev.images passes it explicitly, since these images
# build from a piped Dockerfile with no --platform. No default, so an unset
# value fails to resolve a stage.
ARG TARGETARCH
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517 AS base
ARG DEBIAN_FRONTEND=noninteractive
# A UTF-8 locale so the JVM / javac / kompile default to UTF-8 (the models and
# harnesses carry UTF-8); a locale-less Ubuntu container defaults to US-ASCII.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# Base tools + python3 (a bootstrap interpreter; the spec audits run on the 3.14
# built below, against its duckdb + mypy — `python` → python3)
# + z3 (the SMT solver the K/kore backend and SAW both shell out to) +
# openjdk-17-jdk-headless (the alloy harness compiles RunAlloy.java with `javac`;
# K's .deb only pulls the JRE, and TLC needs just `java` — the JDK covers both)
# + cbmc (the bounded model checker behind the `cbmc` lane, the second
# `C |= spec` lane next to SAW; it reuses the z3 above).
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates git python3 python-is-python3 z3 \
        openjdk-17-jdk-headless cbmc \
    && rm -rf /var/lib/apt/lists/*
# ── cosign and the trust anchor ──────────────────────────────────────────────
#
# The same pins as ds-base: images build with an empty context, so there is no
# shared include. `test_vendor.py` checks both copies against deps.lock. Installed
# before every download in this file, as early as `curl` allows.
#
# ── WHAT EACH DOWNLOAD IN THIS IMAGE PUBLISHES ───────────────────────────────
#
#   LLVM 22.1.8    .sig + .jsonl        sigstore  verified (workflow identity)
#   Python 3.14.0  .sigstore/.sig/.crt  sigstore  verified (release manager)
#   Node 22.20.0   SHASUMS256.txt+.sig  GPG       verified (key in nodejs/node)
#   Alloy 6.2.0    .asc                 GPG       not verified — see below
#   SAW 1.3        .sig                 GPG       not verified — see below
#   K 7.1.337      nothing              —         digest is the only control
#   TLA 1.8.0      nothing              —         digest is the only control
#   protoc 35.1    nothing              —         digest is the only control
#
# A signature is worth what the key behind it is worth, and the key has to be
# corroborated somewhere its publisher does not control end to end:
#
#   Node   fpr C82FA3AE…C17AB93C is published in nodejs/node's README as
#          Richard Lau's release key, independent of nodejs.org/dist.
#   Alloy  fpr C668130C…E7AB9B37 is on keyserver.ubuntu.com only, and
#          AlloyTools publishes no fingerprint of its own.
#   SAW    fpr 07FC90D0…43DB4A3A is on no keyserver and in no Galois document.
#
# So Alloy and SAW are pinned by digest only. Verifying them needs a fingerprint
# from AlloyTools and from Galois by a channel other than the download.
ARG COSIGN_VERSION=3.1.3
ARG COSIGN_SHA256_X64=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
ARG COSIGN_SHA256_ARM64=c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a
ARG SIGSTORE_ROOT_SHA256=6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64)  cosign_arch=amd64; cosign_sha="$COSIGN_SHA256_X64" ;; \
        aarch64) cosign_arch=arm64; cosign_sha="$COSIGN_SHA256_ARM64" ;; \
        *) echo "ds-check: no cosign build for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${cosign_arch}" \
         -o /usr/local/bin/cosign; \
    echo "$cosign_sha  /usr/local/bin/cosign" | sha256sum -c -; \
    chmod +x /usr/local/bin/cosign; \
    cosign version; \
    mkdir -p /opt/sigstore; \
    curl -fsSL "https://tuf-repo-cdn.sigstore.dev/targets/${SIGSTORE_ROOT_SHA256}.trusted_root.json" \
         -o /opt/sigstore/trusted_root.json; \
    echo "$SIGSTORE_ROOT_SHA256  /opt/sigstore/trusted_root.json" | sha256sum -c -
ENV DS_SIGSTORE_ROOT=/opt/sigstore/trusted_root.json

# ── ARCH SPLIT ───────────────────────────────────────────────────────────────
#
# Two pinned assets are published for amd64 only: K Framework
# (`kframework_<v>_amd64_ubuntu_noble.deb`) and SAW
# (`saw-<v>-ubuntu-22.04-X64.tar.gz`). Everything else is arch-neutral: Alloy and
# TLA are jars, Python and RE2/Abseil are built from source, the rest is
# multi-arch apt.
#
# So the image splits for those two only, as stages rather than a TARGETARCH test
# inside one RUN, so the checksum pins stay unconditional on the branch that uses
# them.
#
# K's .deb is also where this image's C toolchain comes from (clang-17, lld-17,
# llvm-17), and libds.build names its compiler, so the arm64 stage installs the
# same LLVM line from Ubuntu's archive. Noble's arm64 LLVM 17 has not been probed
# on the arm64 host; check it before trusting an arm64 ds-check.
#
# On arm64 the `k` and `saw` lanes refuse (scripts/formal/check_k.py,
# check_saw.py) rather than skip. alloy and tla run on both.

# K Framework — executable DS operational semantics. The .deb pulls its full
# toolchain: clang-17 / lld-17 / llvm-17 (the LLVM runtime kore needs) and a JRE.
# The SAW lane reuses that clang; `clang` on PATH is clang-17. Bump K_VERSION to
# move the pin.
FROM base AS tools-amd64
ARG K_VERSION=7.1.337
ARG K_URL=https://github.com/runtimeverification/k/releases/download/v${K_VERSION}/kframework_${K_VERSION}_amd64_ubuntu_noble.deb
# A .deb installed as root runs its maintainer scripts with full privilege, so
# the digest is checked first. runtimeverification publishes no checksum, so it
# is trust-on-first-use.
ARG K_SHA256=3692997e6bfa4be490d24bd9201289d4a05872889c9da725dda21e99d03d6990
RUN curl -fsSL "$K_URL" -o /tmp/k.deb \
    && echo "$K_SHA256  /tmp/k.deb" | sha256sum -c - \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/k.deb \
    && rm -f /tmp/k.deb && rm -rf /var/lib/apt/lists/*

# SAW — symbolic execution + SMT on LLVM bitcode; proves formal/saw/*.saw. Uses the
# clang-17 K brought and z3 above. amd64-only upstream, so it lives here.
ARG SAW_VERSION=1.3
ARG SAW_URL=https://github.com/GaloisInc/saw-script/releases/download/v${SAW_VERSION}/saw-${SAW_VERSION}-ubuntu-22.04-X64.tar.gz
# Trust-on-first-use, checked before the extract, which writes into /opt/saw.
ARG SAW_SHA256=8471c6ccfa433ae827abccc3519b1d2f1dd857f85d5cec20894d9c97fec82a72
RUN mkdir -p /opt/saw \
    && curl -fsSL "$SAW_URL" -o /tmp/saw.tar.gz \
    && echo "$SAW_SHA256  /tmp/saw.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/saw.tar.gz -C /opt/saw --strip-components=1 \
    && rm /tmp/saw.tar.gz \
    && ln -sf /opt/saw/bin/saw /usr/local/bin/saw

# arm64 — no K, no SAW. The same LLVM-17 line from Ubuntu's archive, the drivers
# K's .deb would have pulled.
FROM base AS tools-arm64
RUN apt-get update && apt-get install -y --no-install-recommends \
        clang-17 lld-17 llvm-17 \
    && rm -rf /var/lib/apt/lists/*

# TLA+ tools, built from source at a commit: the jar the `tools` stage copies in
# last. Its own stage, so ant never reaches the gate image. The build is
# upstream's recipe (tlatools/org.lamport.tlatools/customBuild.xml,
# `compile compile-test dist`); every dependency is vendored in the tree, so
# only the commit is fetched.
#
# Fetched by commit, not by tag: v1.8.0 is a rolling tag on master. The check
# after checkout fails rather than build something else.
#
# The version is set, not read: TLC's version comes from the manifest's
# Build-TimeStamp and the git revision, which upstream's build takes from the
# clock and from jgit, and jgit cannot walk a one-commit fetch. The pinned
# commit's date and hash go in instead, so two builds agree.
FROM base AS tla-build
ARG TLA_COMMIT=1813307068bbc5759a441df820f3f548948d6b7a
ARG TLA_COMMIT_DATE=2026-10-02T16:22:23.0Z
ARG ANT_VERSION=1.10.14-1
RUN apt-get update && apt-get install -y --no-install-recommends "ant=${ANT_VERSION}" \
    && rm -rf /var/lib/apt/lists/* \
    && git init -q /tmp/tlaplus \
    && git -C /tmp/tlaplus fetch -q --depth 1 https://github.com/tlaplus/tlaplus.git "${TLA_COMMIT}" \
    && git -C /tmp/tlaplus checkout -q FETCH_HEAD \
    && { test "$(git -C /tmp/tlaplus rev-parse HEAD)" = "${TLA_COMMIT}" \
         || { echo "tlaplus: fetched $(git -C /tmp/tlaplus rev-parse HEAD), pinned ${TLA_COMMIT}" >&2; exit 1; }; } \
    && cd /tmp/tlaplus/tlatools/org.lamport.tlatools \
    && ant -q -f customBuild.xml \
         -DISO8601="${TLA_COMMIT_DATE}" \
         -Dgit.revision="${TLA_COMMIT}" -Dgit.shortRevision="$(echo "${TLA_COMMIT}" | cut -c1-7)" \
         -Dgit.tag=v1.8.0 -Dgit.branch=master \
         compile compile-test dist \
    && mkdir -p /out \
    && cp dist/tla2tools.jar /out/tla2tools.jar \
    && java -cp /out/tla2tools.jar tlc2.TLC -help 2>&1 | grep -q -- '-debugger' \
    && cd / && rm -rf /tmp/tlaplus

# Merge. TARGETARCH is passed explicitly (see the ARG at the top of this file).
FROM tools-${TARGETARCH} AS tools
# `clang` and `clang++` on PATH, unversioned: libds.build names its compiler, so
# `-D cxx=clang++` needs the C++ driver too. In the merged stage because both
# arches need them, and the C and C++ drivers move together with K_VERSION.
RUN ln -sf /usr/bin/clang-17 /usr/local/bin/clang \
    && ln -sf /usr/bin/clang++-17 /usr/local/bin/clang++

# scan-build — the clang static analyser's driver, from `clang-tools-17`, with
# `ccc-analyzer`, the compiler shim it substitutes for `cc`. clang-17 ships
# neither. In the merged stage because both arches need it, and linked
# unversioned like the drivers above.
#
# ccc-analyzer ships under /usr/lib/llvm-17/libexec, which PATH does not search,
# and libds.build names its compiler, so `-D cc=ccc-analyzer` needs it on PATH.
RUN apt-get update && apt-get install -y --no-install-recommends \
        clang-tools-17 \
    && ln -sf /usr/bin/scan-build-17 /usr/local/bin/scan-build \
    && ln -sf /usr/lib/llvm-17/libexec/ccc-analyzer /usr/local/bin/ccc-analyzer \
    && ln -sf /usr/lib/llvm-17/libexec/c++-analyzer /usr/local/bin/c++-analyzer \
    && rm -rf /var/lib/apt/lists/*

# Alloy dist jar (Alloy + Kodkod + SAT4J) — solves formal/alloy/*.als. Runs on the
# openjdk-17 installed in `base`, so alloy runs on both arches.
ARG ALLOY_VERSION=6.2.0
ARG ALLOY_URL=https://repo1.maven.org/maven2/org/alloytools/org.alloytools.alloy.dist/${ALLOY_VERSION}/org.alloytools.alloy.dist-${ALLOY_VERSION}.jar
# The artifact matches Maven Central's published `<artifact>.sha1`,
# F399311928E4E9F5CC8A6C09FACC36C6DD4F4B9C. The pin is sha256, because sha1 is
# broken for collision resistance; the sha1 is the cross-check.
ARG ALLOY_SHA256=6037cbeee0e8423c1c468447ed10f5fcf2f2743a2ffc39cb1c81f2905c0fdb9d
RUN mkdir -p /opt/alloy && curl -fsSL "$ALLOY_URL" -o /opt/alloy/alloy.jar \
    && echo "$ALLOY_SHA256  /opt/alloy/alloy.jar" | sha256sum -c -
ENV ALLOY_JAR=/opt/alloy/alloy.jar

# TLA+ tools (TLC + SANY): installed LAST, from the `tla-build` stage -- see
# "TLA+ tools" at the end of this file.

# Idris 2 — the ITP lane (`formal/idris/**/*.idr`, checks key `idris`). Proves the
# static-semantics and termination properties the other lanes cannot: none of
# them has a totality checker.
#
# Built from source: upstream publishes no Linux binary. The tarball carries
# pre-generated Scheme, `make bootstrap` builds that with Chez, and the result
# rebuilds the compiler from its own source. Arch-neutral, so it sits in the
# merged stage.
#
# noble's Chez 9.5 is enough: INSTALL.md's 10.0.0 floor is for Apple Silicon only.
ARG IDRIS2_VERSION=0.8.0
ARG IDRIS2_URL=https://github.com/idris-lang/Idris2/archive/refs/tags/v${IDRIS2_VERSION}.tar.gz
# Trust-on-first-use: upstream publishes no checksum. A GitHub
# `archive/refs/tags/` URL is generated on demand, so its bytes can move under a
# stable name; if this layer starts failing on the digest, see the TLA+ note at
# the end of this file before assuming the pin is wrong.
ARG IDRIS2_SHA256=7b85226098c5dee96a0a77c892932d2e9fab8e5a5c2d08a0525520e1f4405551
# `make` and `gcc` are installed here because this layer runs before the DS build
# toolchain below. INSTALL.md needs bash, GNU make, gcc or clang, sha256sum and
# GMP.
RUN apt-get update && apt-get install -y --no-install-recommends \
        chezscheme libgmp-dev make gcc \
    && curl -fsSL "$IDRIS2_URL" -o /tmp/idris2.tar.gz \
    && echo "$IDRIS2_SHA256  /tmp/idris2.tar.gz" | sha256sum -c - \
    && mkdir -p /tmp/idris2-src \
    && tar -xzf /tmp/idris2.tar.gz -C /tmp/idris2-src --strip-components=1 \
    && make -C /tmp/idris2-src bootstrap SCHEME=chezscheme PREFIX=/opt/idris2 \
    && make -C /tmp/idris2-src install PREFIX=/opt/idris2 \
    && rm -rf /tmp/idris2.tar.gz /tmp/idris2-src /var/lib/apt/lists/*
ENV IDRIS2_PREFIX=/opt/idris2
ENV PATH=/opt/idris2/bin:$PATH

# SAW's binary is installed in the amd64 stage. These stay in the merged stage
# because the paths are the same on both arches; on arm64 SAW_BIN names no file,
# and scripts/formal/check_saw.py refuses.
ENV SAW_BIN=/usr/local/bin/saw
ENV DS_SAW_CLANG=clang

# ── DS build toolchain, so build-unit runs in this image ─────────────────────
#
# formal.build is a build-unit graph, and the harness is a pyds program, so
# scripts/private/gate/bootstrap.py builds libds.a and installs pyds here before
# anything is scheduled. That needs gcc, protobuf-c and zlib, protoc,
# meson/meson-python/ninja (pyds is a meson-python project) and Python 3.14. noble ships 3.12 with
# no 3.14 package, so 3.14 is built from source and made the canonical
# python3/python; the spec audits run on it too, with duckdb and mypy.
ARG PY_VERSION=3.14.0
# Pinned by digest and verified against python.org's sigstore bundle below. It is
# compiled, and its output is the `python3` every gate here runs.
ARG PY_SHA256=88d2da4eed42fa9a5f42ff58a8bc8988881bd6c547e297e46682c2687638a851
# The signer is a person, not a workflow: CPython is signed by that release's
# release manager under GitHub OAuth (the certificate's SAN is
# `email:hugo@python.org`). It does not track the version, and release managers
# change between feature releases, so a 3.15 bump needs a new value here and
# fails closed until it gets one.
ARG PY_SIGNER=hugo@python.org
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config zlib1g-dev \
        libprotobuf-c-dev protobuf-c-compiler protobuf-compiler \
        libssl-dev libffi-dev libbz2-dev libreadline-dev libsqlite3-dev \
        liblzma-dev uuid-dev wget xz-utils \
    && wget -qO /tmp/python.tgz "https://www.python.org/ftp/python/${PY_VERSION}/Python-${PY_VERSION}.tgz" \
    && echo "$PY_SHA256  /tmp/python.tgz" | sha256sum -c - \
    && wget -qO /tmp/python.sigstore "https://www.python.org/ftp/python/${PY_VERSION}/Python-${PY_VERSION}.tgz.sigstore" \
    && cosign verify-blob --bundle /tmp/python.sigstore \
        --trusted-root "$DS_SIGSTORE_ROOT" \
        --certificate-identity "$PY_SIGNER" \
        --certificate-oidc-issuer "https://github.com/login/oauth" \
        /tmp/python.tgz \
    && rm -f /tmp/python.sigstore \
    && mkdir -p /tmp/pysrc && tar -xzf /tmp/python.tgz -C /tmp/pysrc --strip-components=1 \
    && cd /tmp/pysrc \
    && ./configure --prefix=/usr/local --with-ensurepip=install >/dev/null \
    && make -j"$(nproc)" >/dev/null && make altinstall >/dev/null \
    && ln -sf /usr/local/bin/python3.14 /usr/local/bin/python3 \
    && ln -sf /usr/local/bin/python3.14 /usr/local/bin/python \
    && /usr/local/bin/python3.14 -m pip install --no-cache-dir --upgrade pip \
    && /usr/local/bin/python3.14 -m pip install --no-cache-dir \
        meson ninja meson-python hatchling editables \
        "lark>=1.2" protobuf pyyaml msgpack \
        "duckdb>=1.5" mypy \
    && cd / && rm -rf /tmp/pysrc /tmp/python.tgz /var/lib/apt/lists/*

# ── RE2 AND ABSEIL, BECAUSE THE HARNESS LINKS THEM ──────────────────────────
#
# The harness is a pyds program: scripts/private/gate/bootstrap.py installs
# `bindings/python` before it can schedule formal.build, and `pyds/meson.build`
# requires RE2. So the C++ libraries are here, built shared at deps.lock's
# pins. The google-re2 Python binding is not.
#
# The sources are cloned and removed inside one RUN, so only the installed
# shared libraries land in a layer.
#
# A git tag is mutable and these are compiled into the RE2 that defines the DS
# regex language ([LREG.7.1]), so each clone's commit is checked against the
# lock. abseil's tag is lightweight, so ref and commit are one object; re2's is
# annotated, and the lock holds the commit under it (what `rev-parse HEAD`
# yields after checkout), not the tag object.
COPY vendor/deps.lock /tmp/deps.lock
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake git ca-certificates \
    && lock_get() { sed -n "/^\[$1\]/,/^\[/p" /tmp/deps.lock \
                    | sed -n "s/^$2 *= *//p" | head -1; } \
    && ABSEIL_VERSION="$(lock_get abseil version)" \
    && ABSEIL_COMMIT="$(lock_get abseil commit)" \
    && RE2_VERSION="$(lock_get re2 version)" \
    && RE2_COMMIT="$(lock_get re2 commit)" \
    && for v in "$ABSEIL_VERSION" "$ABSEIL_COMMIT" "$RE2_VERSION" "$RE2_COMMIT"; do \
         test -n "$v" || { echo "ds-check: deps.lock gave an empty pin — abseil=$ABSEIL_VERSION/$ABSEIL_COMMIT re2=$RE2_VERSION/$RE2_COMMIT. A section or field was renamed." >&2; exit 1; }; \
       done \
    && echo "ds-check: pins from deps.lock — abseil $ABSEIL_VERSION ($ABSEIL_COMMIT), re2 $RE2_VERSION ($RE2_COMMIT)" \
    && git clone --depth 1 -b "${ABSEIL_VERSION}" \
         https://github.com/abseil/abseil-cpp.git /tmp/abseil \
    && { test "$(git -C /tmp/abseil rev-parse HEAD)" = "${ABSEIL_COMMIT}" \
         || { echo "abseil tag ${ABSEIL_VERSION} MOVED: got $(git -C /tmp/abseil rev-parse HEAD), pinned ${ABSEIL_COMMIT}" >&2; exit 1; }; } \
    && cmake -S /tmp/abseil -B /tmp/abseil/build \
         -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
         -DCMAKE_CXX_STANDARD=17 -DABSL_PROPAGATE_CXX_STD=ON \
         -DBUILD_TESTING=OFF >/dev/null \
    && cmake --build /tmp/abseil/build -j"$(nproc)" >/dev/null \
    && cmake --install /tmp/abseil/build >/dev/null \
    && git clone --depth 1 -b "${RE2_VERSION}" \
         https://github.com/google/re2.git /tmp/re2 \
    && { test "$(git -C /tmp/re2 rev-parse HEAD)" = "${RE2_COMMIT}" \
         || { echo "re2 tag ${RE2_VERSION} MOVED: got $(git -C /tmp/re2 rev-parse HEAD), pinned ${RE2_COMMIT}" >&2; exit 1; }; } \
    && cmake -S /tmp/re2 -B /tmp/re2/build \
         -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
         -DCMAKE_CXX_STANDARD=17 -DRE2_BUILD_TESTING=OFF >/dev/null \
    && cmake --build /tmp/re2/build -j"$(nproc)" >/dev/null \
    && cmake --install /tmp/re2/build >/dev/null \
    && ldconfig \
    && cd / && rm -rf /tmp/abseil /tmp/re2 /tmp/deps.lock /var/lib/apt/lists/*

# No THIRD_PARTY_NOTICES.md here: RE2's BSD-3 notice binds redistribution, and
# this is an internal image. The redistributed artefacts carry the notice. If
# this image is ever pushed to a public registry, that changes.

# ── the pinned validation clang ──────────────────────────────────────────────
#
# The same version ds-base installs, so the validation clang is identical across
# images. gcc is not: this image is noble's, for K.
#
# It does not touch `clang`, which is clang-17 here: SAW parses clang-17's
# bitcode and kore needs the matching LLVM runtime. The pinned one is `clang-22`
# and $DS_CLANG, as in ds-base. Same selective extraction as ds-base.
ARG LLVM_VERSION=22.1.8
# The same two digests as ds-base, for the same two artifacts. Bump both together.
ARG LLVM_SHA256_X64=df0e1ecf16caf3489a272a5eea4eec9b0d82878f6477fa309504f918a0006384
ARG LLVM_SHA256_ARM64=805efad2bb91cb4967fa569e0881d10c0f69c04461cf671cccbae19f547acc34


RUN set -eu; \
    case "$(uname -m)" in \
        x86_64)  llvm_arch=X64;   llvm_sha="$LLVM_SHA256_X64" ;; \
        aarch64) llvm_arch=ARM64; llvm_sha="$LLVM_SHA256_ARM64" ;; \
        *) echo "ds-check: no LLVM tarball for $(uname -m)" >&2; exit 1 ;; \
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
    "/usr/local/bin/clang-${LLVM_VERSION%%.*}" --version; \
    clang --version | grep -q 'clang version 17\.'
ENV DS_CLANG=/opt/llvm/bin/clang

# ── the test and coordinator packages ────────────────────────────────────────
#
# This image compiles nothing a user receives (ds-base, ds-build and ds-musl
# do), so it is exempt from the toolchain pin: its gcc is whichever noble's K
# .deb brings.
#
#   libcmocka-dev    the libds unit tests link cmocka
#   libmsgpack-dev   libds msgpack paths
#   valgrind         the memcheck / memcheck-leak lanes (gcov ships with gcc)
#   openssh-client   build-unit's ssh and scp reach the fleet from here
#   nodejs, gnupg    the runner's actions/checkout runs `node` and `git` before
#                    any workflow step
# and from ds-base's pip set:
#   pytest, pytest-asyncio, pytest-timeout   every suite; the timeout caps
#                    suites whose fixtures await a server
#   hypothesis       the hypothesis lane
#
# pip runs through the 3.14 built above, the interpreter the gates use.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcmocka-dev \
        libmsgpack-dev \
        valgrind \
        openssh-client \
        nodejs \
        gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && /usr/local/bin/python3.14 -m pip install --no-cache-dir \
        pytest pytest-asyncio pytest-timeout hypothesis

# A protoc that matches the pip protobuf runtime: python protobuf 7.35.1 and
# protoc v35.1 are one release train (the 7 is the Python-side major). A
# descriptor generated by a protoc far from the runtime's train loses the
# `map_entry` option under the pure-Python runtime, and a proto map silently
# degrades to a repeated composite.
#
# apt's protobuf-compiler stays, because protobuf-c-compiler depends on it for
# protoc-c; /usr/local/bin precedes /usr/bin, so this shadows it. The C path uses
# protoc-c, and protobuf-c has no maps.
#
# Late in the file, so editing it does not invalidate the Python-from-source
# layer; unpacked with python's zipfile so the early apt list does not change.
# The asserts make a wrong download a build failure rather than a fall-back to
# apt's protoc.
ARG PROTOC_VERSION=35.1
# The digest catches a tampered binary, which the version asserts cannot.
# Trust-on-first-use.
ARG PROTOC_SHA256=6930ebf62bd4ea607b98fff052596c6ee564b9835b4ce172c75a3f53ae9d91b7
RUN wget -qO /tmp/protoc.zip \
        "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_64.zip" \
    && echo "$PROTOC_SHA256  /tmp/protoc.zip" | sha256sum -c - \
    && /usr/local/bin/python3 -m zipfile -e /tmp/protoc.zip /usr/local \
    && chmod 0755 /usr/local/bin/protoc \
    && rm -f /tmp/protoc.zip /usr/local/readme.txt \
    && test "$(command -v protoc)" = /usr/local/bin/protoc \
    && protoc --version | grep -q "${PROTOC_VERSION}"

# Node 22, so the dsi frontend's Vitest suite runs here. noble's apt `nodejs`
# (18) is too old for Vitest; it stays because the runner's actions/checkout runs
# `node` before any workflow step.
#
# From the tarball rather than an apt repo: a pinned URL is the whole install.
# /usr/local/bin precedes /usr/bin, so these symlinks shadow the apt node on
# PATH; the apt one remains at /usr/bin/node.
#
# No `npm install` here: the frontend's package.json is in the repo, which this
# image cannot see. The gate installs at run time against an npm cache under
# /ds-cache.
ARG NODE_VERSION=22.20.0
# Both digests are from https://nodejs.org/dist/v22.20.0/SHASUMS256.txt, and the
# signature on SHASUMS256.txt is checked. The key is corroborated independently
# of nodejs.org/dist: C82FA3AE1CBEDC6BE46B9360C43CEC45C17AB93C is published in
# nodejs/node's README as Richard Lau's release key.
#
# The keyring is committed as bytes in `node-release-keys.asc` and imported from
# the build context; no keyserver is contacted at image-build time. Each key is
# asserted against its pin below, so editing `NODE_RELEASE_KEYS` without
# regenerating the keyring fails.
#
# Regenerating (a Node release-manager rotation is the only reason to):
#     export GNUPGHOME=$(mktemp -d)
#     for k in <the fingerprints below>; do
#         gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$k"
#         gpg --batch --with-colons --fingerprint "$k" | grep -q "^fpr:::::::::$k:"
#     done
#     gpg --batch --armor --export <the fingerprints> > node-release-keys.asc
# Update the ARG in the same commit; the assertion below fails otherwise.
#
# All nine release keys, not just this version's signer: Node rotates release
# managers between releases and publishes the whole active set. Any of the nine
# is accepted, so this does not detect a single compromised releaser; it detects
# a substituted artifact.
ARG NODE_RELEASE_KEYS="\
5BE8A3F6C8A5C01D106C0AD820B1A390B168D356 \
DD792F5973C6DE52C432CBDAC77ABFA00DDBF2B7 \
CC68F5A3106FF448322E48ED27F5E38D5B0A215F \
8FCCA13FEF1D0C2E91008E09770F7A9A5AE15600 \
890C08DB8579162FEE0DF9DB8BEAB4DFCF555EF4 \
C82FA3AE1CBEDC6BE46B9360C43CEC45C17AB93C \
108F52B48DB57BB0CC439B2997B01419BD92F80A \
655F3B5C1FB3FA8D1A0CA6BDE4A7D232B936D2FD \
A363A499291CBBC940DD62E41F10027AF002F8B0"
ARG NODE_SHA256_X64=00bbd05e306ea68b6e13e17360d0e2f680b493ef95f2fea1c4296ff7437530bc
ARG NODE_SHA256_ARM64=06907b9c088ce62305bc1530e5c1ae1510245114645768f7750c349c5b6fe667
# The keyring, from the build context. COPY rather than a heredoc: heredocs need
# the dockerfile 1.4+ frontend, which the arm64 hosts' older daemons do not
# have, and a `# syntax=` directive would fetch the frontend over the network.
#
# Exported with `--export-options export-minimal`: primary key, UIDs and self
# signatures, which is what `gpg --verify` consults.
COPY runtime/docker/node-release-keys.asc /tmp/node-release-keys.asc

RUN set -eu; \
    case "$(uname -m)" in \
        x86_64)  node_arch=x64;   node_sha="$NODE_SHA256_X64" ;; \
        aarch64) node_arch=arm64; node_sha="$NODE_SHA256_ARM64" ;; \
        *) echo "ds-check: no node tarball for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    export GNUPGHOME=/tmp/nodegpg; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"; \
    gpg --batch --import /tmp/node-release-keys.asc; \
    for k in $NODE_RELEASE_KEYS; do \
        # Every key checked against its pin; a pin with no key in the file
        # fails here rather than at `--verify`.
        gpg --batch --with-colons --fingerprint "$k" | grep -q "^fpr:::::::::$k:"; \
    done; \
    # …and the file holds nothing else: the import is the trust boundary, so it
    # must be exactly the pinned set.
    test "$(gpg --batch --with-colons --list-keys | grep -c '^pub:')" -eq 9; \
    wget -qO /tmp/SHASUMS256.txt "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
    wget -qO /tmp/SHASUMS256.txt.sig "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt.sig"; \
    gpg --batch --verify /tmp/SHASUMS256.txt.sig /tmp/SHASUMS256.txt; \
    url="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    mkdir -p /opt/node; \
    wget -qO /tmp/node.tar.xz "$url"; \
    echo "$node_sha  /tmp/node.tar.xz" | sha256sum -c -; \
    # …and the pinned digest is the one the signed manifest names.
    grep -q "^$node_sha  node-v${NODE_VERSION}-linux-${node_arch}.tar.xz$" \
         /tmp/SHASUMS256.txt; \
    rm -rf "$GNUPGHOME" /tmp/SHASUMS256.txt /tmp/SHASUMS256.txt.sig \
           /tmp/node-release-keys.asc; \
    tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1; \
    rm -f /tmp/node.tar.xz; \
    for b in node npm npx; do ln -sf "/opt/node/bin/$b" "/usr/local/bin/$b"; done; \
    test "$(command -v node)" = /usr/local/bin/node; \
    node --version | grep -q "^v${NODE_VERSION}$"; \
    npm --version

# Playwright's Chromium and its system libraries, for the dsi E2E suite. The
# browser download and `install-deps` (about 40 shared libraries) need root and a
# package manager, so they are in the image rather than run per gate.
#
# PLAYWRIGHT_BROWSERS_PATH keeps the download out of ~/.cache, so it works for
# any user; the frontend's `@playwright/test` resolves browsers through it.
#
# The gate still runs `playwright install chromium` after npm install: a no-op
# when the resolved runner matches the browser baked here, a download when
# package.json's ^1.43.0 has floated past it. The version needs noble support
# (1.45 or later).
#
# The one download here with no digest: an npm-registry fetch, which npm checks
# against the registry's `dist.integrity`. test_downloads_are_checksummed.py pins
# the name, so no second unpinned registry install can join it.
ARG PLAYWRIGHT_VERSION=1.51.1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN set -eu; \
    mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"; \
    npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium; \
    rm -rf /var/lib/apt/lists/*; \
    test -d "$PLAYWRIGHT_BROWSERS_PATH"; \
    ls "$PLAYWRIGHT_BROWSERS_PATH" | grep -q chromium

# No PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION override: with protoc paired to the
# pip runtime above, upb accepts the generated code. Do not reintroduce the
# pure-Python override to silence a version mismatch; with mismatched descriptors
# it makes proto maps silently degrade. test_rfcs_protobuf_backend.py runs a
# child per backend.

# ── Record which deps.lock this image compiled RE2 from ──────────────────────
#
# `scripts/private/gate/bootstrap.py` refuses a tree whose `deps.lock` is not
# this one, so the formal lanes cannot run against a different RE2, and so a
# different regex language ([LREG.7.1]), than the one the image was built with.
# The image's tag folds `deps.lock` too.
#
# A second COPY of the same file, late so that editing this layer does not
# invalidate the ones above it.
COPY vendor/deps.lock /opt/ds-check/deps.lock.stamp
RUN set -eu; \
    mkdir -p /opt/ds-check; \
    sha256sum /opt/ds-check/deps.lock.stamp | cut -d' ' -f1 > /opt/ds-check/deps.lock.sha256; \
    rm -f /opt/ds-check/deps.lock.stamp; \
    echo "ds-check: built from deps.lock sha256:$(cat /opt/ds-check/deps.lock.sha256)"

# ── Soufflé — the `souffle` lane ─────────────────────────────────────────────
#
# A Datalog engine. The lane lowers a fragment program's rules and base facts to
# Datalog and has Soufflé compute the stratified least model, on an engine that
# has never seen libds's bookkeeping, so libds's live content can be compared
# against it. The lane runs the interpreter (`souffle prog.dl`), so no C++
# compiler is needed after this layer builds. The lane's prelude `#include` needs
# a C preprocessor; Soufflé tries `mcpp` first, which is installed and asserted.
#
# Built from source with SOUFFLE_DOMAIN_64BIT=ON: upstream's packages have a
# 32-bit `number`, a compile-time choice, and DS Int is int64. The probe at the
# end of the RUN parses 2^42, which a 32-bit build cannot, so a wrong build
# fails here.
#
# Pinned as a tag and its commit; the clone asserts the commit before cmake
# reads it. 2.5's tag is lightweight. Cloned rather than fetched as a tarball,
# because CMake derives the version string from `git describe`.
#
# Late in the file, so a pin bump rebuilds this layer alone. The build needs
# only bison, flex and mcpp beyond what the layers above installed. The
# interactive provenance explorer and the test suite are not built.
ARG SOUFFLE_VERSION=2.5
ARG SOUFFLE_COMMIT=5682a9f12e2668ecdd26348fe63cc508bc0fcf47
RUN apt-get update && apt-get install -y --no-install-recommends \
        bison flex mcpp \
    && git clone --depth 1 -b "${SOUFFLE_VERSION}" \
         https://github.com/souffle-lang/souffle.git /tmp/souffle \
    && { test "$(git -C /tmp/souffle rev-parse HEAD)" = "${SOUFFLE_COMMIT}" \
         || { echo "souffle tag ${SOUFFLE_VERSION} MOVED: got $(git -C /tmp/souffle rev-parse HEAD), pinned ${SOUFFLE_COMMIT}" >&2; exit 1; }; } \
    && cmake -S /tmp/souffle -B /tmp/souffle/build \
         -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/souffle \
         -DSOUFFLE_DOMAIN_64BIT=ON \
         -DSOUFFLE_USE_CURSES=OFF \
         -DSOUFFLE_ENABLE_TESTING=OFF -DSOUFFLE_TEST_EVALUATION=OFF \
         -DSOUFFLE_BASH_COMPLETION=OFF >/dev/null \
    && cmake --build /tmp/souffle/build -j"$(nproc)" >/dev/null \
    && cmake --install /tmp/souffle/build >/dev/null \
    && ln -sf /opt/souffle/bin/souffle /usr/local/bin/souffle \
    && test "$(command -v souffle)" = /usr/local/bin/souffle \
    && souffle --version | grep -q "${SOUFFLE_VERSION}" \
    && command -v mcpp >/dev/null \
    && printf '.decl A(x:number)\nA(4398046511104).\n.output A\n' > /tmp/souffle-probe.dl \
    && souffle -D- /tmp/souffle-probe.dl | grep -qx '4398046511104' \
    && rm -f /tmp/souffle-probe.dl \
    && cd / && rm -rf /tmp/souffle /var/lib/apt/lists/*
ENV SOUFFLE_BIN=/usr/local/bin/souffle

# ── Mercury — the toolchain formal.build's `mdsc-bin` builds `dsc` with ──────
#
# The souffle lane lowers its corpus and witnesses through ds_ast, which runs
# the Mercury `dsc`. formal.build runs in this image, so `dsc` is built here by
# the compiler lane's recipe (`gate.py mdsc-bin`), and `mmc` has to be here.
#
# The same pin as ds-base, built again: ds-base's binaries cannot be copied to
# this older glibc. ds-base's Mercury layer explains the pin and the grade. The
# three ARGs are a second copy, held equal by
# scripts/private/tests/pins/test_mercury_pin.py.
#
# Late in the file, so a pin bump rebuilds this layer alone. `flex` and `bison`
# come from the Soufflé layer.
ARG MERCURY_VERSION=22.01.8
ARG MERCURY_SHA256=a097e8cc8eca0152ed9527c1caf73e5c9c83f6ada1d313a25b80fe79072fbad8
ARG MERCURY_GRADE=hlc.gc
ENV PATH=/opt/mercury/bin:$PATH
RUN set -eu; \
    url="https://dl.mercurylang.org/release/mercury-srcdist-${MERCURY_VERSION}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/mercury.tar.gz; \
    echo "${MERCURY_SHA256}  /tmp/mercury.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/mercury-src; \
    tar -xzf /tmp/mercury.tar.gz -C /tmp/mercury-src --strip-components=1; \
    cd /tmp/mercury-src; \
    ./configure --prefix=/opt/mercury \
        --enable-libgrades="${MERCURY_GRADE}" \
        --with-default-grade="${MERCURY_GRADE}"; \
    make PARALLEL=-j"$(nproc)"; \
    make install PARALLEL=-j"$(nproc)"; \
    cd /; \
    rm -rf /tmp/mercury-src /tmp/mercury.tar.gz; \
    mmc --version; \
    test "$(mmc --output-grade-string)" = "${MERCURY_GRADE}"

# ── TLA+ tools (TLC model checker + SANY) — model-checks formal/tla/*.tla ──────
#
# 1.8, built from a commit. 1.8 is the line with TLC's debugger (`-debugger`, a
# DAP server), which dev/mcp's TLA+ launch drives; 1.7.4 has none.
#
# Not the release asset: v1.8.0 is a rolling prerelease, re-cut from master with
# a different tla2tools.jar behind the same tag, so a digest of it breaks at the
# next re-cut. The `tla-build` stage above fetches tlaplus at TLA_COMMIT and
# builds the jar with upstream's recipe. To move the pin, move TLA_COMMIT and
# TLA_COMMIT_DATE there (the commit's committer date, UTC).
#
# A host with the layer cached never re-fetches, so only a cold-cache build
# exercises the pin. Last, so a pin bump rebuilds this layer and its stage
# alone.
COPY --from=tla-build /out/tla2tools.jar /opt/tla/tla2tools.jar
ENV TLA_JAR=/opt/tla/tla2tools.jar
RUN java -cp "$TLA_JAR" tlc2.TLC -help 2>&1 | grep -q -- '-debugger' \
    && java -cp "$TLA_JAR" tla2sany.SANY 2>&1 | grep -q 'SANY'

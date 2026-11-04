# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# ds-lean — a formal image plus Lean 4, for formal/lean. No lane uses it.
#
# Separate from every CI image, as ds-verus is: nothing a gate pulls may change
# because this exists. dev-mcp runs its own graph in it, stacked on
# ds-check-verus:
#
#   ds-check -> ds-check-verus (the Rust binding's Verus image)
#            -> ds-check-lean  (this file)
#
# so every other formal toolchain is ds-check's bytes.
#
# ONE DOWNLOAD, PINNED. The Lean toolchain release tarball, by version and by
# the SHA-256 GitHub publishes for the asset. No elan: a toolchain manager
# would choose versions at run time, and one pinned toolchain is all that is
# wanted. formal/lean uses core Lean only — no Mathlib, no Lake packages — so
# nothing else is fetched, at build or at check.
#
# BUILD, on the build host:
#
#   git -C <mirror> show <ref>:formal/lean/docker/ds-lean.Dockerfile \
#     | docker build --build-arg BASE=ds-check-verus:amd64-f9fffe4a742b \
#         -t ds-check-lean:amd64-f9fffe4a742b -
ARG BASE=ds-check-verus:latest
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive

# zstd for the release tarball; curl and ca-certificates come with the base.
RUN apt-get update && apt-get install -y --no-install-recommends zstd \
    && rm -rf /var/lib/apt/lists/*

ARG LEAN_VERSION=4.34.1
ARG LEAN_SHA256=47bf4bbd78f70c2e9670598ab7124d92b6efb7330ff33e5fbb4030f6fd72e4e4
RUN set -eu; \
    tgz="lean-${LEAN_VERSION}-linux.tar.zst"; \
    curl -fsSL "https://github.com/leanprover/lean4/releases/download/v${LEAN_VERSION}/${tgz}" \
        -o "/tmp/${tgz}"; \
    echo "${LEAN_SHA256}  /tmp/${tgz}" | sha256sum -c -; \
    mkdir -p /opt/lean; \
    tar --zstd -xf "/tmp/${tgz}" -C /opt/lean --strip-components=1; \
    rm "/tmp/${tgz}"; \
    [ -x /opt/lean/bin/lean ] || { echo "ds-lean: ${tgz} has no bin/lean" >&2; exit 1; }; \
    chmod -R a+rX /opt/lean
ENV PATH=/opt/lean/bin:$PATH \
    LEAN_VERSION=${LEAN_VERSION}

# THE PROBE: the toolchain runs and elaborates a theorem.
RUN set -eu; \
    lean --version; \
    printf 'theorem probe : 1 + 1 = 2 := rfl\n' > /tmp/probe.lean; \
    lean /tmp/probe.lean; \
    rm /tmp/probe.lean

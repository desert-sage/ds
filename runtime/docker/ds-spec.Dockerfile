# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
#
# ds-spec — the image `scripts/private/spec/check.py` needs, and nothing else.
#
# It has no arch-specific content, so it builds on amd64 and arm64 alike;
# ds-check carries tools published for amd64 only.
#
# What the gate needs:
#
#   * `python` on PATH, not just `python3`: every step in `check.py`'s `run()`
#     shells `python`.
#   * duckdb — `scripts/private/spec/spec_db.py`, the substrate the gates run on.
#   * mypy — `mypy --strict scripts/private/spec/spec_db.py` is a step.
#   * git — the workflow clones into this container.
#
# Nothing for protobuf: `gen_pbf_vectors.py` downgrades one cross-check when the
# bindings are absent, and says so on every run.
#
# No jsonschema: `scripts/private/spec/spec_validate.py` then runs its stdlib
# subset. Adding it would change the gate's verdict, which is a new check and
# lands as one ([STYL.5.10.6]).
#
# The interpreter is pinned to ds-check's exactly: version, sha256, signature
# and ubuntu base digest. `mypy --strict` can reach a different verdict on a
# different interpreter, so when ds-check's PY_VERSION moves, this moves with
# it.

# Same digest as ds-check's base, so the two images cannot drift on libc.
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517 AS base

ENV DEBIAN_FRONTEND=noninteractive

# cosign, to verify the CPython bundle below. Values pinned identically to
# ds-check's.
ARG COSIGN_VERSION=3.1.3
ARG COSIGN_SHA256_X64=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
ARG COSIGN_SHA256_ARM64=c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a
ARG SIGSTORE_ROOT_SHA256=6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
    && set -eu; \
    case "$(uname -m)" in \
        x86_64)  cosign_arch=amd64; cosign_sha="$COSIGN_SHA256_X64" ;; \
        aarch64) cosign_arch=arm64; cosign_sha="$COSIGN_SHA256_ARM64" ;; \
        *) echo "ds-spec: no cosign build for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${cosign_arch}" \
         -o /usr/local/bin/cosign; \
    echo "$cosign_sha  /usr/local/bin/cosign" | sha256sum -c -; \
    chmod +x /usr/local/bin/cosign; \
    mkdir -p /opt/sigstore; \
    curl -fsSL "https://tuf-repo-cdn.sigstore.dev/targets/${SIGSTORE_ROOT_SHA256}.trusted_root.json" \
         -o /opt/sigstore/trusted_root.json; \
    echo "$SIGSTORE_ROOT_SHA256  /opt/sigstore/trusted_root.json" | sha256sum -c -
ENV DS_SIGSTORE_ROOT=/opt/sigstore/trusted_root.json

# CPython, from source, digest-pinned and signature-verified, with ds-check's
# values. `--with-ensurepip=install` because the pip installs below need it.
ARG PY_VERSION=3.14.0
ARG PY_SHA256=88d2da4eed42fa9a5f42ff58a8bc8988881bd6c547e297e46682c2687638a851
ARG PY_SIGNER=hugo@python.org
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config zlib1g-dev \
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
        "duckdb>=1.5" mypy \
    && cd / && rm -rf /tmp/pysrc /tmp/python.tgz /var/lib/apt/lists/*

# git, because the workflow clones into this container. Last, so an apt change
# does not invalidate the layer above.
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

# The smoke test is part of the build, so a missing shared library or stdlib
# module fails the image rather than a spec gate. It runs `python`, the name the
# gate's steps invoke.
RUN python --version \
    && python -c "import ssl, sqlite3, lzma, bz2, readline, ctypes, uuid, zlib" \
    && python -c "import duckdb; print('duckdb', duckdb.__version__)" \
    && python -m mypy --version \
    && git --version

WORKDIR /ds

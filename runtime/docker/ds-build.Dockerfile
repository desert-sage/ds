# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# ds-build — the release and docs build image: ds-python (ds-deps, which is
# ds-base plus the vendored set at /opt/ds-deps/vendor, with CPython 3.12) and
# the packaging tools that turn the source tree into artifacts:
#   + setuptools, wheel — the wheel plumbing pip wheel needs.
#   + jupyter-book       — the docs site build.
#   + auditwheel         — measures the manylinux tag of each Linux pyds wheel,
#                          which its release step puts on it so PyPI takes it
#                          (scripts/private/gate/buildlib.py, `_wheel_platform`).
#                          `show` only: nothing is grafted, so no patchelf.
# It builds the glibc libds tarball, the pyds wheel and the docs, on every
# architecture. Used by `dsdev build <target>` and `dsdev release`.
#
# Emscripten is in ds-emsdk, not here: emsdk has no riscv64 toolchain, and this
# image has to build for riscv64.
ARG BASE=ds-python:latest
FROM ${BASE}

RUN pip install --no-cache-dir setuptools wheel "jupyter-book>=1.0,<2"
# Pinned, both: the tag it reads is what decides whether a wheel ships, so a
# new auditwheel's policy is a change this file makes, not one an image build
# picks up.
RUN pip install --no-cache-dir auditwheel==6.8.2 pyelftools==0.33

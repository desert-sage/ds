# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The platform-signature accessor (LDET.2.3).

The accessor is informational — its output bounds the scope of
LDET.10's bit-for-bit replay guarantee. These tests pin the shape
plus the platform pieces that matter for in-process replay.

THERE IS NO ULP-TOLERANCE CONTRACT TO CALIBRATE. v1 admits no
transcendentals, so engine operations are correctly-rounded IEEE-754
and there is nothing to tolerate.
"""

import dataclasses

import pyds


def test_platform_signature_shape():
    eng = pyds.Engine()
    sig = eng.platform_signature
    assert isinstance(sig, pyds.PlatformSignature)
    assert [f.name for f in dataclasses.fields(sig)] == [
        "os_family",
        "cpu_arch",
        "libc",
        "compiler",
        "libds_version",
        "backends",
    ]
    for key in ("os_family", "cpu_arch", "libc", "compiler", "libds_version"):
        assert isinstance(getattr(sig, key), str), f"{key} not a str"
        assert getattr(sig, key), f"{key} empty"
    assert isinstance(sig.backends, tuple)
    for b in sig.backends:
        assert isinstance(b, str)


# @spec [NDET.2.2]
def test_platform_signature_includes_pyds_backends():
    """The platform signature lists the exact v1 backend identities.

    Engine() registers all seven built-in backends ([NSBK.2.3]), so the
    signature lists each, named by its atom's body message: the five
    series backings plus the two signal backings, interval pulse
    (active_fraction, LSIG.2.2) and numeric integral (integral, LSIG.2.3).
    """
    eng = pyds.Engine()
    backends = eng.platform_signature.backends
    assert len(backends) == 7, f"expected 7 backends, got {backends!r}"

    atoms = {b.split(":", 1)[0] for b in backends}
    assert atoms == {
        "SeriesBackendWelfordEwma",
        "SeriesBackendRingBuffer",
        "SeriesBackendMonotonicDeque",
        "SeriesBackendFifoDeque",
        "SeriesBackendReservoir",
        "SeriesBackendIntervalPulse",
        "SeriesBackendNumericIntegral",
    }, f"expected exact atom set, got {atoms!r}"

    # Each identity is `<atom>:<name>:<version>`, and every name is `ds-`: the
    # seven are libds's backings, not a binding's ([NDET.2.5]). The
    # whole table is pinned in libds's and the Mercury runtime's own suites.
    for b in backends:
        parts = b.split(":")
        assert len(parts) == 3, f"malformed identity: {b!r}"
        assert parts[1].startswith("ds-"), f"unexpected name: {b!r}"


def test_platform_signature_stable_across_calls():
    """Repeated reads return identical strings: the field values don't drift.

    That is required for the signature to be a useful key for
    replay-determinism scoping.
    """
    eng = pyds.Engine()
    a = eng.platform_signature
    b = eng.platform_signature
    assert a == b


def test_platform_signature_within_v1_envelope():
    """v1 envelope smoke test.

    The floor this guards is the build pin, not a tolerance contract.

    The glibc floor here is 2.34, the pinned build floor: the release
    is built against 2.34 (manylinux_2_34) because glibc symbol
    versioning is one-way, so a higher floor would put a release
    OUTSIDE its own envelope on every host.

    WHY READING THE COMPILE-TIME GLIBC IS SOUND HERE, since it
    looks wrong and someone will want to "fix" it. platform.c
    derives `libc` from __GLIBC__/__GLIBC_MINOR__, i.e. the glibc
    DS was BUILT against — not the one it is running on. With the
    floor set to the build floor that is not a bug but a sound
    lower bound: symbol versioning means a binary built against
    2.34 CANNOT run on anything older, so build >= floor implies
    runtime >= floor. The check can therefore never pass while the
    running platform is out of scope. (It is still the wrong value
    for an integrator asking "what libm am I actually on?" — that
    is a separate question, and it is not what this test asks.)

    So what this guards is a real regression: that nobody
    builds DS against a glibc older than the pin.

    The glibc version does not bear on `**`: `builtin_pow` calls
    CORE-MATH's correctly rounded pow, compiled into libds, not libm's.

    The other three out-of-envelope conditions below skip rather
    than fail, and this one agrees with them in spirit: the floor
    it asserts is one we control at build time, not a property of
    whatever host happens to run the suite.
    """
    import re

    eng = pyds.Engine()
    sig = eng.platform_signature

    # Skip cleanly on out-of-envelope platforms — DS still works,
    # but the conformance suite's bit-identical assertions don't
    # apply.
    if sig.os_family != "linux":
        import pytest

        pytest.skip(f"non-linux: {sig.os_family!r}")
    if sig.cpu_arch not in ("x86_64", "aarch64"):
        import pytest

        pytest.skip(f"non-{{x86_64, aarch64}}: {sig.cpu_arch!r}")

    # libc must be glibc-X.Y with X.Y >= 2.34 (the build floor).
    m = re.match(r"glibc-(\d+)\.(\d+)$", sig.libc)
    if m is None:
        import pytest

        pytest.skip(f"non-glibc: {sig.libc!r}")
    glibc_major, glibc_minor = int(m.group(1)), int(m.group(2))
    assert (glibc_major, glibc_minor) >= (2, 34), (
        f"built against a glibc older than the 2.34 floor: {sig.libc!r}"
    )

    # Compiler must be gcc >= 11.4, the endorsed floor; the release builds
    # with 14.2. The bound is the floor and not the release toolchain, as
    # for glibc above: ds-check carries jammy's gcc 11.4.
    m = re.match(r"gcc-(\d+)\.(\d+)$", sig.compiler)
    if m is None:
        import pytest

        pytest.skip(f"non-gcc: {sig.compiler!r}")
    gcc_major, gcc_minor = int(m.group(1)), int(m.group(2))
    assert (gcc_major, gcc_minor) >= (11, 4), (
        f"built with a gcc older than the 11.4 floor: {sig.compiler!r}"
    )

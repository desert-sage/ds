#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""REGEXRE2 — the shared Abseil and RE2 a NON-VENDORED build has to find.

WHY THIS EXISTS AT ALL. `vendor.enabled()` is declared, never sniffed: it is an
environment variable, and nothing on a gate's path sets it. So every gate
builds libds and pyds NON-VENDORED, and there are TWO ways that build looks for
RE2 — which is the whole difficulty, and it is the part I got wrong first:

  * `libds.build` wants it on the COMPILER's default paths. `sources_cxx` emits
    the C++ unit with `iflags: ""` — "RE2's headers come from the toolchain's
    default search path" — and every `libds.a` link site emits a bare `-lre2
    -lstdc++`, and no link site adds flags of its own.
  * `bindings/python/meson.build` wants it from PKG-CONFIG, deliberately and
    against its own history: `dependency('re2')`, not `cc.find_library('re2')`.
    VENDORWHL1 made that change on purpose, because `_pyds.so` links RE2 INTO
    ITSELF and `find_library` cannot see the vendored prefixes.

An image that satisfies only the first builds libds and
then fails before a single gate runs, on
`Dependency "re2" not found (tried pkg-config and cmake)`.

`ds-check` satisfied both, by building Abseil and RE2 `-DBUILD_SHARED_LIBS=ON`
into `/usr/local` — headers, libraries, `.pc` files and cmake config together.
That image left the gates' path, the gates moved to `ds-test`, and
the arrangement had to move down to `ds-deps` with them. This file is that block,
moved, and it should not have been redesigned on the way.

WHY BOTH, WHEN ONLY RE2 IS NAMED. `re2.pc` carries `Requires: absl_*` and
`re2Config.cmake` carries `find_dependency(absl)`, so pkg-config and cmake BOTH
report re2 as not-found when Abseil's metadata is missing, however present RE2
itself is. Installing RE2 alone gives a compiler that finds `re2/re2.h` and a
`dependency('re2')` that fails — the split-brain that cost a gate run.

A HAZARD I ASSERTED AND HAD NOT MEASURED, recorded because the measurement is
the point. The first version of this file installed RE2 only, on the reasoning
that `/usr/local/lib` precedes `/usr/lib` in the ld.so cache and Debian's
`protoc-c` — which the non-vendored build resolves by bare name — is linked
against Debian's Abseil, so two Abseil builds would answer one soname. Measured
afterwards, in the image:

    ldd $(command -v protoc-c) | grep -c absl   ->  0
    ls /usr/lib/*/libabsl*                      ->  nothing

`protoc-c` links no Abseil, and there is no Debian Abseil in this image to
collide with. The conflict was invented. What it cost was real: RE2's headers
pull in `absl/base/call_once.h`, so the design also needed an Abseil header
symlink to compile at all, and then still could not satisfy pkg-config.

ONE PIN, TWO BUILDS OF IT — not two copies of a pin. Both versions come from
`deps.lock` through `vendor.lock()`, the same rows the vendored store builds
from, and the tarballs arrive through `vendor.fetch()` so they are digest-checked
and (for RE2, which publishes a sigstore bundle) signature-checked before they
are unpacked. That is stronger than the `git clone -b <tag>` the ds-check block
used, where a moved tag had to be caught by comparing the resolved commit after
the fact.

It matters more here than anywhere: RE2 IS the DS regex language under
[LREG.7.1]. A second version reachable on the default paths would have the
compiler validating patterns against a language the release does not ship, and
saying nothing. That is also why Debian's `libre2-dev` is not the answer,
however well it would work.

THE STORE IS UNTOUCHED AND STAYS STATIC. `scripts/vendor/vendor.py` builds the vendored set
`-DBUILD_SHARED_LIBS=OFF` for relocatable release artifacts, and the vendored
lane reaches it through explicit `-I`/`-L` and PKG_CONFIG_PATH. Nothing here
changes that: this is the SYSTEM copy, for the builds that declared nothing.
"""

import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import vendor                                        # noqa: E402 — see above

# `/usr/local` is not a preference, it is the requirement: the point is a place
# g++, ld and pkg-config all search with no flag. Overridable only so a test can
# aim it somewhere writable.
PREFIX = Path(os.environ.get("DS_SHARED_PREFIX", "/usr/local"))

# ORDER IS vendor.py's ORDER: re2 needs abseil, and it needs it INSTALLED —
# `find_package(absl)` runs at re2's configure time, so this cannot be a loop
# over an unordered set.
BUILDS = (
    ("abseil", ("-DABSL_PROPAGATE_CXX_STD=ON", "-DBUILD_TESTING=OFF")),
    ("re2", ("-DRE2_BUILD_TESTING=OFF",)),
)


def _cmake(name: str, src: Path, build: Path, extra: tuple[str, ...]) -> list[list[str]]:
    return [
        ["cmake", "-S", str(src), "-B", str(build),
         f"-DCMAKE_INSTALL_PREFIX={PREFIX}",
         "-DCMAKE_BUILD_TYPE=Release",
         # THE LINE THIS FILE IS ABOUT. Shared, so that `-lre2` on a caller's
         # command line drags Abseil in through DT_NEEDED rather than requiring
         # the caller to name ~40 archives it has no way to know about.
         "-DBUILD_SHARED_LIBS=ON",
         "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
         "-DCMAKE_CXX_STANDARD=17",
         # Ours over the system's, for re2 finding the abseil installed one
         # iteration earlier.
         f"-DCMAKE_PREFIX_PATH={PREFIX}",
         *extra],
        ["cmake", "--build", str(build), "-j", str(vendor.build_jobs())],
        ["cmake", "--install", str(build)],
        # Installed is not found: without this the .so is on disk and the
        # dynamic linker does not know it. Run per-build, because re2's
        # configure links test binaries against the abseil just installed.
        ["ldconfig"],
    ]


def main(argv: list[str]) -> int:
    work = Path(argv[1] if len(argv) > 1 else "vendor-shared-work").resolve()
    cp = vendor.lock()

    for name, extra in BUILDS:
        blob = vendor.fetch(name, work, cp)           # digest + signature first
        src = vendor.extract(blob, work / f"{name}-src")
        for step in _cmake(name, src, work / f"{name}-build", extra):
            subprocess.run(step, check=True)
        print(f"vendor_shared: {name} {cp[name]['version']} installed SHARED "
              f"into {PREFIX}", flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

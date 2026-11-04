#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""scripts/formal/check_saw.py [saw-dir] — the `saw` formal lane: prove libds C code matches
its spec bit/pointer-exact (formal/saw/*.saw) with SAW in the ds-check image.

The thin recipe behind formal.build's `saw.stamp` stamp step (Python port of
saw-entrypoint.sh). For each formal/saw/*.c harness TU, compile to LLVM bitcode
with the pinned clang; then run each formal/saw/*.saw proof (llvm_load_module +
llvm_verify against a spec). The /ds mount is read-only, so compile + prove in a
temp dir with the .bc co-located (SAW resolves llvm_load_module relative to the
.saw's own dir). Non-zero if any proof fails — a stamp step materializes only on exit 0.
"""
from __future__ import annotations

import glob
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # scripts/formal/ on path
import formal_arch  # noqa: E402


def _refuse_without_saw(saw: str) -> int | None:
    """REFUSE, don't skip, when SAW is absent (ARM64TEST1).

    SAW's only Linux release asset is `saw-<v>-ubuntu-22.04-X64.tar.gz` — amd64
    by name — so ds-check on arm64 carries no `saw`. As with the k lane, the
    wrong answer is to return 0 with a note: that reports a proof that never
    ran. TESTING.md, "A check that cannot fail".
    """
    if shutil.which(saw) is not None or Path(saw).is_file():
        return None
    print(
        "== saw gate: REFUSED — no `saw` on this machine ==\n"
        f"   arch: {platform.machine()}  (looked for: {saw})\n"
        "   SAW ships an amd64-only Linux asset (…-ubuntu-22.04-X64.tar.gz),\n"
        "   so ds-check:arm64-* is built without it.\n"
        "   This is a refusal, NOT a skip: no proof ran, so this lane must not\n"
        "   report success. Run `formal` on an amd64 host.",
        file=sys.stderr,
    )
    return 1


def main(argv: list[str]) -> int:
    # IDRISARM1 BEFORE THE TOOL CHECK, and the order is the message. On arm both
    # would fire; "no `saw` on this machine" invites someone to go and install
    # one, and the point is that the lane does not belong here at all.
    refused = formal_arch.refuse_off_amd64("saw")
    if refused is not None:
        return refused

    d = Path(argv[1] if len(argv) > 1 else "formal/saw")
    clang = os.environ.get("DS_SAW_CLANG", "clang")
    saw = os.environ.get("SAW_BIN", "saw")
    refused = _refuse_without_saw(saw)
    if refused is not None:
        return refused

    root = Path.cwd()
    incs = ["-I", str(root / "runtime/include"), "-I", str(root / "runtime/src/libds")]

    print("== saw gate: toolchain ==")
    subprocess.run([clang, "--version"], check=False)
    subprocess.run([saw, "--version"], check=False)

    proofs = sorted(glob.glob(str(d / "*.saw")))
    if not proofs:
        print(f"== saw gate: no proofs found in {d} ==", file=sys.stderr)
        return 1

    rc = 0
    with tempfile.TemporaryDirectory(prefix="ds-saw.") as work:
        print("== saw gate: compiling harness TUs -> bitcode ==")
        for c in sorted(glob.glob(str(d / "*.c"))):
            base = Path(c).stem
            print(f"  clang {c} -> {base}.bc")
            # -O1: clean, verifiable bitcode (fewer allocas than -O0); -g0: no debug.
            subprocess.run([clang, *incs, "-c", "-emit-llvm", "-O1", "-g0",
                            "-o", os.path.join(work, f"{base}.bc"), c], check=True)
        # Stage the proofs next to their bitcode in the writable scratch dir.
        for s in proofs:
            shutil.copyfile(s, os.path.join(work, Path(s).name))

        print("== saw gate: running proofs ==")
        for s in proofs:
            name = Path(s).name
            print(f"--- saw {name} ---")
            if subprocess.run([saw, name], cwd=work).returncode == 0:
                print(f"  PASS: {s}")
            else:
                print(f"  FAIL: {s}")
                rc = 1

    print("== saw gate: all proofs passed ==" if rc == 0 else f"== saw gate: FAILURES (rc={rc}) ==")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))

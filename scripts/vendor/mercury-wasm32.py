#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Patch a Mercury 22.01.8 source tree so it cross-builds for wasm32.

    mercury-wasm32.py <mercury source dir>

ds-emsdk.Dockerfile runs this between `configure` and `mmake`, so the image
carries a Mercury for `wasm32-unknown-emscripten`, grade `hlc`, beside the
native one ds-base installs. mercury.build's wasm32 `dsc` links with it
(the cross toolchain comes with the image,
as the native Mercury and RE2 do).

Each edit must match exactly once, or this refuses and the image does not
build: a pin bump that moved the text is a decision, not a silent no-op.

THE BOEHM RULE BECOMES A NO-OP. The bundled Boehm GC is built for every grade
and `#error`s on wasm; `hlc` has no collector and never links it.

FOUR BOXING GUARDS ADMIT CLANG. On a 32-bit
target `MR_BOXED_INT64S` and `MR_BOXED_FLOAT` hold, and `mercury.h` boxes an
int64 or a double with a GNU statement expression under `MR_GNUC` and an
extern-inline function otherwise. The function's body uses
`MR_new_object_atomic`, which without Boehm GC is `MR_incr_hp_msg`, defined by
`mercury_heap.h`, which `mercury.h` includes at its end. emcc is clang
(`MR_CLANG`, not `MR_GNUC`), so the function is compiled and `MR_incr_hp_msg`
is undeclared there. Clang has statement expressions, so the macro branch is
taken for clang too, and `mercury.c`'s two out-of-line copies are guarded the
same way. `mercury.h` already admits clang for `({...})` where it defines
`MR_new_object`.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

BOEHM_RULE = ("boehm_gc: scripts util_no_rt\n"
              "\t+gc_grade=`scripts/ml --grade $(GRADE) --print-gc-grade`; \\\n"
              "\tcd boehm_gc && $(SUBDIR_MMAKE) GC_GRADE=$$gc_grade\n")
BOEHM_NOOP = ("boehm_gc: scripts util_no_rt\n"
              "\t@echo 'wasm32: boehm_gc not built, the grade has no collector'\n")

GUARDS = [
    ("runtime/mercury.h",
     r"#if defined\(MR_GNUC\)(\s*\n\s*#define MR_box_float\(f\))",
     r"#if defined(MR_GNUC) || defined(MR_CLANG)\1"),
    ("runtime/mercury.h",
     r"#if defined\(MR_GNUC\)(\s*\n\s*#define MR_box_int64\(i\))",
     r"#if defined(MR_GNUC) || defined(MR_CLANG)\1"),
    ("runtime/mercury.c",
     r"#if defined\(MR_BOXED_FLOAT\) && !defined\(MR_GNUC\)([ \t]*\n)",
     r"#if defined(MR_BOXED_FLOAT) && !defined(MR_GNUC) && !defined(MR_CLANG)\1"),
    ("runtime/mercury.c",
     r"#if defined\(MR_BOXED_INT64S\) && !defined\(MR_GNUC\)([ \t]*\n)",
     r"#if defined(MR_BOXED_INT64S) && !defined(MR_GNUC) && !defined(MR_CLANG)\1"),
]


def patch(src: Path) -> None:
    mk = src / "Mmakefile"
    text = mk.read_text()
    if text.count(BOEHM_RULE) != 1:
        raise SystemExit(f"mercury-wasm32: {mk}: the boehm_gc rule is not as expected; "
                         "refusing to patch")
    mk.write_text(text.replace(BOEHM_RULE, BOEHM_NOOP))
    print(f"mercury-wasm32: patched {mk.name}: boehm_gc is a no-op", flush=True)
    for rel, old, new in GUARDS:
        f = src / rel
        t, n = re.subn(old, new, f.read_text())
        if n != 1:
            raise SystemExit(f"mercury-wasm32: {f}: a boxing guard matched {n} times, "
                             "not once; refusing to patch")
        f.write_text(t)
        print(f"mercury-wasm32: patched {rel}: {old[:60]}", flush=True)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    patch(Path(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

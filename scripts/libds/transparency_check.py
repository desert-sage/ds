#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""transparency_check.py — IALC.10.3: in DS_ALLOC_MACRO mode the DS_* macros must
compile byte-identically to the raw libc calls: libds.build's alloc_transparency
step. Compile transparency_probe.c through the macro layer
(DS_ALLOC_MODE=1) and through a regex-generated raw twin, then compare the two
.text sections. Needs no libds build: it tests ds_alloc.h's macro expansion alone. Run
from runtime/tests/libds/alloc_conformance. Env: CC (default gcc).
"""
import os
import re
import subprocess
import sys

TP_CFLAGS = ["-O2", "-g0", "-std=c99", "-D_POSIX_C_SOURCE=200809L", "-DDS_ALLOC_MODE=1"]

# DS_* macro -> the bare libc call the RAW twin substitutes (IALC.10.3).
_SUBST = [("DS_MALLOC", "malloc"), ("DS_CALLOC", "calloc"), ("DS_REALLOC", "realloc"),
          ("DS_FREE", "free"), ("DS_STRDUP", "strdup"), ("DS_STRNDUP", "strndup")]


def main() -> int:
    cc = os.environ.get("CC", "gcc")

    # MACRO twin — expand DS_* through ds_alloc.h (DS_ALLOC_MODE=1 = MACRO).
    subprocess.run([cc, *TP_CFLAGS, "-I../../../src/libds", "-c",
                    "transparency_probe.c", "-o", "tp_macro.o"], check=True)

    # RAW twin — the same source with DS_* rewritten to bare libc + the ds_alloc.h
    # include swapped for stdlib/string. Byte-identical .text proves transparency.
    src = open("transparency_probe.c").read()
    src = src.replace('#include "ds_alloc.h"',
                      '#include <stdlib.h>\n#include <string.h>')
    for macro, fn in _SUBST:
        src = re.sub(rf"\b{macro}\(", f"{fn}(", src)
    with open("tp_raw.c", "w") as f:
        f.write(src)
    subprocess.run([cc, *TP_CFLAGS, "-c", "tp_raw.c", "-o", "tp_raw.o"], check=True)

    subprocess.run(["objcopy", "--dump-section", ".text=tp_macro.text", "tp_macro.o"], check=True)
    subprocess.run(["objcopy", "--dump-section", ".text=tp_raw.text", "tp_raw.o"], check=True)

    with open("tp_macro.text", "rb") as f:
        macro_text = f.read()
    with open("tp_raw.text", "rb") as f:
        raw_text = f.read()

    if macro_text == raw_text:
        print("alloc_transparency: OK (.text byte-identical — DS_* macro layer is "
              "transparent, IALC.10.3)")
        return 0
    print("alloc_transparency: FAIL — DS_* codegen differs from raw libc", file=sys.stderr)
    subprocess.run(["cmp", "tp_macro.text", "tp_raw.text"])   # diagnostic; may fail
    return 1


if __name__ == "__main__":
    sys.exit(main())

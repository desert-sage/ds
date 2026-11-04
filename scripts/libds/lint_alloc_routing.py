#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Anti-rot guard for the libds allocation layer (IALC). Python port of
lint-alloc-routing.sh; run by libds.build's build_lint gate.

  IALC.9.1 — no raw malloc/calloc/realloc/free/strdup/strndup in runtime/src/libds
            (except ds_alloc.{c,h} — the layer itself — and generated *.pb-c.{c,h});
            all DS-owned allocation routes through the DS_* macros / ds_* funcs.
  IALC.9.2 — no NULL allocator to a protobuf-c __unpack / __free_unpacked in the
            hand-written loaders (dsc/*.c, not generated) — must be &ds_pb_allocator.
  IALC.5.3 — the libds-linking .so (pyds meson) must not hide the ds_* override
            symbols (-fvisibility=hidden / gnu_symbol_visibility:'hidden' / -Bsymbolic).

Non-zero (build-failing) on any violation. Spec: specs/impl/ALLOCATOR/ (IALC.9).

The C rules read code, not comments: a comment that says `realloc()`
is not a call, and failed the lint once. Comments and the contents of string
and character literals are blanked, line numbers kept. Before it scans the
tree, every run checks itself against planted lines, a call it must refuse
and a comment it must not, so a scanner that went blind fails the run.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIBDS = ROOT / "runtime" / "src" / "libds"
RAW_ALLOC = r"\b(malloc|calloc|realloc|free|strdup|strndup)\("


def code_only(text: str) -> str:
    """`text` with every C comment replaced by spaces, newlines kept, so a
    line number still names the line it came from."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(c + re.sub(r"[^\n]", " ", text[i + 1:j]) + text[j:j + 1])
            i = j + 1
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _lines(rx, text: str):
    raw = text.splitlines()
    return [(i, raw[i - 1]) for i, line in enumerate(code_only(text).splitlines(), 1)
            if rx.search(line)]


def _grep(paths, pattern: str, skip=lambda p: False):
    rx = re.compile(pattern)
    hits = []
    for p in paths:
        if skip(p):
            continue
        try:
            text = p.read_text(errors="replace")
        except OSError:
            continue
        hits += [f"{p}:{i}:{line}" for i, line in _lines(rx, text)]
    return hits


# THE NEGATIVE FIXTURE: the lines the IALC.9.1 scan must refuse, and the ones
# it must pass, checked on every run before the tree is.
_PLANTED_CALLS = ("p = malloc(4);", "q = strdup(s); /* copy */", "free(p);")
_PLANTED_NOT_CALLS = ("/* grows with realloc() */", "// free(p) on error",
                      " * calloc(n, size) would zero it",
                      'msg = "free(";', "c = '(';")


def self_check() -> list[str]:
    rx = re.compile(RAW_ALLOC)
    text = "\n".join(_PLANTED_CALLS + ("/*",) + _PLANTED_NOT_CALLS[2:3] + (" */",)
                     + _PLANTED_NOT_CALLS[:2] + _PLANTED_NOT_CALLS[3:])
    hit = {line for _, line in _lines(rx, text)}
    wrong = [f"missed {c!r}" for c in _PLANTED_CALLS if c not in hit]
    wrong += [f"flagged {c!r}" for c in _PLANTED_NOT_CALLS if c in hit]
    return wrong


def main() -> int:
    status = 0

    wrong = self_check()
    if wrong:
        print("lint-alloc-routing: the scan fails its own planted lines, so it "
              "certifies nothing: " + "; ".join(wrong), file=sys.stderr)
        return 1

    # IALC.9.1 — no raw libc allocation in DS-owned source.
    c_and_h = sorted(LIBDS.rglob("*.c")) + sorted(LIBDS.rglob("*.h"))
    raw = _grep(c_and_h, RAW_ALLOC,
                skip=lambda p: p.name in ("ds_alloc.c", "ds_alloc.h")
                or p.name.endswith((".pb-c.c", ".pb-c.h")))
    if not c_and_h:
        print(f"lint-alloc-routing: no C source under {LIBDS}: a scan of "
              f"nothing certifies nothing", file=sys.stderr)
        return 1
    if raw:
        print("IALC.9.1 violation: raw libc allocation in runtime/src/libds — route "
              "through the DS_* macros (IALC.9.1):", file=sys.stderr)
        print("\n".join(raw), file=sys.stderr)
        status = 1

    # IALC.9.2 — no NULL protobuf-c allocator in the hand-written loaders.
    dsc_c = [p for p in sorted((LIBDS / "dsc").rglob("*.c")) if not p.name.endswith(".pb-c.c")]
    pbnull = _grep(dsc_c, r"__(unpack|free_unpacked)\s*\([^)]*\bNULL\b")
    pbnull += _grep(dsc_c, r"^\s*NULL,\s*body_len,\s*body\);")
    if pbnull:
        print("IALC.9.2 violation: NULL protobuf-c allocator — pass &ds_pb_allocator "
              "(specs/impl/ALLOCATOR/):", file=sys.stderr)
        print("\n".join(pbnull), file=sys.stderr)
        status = 1

    # IALC.5.3 — the libds-linking .so must not hide the ds_* override symbols.
    meson = ROOT / "bindings" / "python" / "meson.build"
    if meson.exists():
        vis = _grep([meson],
                    r"fvisibility\s*=\s*(hidden|internal)"
                    r"|gnu_symbol_visibility\s*:\s*'(hidden|internal)'"
                    r"|-Bsymbolic\b")
        if vis:
            print("IALC.5.3 violation: ds_* override symbols hidden in the libds-linking "
                  ".so — drop -fvisibility=hidden / gnu_symbol_visibility:'hidden' / "
                  "-Bsymbolic (specs/impl/ALLOCATOR/):", file=sys.stderr)
            print("\n".join(vis), file=sys.stderr)
            status = 1

    if status == 0:
        print("lint-alloc-routing: OK (IALC.9.1, IALC.9.2, IALC.5.3)")
    return status


if __name__ == "__main__":
    sys.exit(main())

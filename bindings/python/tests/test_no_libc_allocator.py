# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The extension never hands memory to the libc allocator.

What libds allocates, libds releases: `ds_free` ([IALC.4.3]). The default
build's weak `ds_free` forwards to `free`, so a libc `free` of a libds buffer
works there and corrupts the heap under a strong allocator override
([IALC.5.1]) or a `DS_ALLOC_MACRO` build. pyds links no override, so no run of
it can tell the two apart; the guard is on the source instead. The binding's
own memory goes through `PyMem_*`, so no libc allocator call belongs in it at
all.
"""

from __future__ import annotations

import re
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src" / "_pyds"

_CALL = re.compile(r"(?<![A-Za-z0-9_])(free|malloc|calloc|realloc)\s*\(")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)


def _code(text: str) -> str:
    """Return the source with its comments blanked, line numbers kept."""
    text = _BLOCK_COMMENT.sub(lambda m: "\n" * m.group().count("\n"), text)
    return "\n".join(line.split("//", 1)[0] for line in text.split("\n"))


def _libc_calls(text: str) -> list[tuple[int, str]]:
    return [
        (n, line.strip()) for n, line in enumerate(_code(text).split("\n"), 1) if _CALL.search(line)
    ]


def test_no_libc_allocator_call():
    sources = sorted(SRC.glob("*.c"))
    assert sources, f"no C sources under {SRC}"
    found = [
        f"{p.name}:{n}: {line}"
        for p in sources
        for n, line in _libc_calls(p.read_text(encoding="utf-8"))
    ]
    assert not found, "libc allocator calls:\n" + "\n".join(found)


def test_the_scan_sees_a_libc_call():
    # The check above must be able to fire, and must not on the right calls.
    assert _libc_calls("x;\n    free(text);\n") == [(2, "free(text);")]
    assert _libc_calls("p = malloc (n);") == [(1, "p = malloc (n);")]
    for fine in (
        "ds_free(text);",
        "PyMem_Free(p);",
        "PyMem_Calloc(n, s);",
        "/* never libc free (here) */",
        "// free(x)",
        "/* a\n free(x)\n */",
    ):
        assert _libc_calls(fine) == [], fine

# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The bind-slot occupancy marker has exactly one producer, and it is not a fault.

`DS_RETE_VAL_UNBOUND` means one thing: a bind slot whose action has not run.
`eval_actions` pre-fills a terminal's bind frame with it, and `eval.c`'s
BIND_REF arm reads it to detect a read before the binding. A fault is
`ds_rete_fault`'s, and an absent value is `ds_rete_val_null()`.

It cannot be `null`: a read before its binding "is NOT an absent value" and
halts the tier ([RARC.5.6.11]), and a `let` may bind a real null, so "is it
null" cannot answer "has it been written".

The check is on the set of `(file, line)` sites, not a count per file, and it
separately refuses any function whose whole body is a bare
`return ds_rete_val_unbound();`: such a wrapper is one site standing for any
number of producers. Comments are stripped before matching.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
SRC = REPO / "runtime/src"

_BLOCK = re.compile(r"/\*.*?\*/", re.S)
_LINE = re.compile(r"//[^\n]*")

# The declaration and definition of the constructor itself, in rete/val.h, are
# not producers. Everything else that names it is.
_DEFINING_FILE = "runtime/src/libds/rete/val.h"

# Every construction of the occupancy marker, with its reason.
ALLOWED = {
    # The one producer. `eval_actions` pre-fills a terminal's bind frame, and a
    # slot still carrying UNBOUND when BIND_REF reads it is a read before its
    # binding — DS_FAULT_BINDING_ORDER, which [RARC.5.6.11] makes an
    # unrecoverable fault rather than an absence.
    ("runtime/src/libds/rete/engine.c",
     "bind_frame[i] = ds_rete_val_unbound();"): 1,
}


def _strip(text: str) -> str:
    return _LINE.sub(" ", _BLOCK.sub(" ", text))


def _sources() -> list[Path]:
    return sorted(p for p in SRC.rglob("*")
                  if p.suffix in (".c", ".h") and p.is_file())


def _sites() -> dict[tuple[str, str], int]:
    """Every `(rel_path, stripped source line)` that constructs the occupancy marker."""
    found: dict[tuple[str, str], int] = {}
    for path in _sources():
        rel = path.relative_to(REPO).as_posix()
        if rel == _DEFINING_FILE:
            continue
        for line in _strip(path.read_text()).splitlines():
            if "ds_rete_val_unbound()" not in line:
                continue
            key = (rel, " ".join(line.split()))
            found[key] = found.get(key, 0) + 1
    return found


def test_no_unallowed_unbound_producer() -> None:
    found = _sites()
    new = {k: v for k, v in found.items() if k not in ALLOWED}
    assert not new, (
        "a new UNBOUND producer appeared. UNBOUND means ONE thing -- a bind "
        "slot whose action has not run ([RARC.5.6.11]) -- so a second producer "
        "is either a fault, which belongs in ds_rete_fault(ctx, expr, "
        "DS_FAULT_*) with its cause, or an absent value, which is "
        "ds_rete_val_null(). If it is a bind-frame pre-fill, add it to "
        "ALLOWED with its reason:\n  "
        + "\n  ".join(f"{f}: {line}" for f, line in sorted(new)))


def test_allowed_sites_have_not_multiplied() -> None:
    """An allowed line appearing more often than allowed is a new producer,
    which a membership-only check would pass."""
    found = _sites()
    grew = {k: (found[k], n) for k, n in ALLOWED.items()
            if found.get(k, 0) > n}
    assert not grew, (
        "an allowed UNBOUND site gained occurrences:\n  "
        + "\n  ".join(f"{f}: {line} -- {got} now, {want} allowed"
                      for (f, line), (got, want) in sorted(grew.items())))


def test_allowlist_has_no_dead_entries() -> None:
    """A stale allowance is how the next wrapper gets waved through."""
    found = _sites()
    dead = sorted(k for k in ALLOWED if k not in found)
    assert not dead, (
        "ALLOWED names sites that no longer exist -- delete them:\n  "
        + "\n  ".join(f"{f}: {line}" for f, line in dead))


# A function whose entire body is `return ds_rete_val_unbound();`. It defeats the
# site check above by construction: one site, called from anywhere.
_WRAPPER = re.compile(
    r"\bds_rete_val_t\s+\w+\s*\([^;{]*\)\s*\{\s*return\s+ds_rete_val_unbound\(\)\s*;\s*\}",
    re.S)


def test_no_local_unbound_wrapper_is_reintroduced() -> None:
    offenders = []
    for path in _sources():
        rel = path.relative_to(REPO).as_posix()
        if rel == _DEFINING_FILE:
            continue
        for m in _WRAPPER.finditer(_strip(path.read_text())):
            offenders.append(f"{rel}: {' '.join(m.group(0).split())}")
    assert not offenders, (
        "a local UNBOUND wrapper is back: one visible producer standing for "
        "any number of real ones. Raise through ds_rete_fault instead:\n  "
        + "\n  ".join(offenders))

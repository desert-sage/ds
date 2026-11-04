#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""scripts/formal/check_cbmc.py [cbmc-dir] — the `cbmc` formal lane: bounded model-checking
of libds C against named clause properties (formal/cbmc/*.c) in the ds-check image.

The thin recipe behind formal.build's `cbmc.stamp` stamp step, in the shape
check_saw.py already set for this lane. Non-zero if any proof fails — a stamp
materializes only on exit 0.

WHY A SECOND `C |= spec` LANE, next to SAW. They prove different things and the
difference must never have to be inferred:

  * SAW proves EQUIVALENCE to a bit-precise Cryptol reference over a whole
    domain (oa_mix64 covers all 2^64 inputs).
  * CBMC proves a STATED PROPERTY, and where a loop is reached, only up to an
    unwind bound.

So a CBMC pass is a weaker claim than a SAW pass, and the harness says which it
is making. That is why every bound is written beside the function it bounds
rather than here.

THE `@cbmc` DIRECTIVE. Each entry point in a harness carries, on the line above
it:

    @cbmc <function> [extra flags...]

One CBMC invocation per directive. Putting the invocation in the source rather
than in this recipe means a reader of the proof sees what it was proved over
without opening the build graph — the same reason the SAW harnesses name their
clause in a `@spec` tag.

UNWINDING ASSERTIONS ARE NOT OPTIONAL where a bound is given. `--unwind N`
alone silently truncates a longer loop and still exits 0, which is a proof of
nothing wearing a proof's clothes — the BUCASAN1 shape. A harness that passes a
bound must pass `--unwind-assertions` with it so CBMC proves the bound
sufficient instead of assuming it; this recipe refuses the run otherwise.

THE `@cbmc-step` MARKER splits a harness between steps of formal.build. A line

    @cbmc-step <name>

puts every `@cbmc` directive after it, to the end of the file or the next
marker, in step `<name>`; directives before any marker are in the default step,
`""`. `--step <name>` runs one step's directives and no other, so a harness
whose entry points differ in cost by hours can keep the ones the corpus ties
in `cbmc.stamp` and the rest in a step of their own (`cbmc-sweep.stamp`). A run that selects a step no directive is in
fails: a lane that proves nothing must never exit 0. The marker is invisible to
`_directives`, which still lists every entry point, so dev-mcp's per-entry
steps (private tooling) see the harness whole.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # scripts/formal/ on path
import formal_arch  # noqa: E402

# THE `@` MUST ABUT THE COMMENT MARKER: `/*@cbmc`, `*@cbmc`, `//@cbmc`, with no
# space between. That is the whole rule, and it exists because a looser pattern
# matched this file's own documentation of the directives -- twice, on the first
# two runs of the gate. Once reading `<function>` from `@cbmc <function> [extra
# flags...]`, and once reading "rather than running one." as a source path from a
# sentence containing the words `@cbmc-src`.
#
# Prose therefore writes ` * @cbmc-src ...` (spaced) and a directive writes
# ` *@cbmc-src ...` (abutting). Same convention as the SAW lane's `//@spec`.
#
# The lesson is not about regexes. A parser whose input includes its own
# specification will match the specification unless something distinguishes the
# two, and "looks like a directive" is not that something.
_ANCHOR = r"^\s*(?:/\*|//|\*)"

# `@cbmc <function> [flags...]` — one CBMC invocation. `\s+` after the keyword is
# what keeps this off `@cbmc-src`.
_DIRECTIVE = re.compile(_ANCHOR + r"@cbmc\s+([A-Za-z_][A-Za-z0-9_]*)(.*?)(?:\*/)?\s*$")

# `@cbmc-src <path> [<path>...]` — the implementation TUs this harness proves
# ABOUT. Without them CBMC sees only the header declarations, models each
# function as undefined-returning-nondet, and the assertions are checked against
# a value with no relationship to the real code. That is not a failure mode you
# get told about: it looks like an ordinary counterexample.
_SOURCES = re.compile(_ANCHOR + r"@cbmc-src\s+(.+?)(?:\*/)?\s*$")

# `@cbmc-step <name>` — the directives after it belong to step <name>. Like
# `@cbmc-src`, the hyphen keeps it off `_DIRECTIVE`.
_STEP = re.compile(_ANCHOR + r"@cbmc-step\s+([A-Za-z_][A-Za-z0-9_-]*)\s*(?:\*/)?\s*$")

DEFAULT_STEP = ""


def _directives(path: Path) -> list[tuple[str, list[str]]]:
    """Every `@cbmc` directive, in file order, whatever step it is in."""
    return [(f, fl) for f, fl, _ in _directives_by_step(path)]


def _directives_by_step(path: Path) -> list[tuple[str, list[str], str]]:
    """Every `@cbmc` directive with the step a `@cbmc-step` marker above it
    named; DEFAULT_STEP before any marker."""
    out: list[tuple[str, list[str], str]] = []
    step = DEFAULT_STEP
    for line in path.read_text(encoding="utf-8").splitlines():
        if _SOURCES.search(line):
            continue
        s = _STEP.search(line)
        if s:
            step = s.group(1)
            continue
        m = _DIRECTIVE.search(line)
        if m:
            out.append((m.group(1), m.group(2).split(), step))
    return out


def _sources(path: Path) -> list[str]:
    out: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = _SOURCES.search(line)
        if m:
            out.extend(m.group(1).split())
    return out


def _parse(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="the cbmc formal lane")
    ap.add_argument("--step", default=DEFAULT_STEP,
                    help="run the directives a `@cbmc-step` marker puts in this "
                         "step; the default is the directives before any marker")
    ap.add_argument("dir", nargs="?", default="formal/cbmc")
    return ap.parse_args(argv)


def main(argv: list[str]) -> int:
    # IDRISARM1 — amd64 only. CBMC packages perfectly well for arm64, which is
    # exactly why this has to be explicit: nothing else here would stop it.
    refused = formal_arch.refuse_off_amd64("cbmc")
    if refused is not None:
        return refused

    args = _parse(argv[1:])
    d = Path(args.dir)
    cbmc = os.environ.get("CBMC_BIN", "cbmc")
    root = Path.cwd()
    incs = ["-I", str(root / "runtime/include"), "-I", str(root / "runtime/src/libds")]

    step_label = f"step `{args.step}`" if args.step != DEFAULT_STEP else "the default step"
    print(f"== cbmc gate: toolchain ({step_label}) ==")
    subprocess.run([cbmc, "--version"], check=False)

    harnesses = sorted(glob.glob(str(d / "*.c")))
    if not harnesses:
        # Belt and braces: build-unit's glob expansion already fails formal.build
        # when formal/cbmc/*.c matches nothing. This catches the same hole when the
        # recipe is run directly, because a lane that proves nothing must never exit 0.
        print(f"== cbmc gate: no harnesses found in {d} ==", file=sys.stderr)
        return 1

    rc = 0
    ran = 0
    for c in harnesses:
        src = Path(c)
        everything = _directives_by_step(src)
        if not everything:
            print(f"  FAIL: {c} — no @cbmc directive, so nothing would be "
                  f"checked and the lane would stamp green", file=sys.stderr)
            rc = 1
            continue
        ds = [(f, fl) for f, fl, step in everything if step == args.step]
        if not ds:
            # The harness has entry points, and none in this step: another
            # step's. Said, not silent, and counted below: a run in which NO
            # harness had a directive in the step fails.
            print(f"  skip: {c} — no @cbmc directive in {step_label}")
            continue

        impl = _sources(src)
        if not impl:
            print(f"  FAIL: {c} — no @cbmc-src, so CBMC would see only header "
                  f"declarations and prove nothing about the real code",
                  file=sys.stderr)
            rc = 1
            continue
        missing = [p for p in impl if not (root / p).exists()]
        if missing:
            print(f"  FAIL: {c} — @cbmc-src names files that do not exist: "
                  f"{' '.join(missing)}", file=sys.stderr)
            rc = 1
            continue

        for func, flags in ds:
            if "--unwind" in flags and "--unwinding-assertions" not in flags:
                print(f"  FAIL: {c}:{func} — --unwind without "
                      f"--unwinding-assertions cannot prove the bound is "
                      f"sufficient", file=sys.stderr)
                rc = 1
                continue

            print(f"--- cbmc {src.name}:{func} {' '.join(flags)} ---", flush=True)
            cmd = [cbmc, *incs, "--function", func, *flags, str(src), *impl]
            ran += 1
            if subprocess.run(cmd).returncode == 0:
                print(f"  PASS: {src.name}:{func}")
            else:
                print(f"  FAIL: {src.name}:{func}")
                rc = 1

    if ran == 0 and rc == 0:
        print(f"  FAIL: no harness in {d} has a @cbmc directive in {step_label}, so "
              f"nothing was checked and the lane would stamp green", file=sys.stderr)
        rc = 1
    print(f"== cbmc gate: {ran} entry point(s) run in {step_label} ==")
    print("== cbmc gate: OK ==" if rc == 0 else "== cbmc gate: FAILED ==")
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

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

THE `@cbmc-refute` DIRECTIVE is an entry point CBMC must REFUTE:

    @cbmc-refute <function> <tag> [extra flags...]

It passes only when CBMC ends in VERIFICATION FAILED (exit 10) and an
assertion whose description contains `<tag>` is among the failures. Any other
end fails the gate: a proof that passes means the check it was written for
cannot fail, and a refutation of some other assertion is not the one the
fixture was written to show. It is the TLA lane's teeth (`MUST VIOLATE:`,
check_tla.py) for C: a negative fixture fed to a harness on every run
([STYL.5.10.5]), or a probe that a bound reaches the case it claims to. A
passing refutation says the tagged assertion broke, not why; the fixture's
header says why it should.

THE MEMORY CAP. Every CBMC process runs under an address-space limit
(`RLIMIT_AS`) of `CBMC_MEM_MIB` MiB, which formal.build sets from its
`cbmc_mem_mib` param, so the value is the graph's and is in the key. A harness
whose model needs more ends past the cap with a non-zero status, and the entry
point fails: the cap excludes every proof that needs more address space than
it allows, and never turns one into a pass. It exists so one harness cannot
take a shared host down: a nondeterministic store size can make CBMC model the
store byte by byte, and use all the memory it finds.

THE CAP SHOWS IT FIRES ON EVERY RUN, before any harness ([STYL.5.10.5]). A
probe under the same cap maps more address space than the cap allows, touching
none of it, and must be refused. A second probe maps a quarter of it and must
succeed. Each also reports the limit it runs under, so a probe refused for
another reason (strict overcommit, say) is not mistaken for the cap. A lane
whose cap is not in force, or refuses what it should admit, fails before it
proves anything.

THE ASSUMPTION THE CAP RESTS ON. A plain `@cbmc` entry point passes on exit 0
alone, so the cap is sound only if CBMC never ends 0 when an allocation the cap
refuses fails, its own or the SAT backend's: an out-of-memory solver that
answered UNSAT and exited 0 would be a false PASS. CBMC turns an allocation
failure into `std::bad_alloc`, the MiniSat backend reports its own as one
("SAT checker ran out of memory"), and the driver catches it, prints "Out of
memory" and exits CPROVER_EXIT_INTERNAL_OUT_OF_MEMORY, 6 (`util/exit_codes.h`,
`util/parse_options.cpp`). That is the CBMC this lane runs, read from its
sources and its output. No run here drives CBMC toward the cap on purpose: a
harness whose proof needs a sizeable fraction of it is a harness to fix, not a
case to exercise.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import resource
import subprocess
import sys
from collections.abc import Callable
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

# `@cbmc-refute <function> <tag> [flags...]` — an entry point CBMC must refute,
# on an assertion whose description contains <tag>. The hyphen keeps it off
# `_DIRECTIVE`, as `@cbmc-src`'s does.
_REFUTE = re.compile(_ANCHOR + r"@cbmc-refute\s+([A-Za-z_][A-Za-z0-9_]*)\s+(\S+)(.*?)(?:\*/)?\s*$")

# CBMC's exit status for VERIFICATION FAILED. Every other non-zero status is an
# error before or during the check (a parse failure, a missing function), which
# is no refutation at all.
CBMC_REFUTED = 10

DEFAULT_STEP = ""

# The memory cap, in MiB: the environment's, else this. formal.build passes it.
MEM_ENV = "CBMC_MEM_MIB"
DEFAULT_MEM_MIB = 3072
_MIB = 1 << 20

# The probe: report the address-space limit it runs under, then map `size`
# bytes of anonymous memory and touch none of them, so a cap that is not in
# force costs the host no memory. Exit 3 when the mapping is refused. Any other
# status is no answer: an interpreter that did not start is not a refusal.
PROBE_REFUSED = 3
_PROBE = (
    "import mmap, resource, sys\n"
    "print(resource.getrlimit(resource.RLIMIT_AS)[0], flush=True)\n"
    "try:\n"
    "    m = mmap.mmap(-1, int(sys.argv[1]))\n"
    "except OSError:\n"
    "    sys.exit(3)\n"
    "m.close()\n"
)


def mem_cap_bytes() -> int | None:
    """The cap in bytes, from `CBMC_MEM_MIB`; None when it is not a positive
    whole number of MiB."""
    raw = os.environ.get(MEM_ENV, str(DEFAULT_MEM_MIB))
    if not raw.isdigit() or int(raw) <= 0:
        return None
    return int(raw) * _MIB


def capped(limit: int) -> Callable[[], None]:
    """A `preexec_fn` that puts the child under an address-space limit of
    `limit` bytes, soft and hard, before it runs."""
    def apply() -> None:
        resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
    return apply


def probe(limit: int, size: int) -> tuple[int, str]:
    """A child under the cap that maps `size` bytes: its status, and the limit
    it reported."""
    proc = subprocess.run([sys.executable, "-c", _PROBE, str(size)],
                          preexec_fn=capped(limit), capture_output=True, text=True)
    seen = proc.stdout.splitlines()[0] if proc.stdout else ""
    return proc.returncode, seen


def cap_fires(limit: int) -> str | None:
    """None when the cap is in force: a child under it reports it, is refused a
    mapping past it, and is granted one within it. Otherwise, why not."""
    mib = limit // _MIB
    rc, seen = probe(limit, limit + 64 * _MIB)
    if seen != str(limit):
        return (f"a probe under the {mib} MiB cap reported a limit of "
                f"`{seen or 'nothing'}`: the cap is not in force")
    if rc != PROBE_REFUSED:
        return (f"a probe mapped {mib + 64} MiB under the {mib} MiB cap and "
                f"ended {rc}, not refused: the cap does not bound it")
    rc, _ = probe(limit, limit // 4)
    if rc != 0:
        return (f"a probe mapping {mib // 4} MiB under the {mib} MiB cap ended "
                f"{rc}: the cap refuses what it should admit")
    return None


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


def _refutations_by_step(path: Path) -> list[tuple[str, str, list[str], str]]:
    """Every `@cbmc-refute` directive as (function, tag, flags, step), in file
    order, the step a `@cbmc-step` marker above it named."""
    out: list[tuple[str, str, list[str], str]] = []
    step = DEFAULT_STEP
    for line in path.read_text(encoding="utf-8").splitlines():
        s = _STEP.search(line)
        if s:
            step = s.group(1)
            continue
        m = _REFUTE.search(line)
        if m:
            out.append((m.group(1), m.group(2), m.group(3).split(), step))
    return out


def refuted_on(output: str, tag: str) -> bool:
    """Whether CBMC's report names a failed assertion whose description holds
    `tag`. CBMC prints one `[<property>] <description>: FAILURE` line per
    failed property."""
    return any(tag in line and line.rstrip().endswith(": FAILURE")
               for line in output.splitlines())


def _sources_in(text: str) -> list[str]:
    """Every path a `@cbmc-src` line of `text` names, in order."""
    out: list[str] = []
    for line in text.splitlines():
        m = _SOURCES.search(line)
        if m:
            out.extend(m.group(1).split())
    return out


def _sources(path: Path) -> list[str]:
    return _sources_in(path.read_text(encoding="utf-8"))


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
    limit = mem_cap_bytes()
    if limit is None:
        print(f"== cbmc gate: {MEM_ENV}=`{os.environ.get(MEM_ENV)}` is not a "
              f"positive whole number of MiB, so no CBMC runs uncapped ==",
              file=sys.stderr)
        return 1
    print(f"== cbmc gate: each CBMC process capped at {limit // _MIB} MiB of "
          f"address space ({MEM_ENV}) ==")
    unfired = cap_fires(limit)
    if unfired is not None:
        print(f"  FAIL: the memory cap's probe: {unfired}", file=sys.stderr)
        print("== cbmc gate: FAILED ==")
        return 1
    print(f"  ok: a probe was refused {limit // _MIB + 64} MiB and granted "
          f"{limit // _MIB // 4} MiB under the cap")
    run_capped = capped(limit)

    print(f"== cbmc gate: toolchain ({step_label}) ==")
    subprocess.run([cbmc, "--version"], check=False, preexec_fn=run_capped)

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
        rs = [(f, tag, fl) for f, tag, fl, step in _refutations_by_step(src)
              if step == args.step]
        if not ds and not rs:
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
            status = subprocess.run(cmd, preexec_fn=run_capped).returncode
            if status == 0:
                print(f"  PASS: {src.name}:{func}")
            elif status == CBMC_REFUTED:
                print(f"  FAIL: {src.name}:{func}")
                rc = 1
            else:
                print(f"  FAIL: {src.name}:{func} — cbmc exited {status}: an "
                      f"error, or a model past the {limit // _MIB} MiB cap")
                rc = 1

        for func, tag, flags in rs:
            if "--unwind" in flags and "--unwinding-assertions" not in flags:
                print(f"  FAIL: {c}:{func} — --unwind without "
                      f"--unwinding-assertions, so a refutation could come from "
                      f"a truncated loop", file=sys.stderr)
                rc = 1
                continue

            print(f"--- cbmc {src.name}:{func} (must refute `{tag}`) "
                  f"{' '.join(flags)} ---", flush=True)
            cmd = [cbmc, *incs, "--function", func, *flags, str(src), *impl]
            ran += 1
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  preexec_fn=run_capped)
            sys.stdout.write(proc.stdout)
            sys.stderr.write(proc.stderr)
            if proc.returncode == CBMC_REFUTED and refuted_on(proc.stdout, tag):
                print(f"  REFUTED, as required: {src.name}:{func} on `{tag}`")
            elif proc.returncode == 0:
                print(f"  FAIL: {src.name}:{func} — proved, where it must be "
                      f"refuted: the check it was written against cannot fail")
                rc = 1
            elif proc.returncode == CBMC_REFUTED:
                print(f"  FAIL: {src.name}:{func} — refuted, but on no assertion "
                      f"tagged `{tag}`")
                rc = 1
            else:
                print(f"  FAIL: {src.name}:{func} — cbmc exited "
                      f"{proc.returncode}, which is an error, or a model past "
                      f"the {limit // _MIB} MiB cap, and no refutation")
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

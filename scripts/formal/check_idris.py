#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""scripts/formal/check_idris.py [idris-dir] — the `idris` formal lane: typecheck the DS
metatheory modules (formal/idris/**/*.idr) with Idris 2 in the ds-check image.

The thin recipe behind formal.build's `idris.stamp` step. Idris 2 is a
dependently-typed language with a TOTALITY checker, which is the property this
lane exists for: Alloy does structure, TLA+ behaviour, K dynamic semantics, SAW
bit-exact C equivalence, CBMC bounded C properties, and none of them can say
"this function terminates on every input" or "this proof has no holes".

WHAT COUNTS AS PASSING, and it is stricter than `idris2 --check` alone:

  1. Every module typechecks.
  2. `%default total` is in force and NO `partial` escape is present, so a
     non-terminating definition is a compile error rather than a warning. A
     metatheory module that typechecks while admitting a diverging proof has
     established nothing -- `believe_me` and friends must be declared, not
     discovered.
  3. Any `postulate` / `believe_me` / `assert_total` / `idris_crash` is
     REPORTED, with its file and line. Not an error: a hole is legitimate when
     it is declared, and [STYL.5.3.6.2]'s `verdict: "assumed"` is where a clause
     records that its lemma rests on one. What is not legitimate is a hole
     nobody can see -- so the lane prints them, and the count is the number a
     reader should expect to find declared in the corpus.
  4. NO `?name` IS LEFT IN CODE. A named hole is how a proof is developed in
     Idris, so the language is built to elaborate a definition that contains
     one; `thm = ?todo` then has a name, a type, a clause tag and no proof. The
     lane does not leave it to the checker to object. A hole is not one of
     (3)'s declared assumptions -- those state what they take for granted --
     and it FAILS the lane.
  5. THERE IS A CORPUS, A PACKAGE AND AN IDRIS TEST PAIR. Each was allowed to be
     absent while the lane was being stood up, and each absence returned 0. The
     lane has modules, `ds-formal.ipkg` and `tests/` now, so a run that finds
     none of one was pointed at the wrong directory or at a tree that lost
     them, and it has proved nothing.

REFUSES rather than skips when `idris2` is absent, the same way check_k.py does
for `kompile`: a lane that returns 0 on a machine where it proved nothing is the
"check that cannot fail" TESTING.md rules out.

AND REFUSES ON ANYTHING BUT amd64 (IDRISARM1). That is
a separate refusal from the one above and fires first — see `formal_arch.py`.
This lane is the one the refusal is named for because it is the one that would
otherwise PASS on arm: Idris 2 runs there perfectly well.
"""
from __future__ import annotations

import glob
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # scripts/formal/ on path
import formal_arch  # noqa: E402

# Declared-hole markers. `assert_total` silences the totality checker for one
# expression; `assert_smaller` tells it an argument is structurally smaller
# without proof, which is the same silencing aimed at one recursive call;
# `believe_me` and `idris_crash` bypass the type system outright; a `postulate`
# asserts a type with no proof term at all; a `covering` annotation lowers one
# definition from total to covering-only, so it may still diverge. Each is a
# legitimate tool and each ends a chain of reasoning, so each is surfaced.
#
# `assert_smaller` and `covering` are on this list because without them a module
# could carry either and the lane would report zero holes.
HOLE_RE = re.compile(
    r"\b(postulate|believe_me|assert_total|assert_smaller|idris_crash|covering)\b")

# `%default partial` (or a bare `partial` annotation) turns the totality checker
# off for the rest of a module; `%default covering` lowers the floor to coverage
# alone, under which a diverging definition typechecks. Either is the one thing
# this lane cannot allow to pass quietly: it does not add a hole, it removes the
# floor.
PARTIAL_RE = re.compile(
    r"^\s*%default\s+(partial|covering)\b|^\s*partial\s*$", re.M)

# A named hole: `?` directly before an identifier, and not directly after one.
# The second half keeps this off an operator section or a `?` that ends a word
# in a string; the first keeps it off the character literal '?'.
UNFILLED_RE = re.compile(r"(?<![A-Za-z0-9_'])\?[A-Za-z_][A-Za-z0-9_']*")


def _refuse_without_idris2() -> int | None:
    """REFUSE, don't skip, when Idris 2 is absent.

    NOT AN ARCHITECTURE STORY, and that distinction survived IDRISARM1 rather
    than being replaced by it. Idris 2 is built from source in ds-check and is
    arch-neutral, so an absent `idris2` means the image predates the lane rather
    than that the platform cannot carry it -- which is why the arch refusal is a
    SEPARATE check that runs before this one. On arm both would fire and only
    one of them names the actual reason the lane is not running.

    Either way the answer is the same: say so, non-zero, rather than hand back a
    green from a machine that typechecked nothing.
    """
    if shutil.which("idris2") is not None:
        return None
    print(
        "== idris gate: REFUSED — no `idris2` on this machine ==\n"
        f"   arch: {platform.machine()}\n"
        "   ds-check builds Idris 2 from source (IDRIS2_VERSION in the\n"
        "   image's Dockerfile, private) and puts it on PATH at\n"
        "   /opt/idris2/bin. An image without it predates that layer.\n"
        "   Rebuild ds-check, or run this lane on a host whose image has it.\n"
        "   Not skipped: a formal lane that passes without a checker has\n"
        "   proved nothing and would say so in green.",
        file=sys.stderr,
    )
    return 2


def _scan(path: Path) -> tuple[list[str], list[str]]:
    """(declared holes, totality escapes) in one module, as reportable lines."""
    return _scan_text(str(path), path.read_text(encoding="utf-8"))


def _scan_text(path: str, text: str) -> tuple[list[str], list[str]]:
    """`_scan` on text already read, so `_selftest` can hand it a module."""
    holes: list[str] = []
    escapes: list[str] = []
    code_lines: list[str] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        # Strip a trailing line comment before matching so prose about
        # `believe_me` in a header does not read as a use of it. A `|||`
        # docstring line is prose too, and the headers in this lane are long
        # ones -- `covering` and `partial` occur in them as English.
        if line.lstrip().startswith("|||"):
            code_lines.append("")
            continue
        code = line.split("--", 1)[0]
        code_lines.append(code)
        m = HOLE_RE.search(code)
        if m:
            holes.append(f"{path}:{lineno}: {m.group(1)}")
        for u in UNFILLED_RE.findall(code):
            escapes.append(f"{path}:{lineno}: `{u}` is an unfilled hole — the "
                           f"definition it stands in has no proof")
    # Both floor checks read CODE, not the file: a `%default total` quoted in a
    # comment satisfied the substring test this used to be, and a `%default
    # partial` in a comment would have failed it.
    code_text = "\n".join(code_lines)
    if PARTIAL_RE.search(code_text):
        escapes.append(f"{path}: `%default partial` / `%default covering` / bare "
                       f"`partial` disables the totality checker for this module")
    if "%default total" not in code_text:
        escapes.append(f"{path}: no `%default total` — totality is not in force, "
                       f"so a diverging proof typechecks")
    return holes, escapes


_SELFTEST_MODULE = """module M
%default total
||| Prose that says ?prose and believe_me, and is not code.
thm : (n : Nat) -> n = n
thm n = ?todo   -- a comment that says ?comment
ok : Char
ok = '?'
"""


def _selftest() -> list[str]:
    """`_scan_text` against a module whose answer is known. Returns what it got
    wrong; empty means an unfilled hole in code is seen, and one in prose, in a
    comment or in a character literal is not."""
    holes, escapes = _scan_text("M.idr", _SELFTEST_MODULE)
    wrong: list[str] = []
    if holes:
        wrong.append(f"prose read as a declared hole: {holes}")
    if len(escapes) != 1 or "M.idr:5: `?todo`" not in escapes[0]:
        wrong.append(f"wanted exactly the hole at M.idr:5, read {escapes}")
    _, escapes = _scan_text("M.idr", _SELFTEST_MODULE.replace("?todo", "Refl"))
    if escapes:
        wrong.append(f"a module with no hole was reported: {escapes}")
    return wrong


def main(argv: list[str]) -> int:
    # IDRISARM1 — amd64 only, and this lane is the one the refusal is named for.
    # It is also the one with the least excuse to be arm-shy on its own: Idris 2
    # is built from source in ds-check and runs perfectly well on arm64, so
    # without this the idris lane would PASS on the excluded architecture. The
    # tool check below cannot help -- `idris2` is present there.
    refusal = formal_arch.refuse_off_amd64("idris")
    if refusal is not None:
        return refusal

    refusal = _refuse_without_idris2()
    if refusal is not None:
        return refusal

    wrong = _selftest()
    if wrong:
        print("== idris gate: the hole scan failed its own fixture, so its "
              "silence on a module would mean nothing ==", file=sys.stderr)
        for w in wrong:
            print(f"   {w}", file=sys.stderr)
        return 2

    root = Path(argv[1] if len(argv) > 1 else "formal/idris")
    modules = sorted(Path(p) for p in glob.glob(str(root / "**" / "*.idr"),
                                                recursive=True)
                     if "build" not in Path(p).relative_to(root).parts[:-1])
    if not modules:
        # AN ERROR, since the first module landed. While the lane was registered
        # ahead of its corpus this returned 0 and said so, which was the honest
        # state then; with a corpus in the tree, "no modules" means the path is
        # wrong or the corpus is gone, and 0 would stamp that green.
        print(f"== idris gate: no modules under {root} — nothing was typechecked "
              f"-> FAIL ==", file=sys.stderr)
        return 1

    print(f"== idris gate: {len(modules)} module(s) under {root} ==")
    failed: list[str] = []
    all_holes: list[str] = []
    all_escapes: list[str] = []

    for mod in modules:
        holes, escapes = _scan(mod)
        all_holes += holes
        all_escapes += escapes
        # `--check` typechecks without producing an executable.
        #
        # RUN FROM THE IDRIS ROOT, not the repo root, and the path is relative to
        # it. Idris derives a module's name from its path — invoked from the repo
        # root, `formal/idris/ConsumptionLoop.idr` has to declare `module
        # formal.idris.ConsumptionLoop`, and Idris rejects the lowercase path
        # components. With cwd at `formal/idris`, `ConsumptionLoop.idr` is
        # `module ConsumptionLoop` and a nested `Runtime/Pump.idr` is `module
        # Runtime.Pump`, which is the ordinary convention and lets imports
        # resolve between modules without a package file.
        proc = subprocess.run(
            ["idris2", "--check", str(mod.relative_to(root))],
            cwd=str(root), capture_output=True, text=True,
            env={**os.environ, "IDRIS2_PREFIX": os.environ.get(
                "IDRIS2_PREFIX", "/opt/idris2")},
        )
        status = "ok" if proc.returncode == 0 else "FAILED"
        print(f"   {mod}  ->  {status}")
        if proc.returncode != 0:
            failed.append(str(mod))
            sys.stdout.write(proc.stdout)
            sys.stderr.write(proc.stderr)

    if all_holes:
        print(f"\n== declared holes ({len(all_holes)}) — each ends a chain of "
              f"reasoning and belongs behind a `verdict: \"assumed\"` ==")
        for h in all_holes:
            print(f"   {h}")

    if all_escapes:
        print(f"\n== TOTALITY ESCAPES AND UNFILLED HOLES ({len(all_escapes)}) — "
              f"these are failures ==", file=sys.stderr)
        for e in all_escapes:
            print(f"   {e}", file=sys.stderr)

    if failed or all_escapes:
        print(f"\nidris gate: {len(failed)} module(s) failed to typecheck, "
              f"{len(all_escapes)} totality escape(s) or unfilled hole(s) -> FAIL",
              file=sys.stderr)
        return 1

    print(f"\nidris gate: {len(modules)} module(s) typecheck under `%default total`, "
          f"{len(all_holes)} declared hole(s) -> ok")

    return _build_and_run(root)


def _build_and_run(root: Path) -> int:
    """Build the package and run its worked examples.

    WHY THIS PHASE EXISTS. `--check` typechecks and stops; it never generates
    code, so a decoder that typechecks has still never DECODED anything.
    Building catches what elaboration defers, and it gives the worked examples
    somewhere to live -- `Protobuf/Wire.idr` records why they cannot be
    compile-time `Refl` proofs and why rewriting the arithmetic so they could be
    would make the decoder worse.

    NO PACKAGE IS A FAILURE, since the package landed. The worked examples and
    the Idris tests run only through it, so a tree without one skips both and
    would report the typecheck alone as the lane.

    A BUILT PACKAGE WITH NO EXECUTABLE IS ONE TOO. That means the ipkg declares
    no `main`, so the examples silently never ran -- the shape of a green that
    proves nothing, which is what every gate in this repo is written against.
    """
    pkgs = sorted(root.glob("*.ipkg"))
    if not pkgs:
        print(f"\nidris gate: no .ipkg under {root} -- the worked examples and "
              f"the Idris tests have nothing to run through -> FAIL",
              file=sys.stderr)
        return 1
    if len(pkgs) > 1:
        print(f"\nidris gate: {len(pkgs)} .ipkg files under {root}; expected one",
              file=sys.stderr)
        return 1

    pkg = pkgs[0]
    print(f"\n== building {pkg.name} ==")
    build = subprocess.run(["idris2", "--build", pkg.name],
                           cwd=str(root), capture_output=True, text=True)
    sys.stdout.write(build.stdout)
    sys.stderr.write(build.stderr)
    if build.returncode != 0:
        print(f"idris gate: {pkg.name} failed to BUILD though every module "
              f"typechecks -- codegen catches what elaboration defers -> FAIL",
              file=sys.stderr)
        return 1

    # Located by glob rather than by hard-coding the ipkg's `executable` name,
    # so renaming it there cannot silently skip the run.
    execdir = root / "build" / "exec"
    runnable = [p for p in sorted(execdir.glob("*"))
                if p.is_file() and os.access(p, os.X_OK)] if execdir.is_dir() else []
    if not runnable:
        print("idris gate: built, but no executable under build/exec -- the "
              "package declares no `main`, so the worked examples never ran "
              "-> FAIL", file=sys.stderr)
        return 1

    # RESOLVED, because the run also sets `cwd`. `root` arrives relative
    # ("formal/idris"), so a relative executable path was being resolved against
    # the new working directory and looked for
    # formal/idris/formal/idris/build/exec/... -- a FileNotFoundError reported
    # against a path that never existed anywhere.
    print(f"\n== running {runnable[0].name} ==")
    run = subprocess.run([str(runnable[0].resolve())], cwd=str(root),
                         capture_output=True, text=True)
    sys.stdout.write(run.stdout)
    sys.stderr.write(run.stderr)
    if run.returncode != 0:
        print(f"idris gate: worked examples FAILED (exit {run.returncode})",
              file=sys.stderr)
        return 1
    rc = _idris_tests(root, runnable[0])
    if rc != 0:
        return rc
    return _idris_refusals(root, runnable[0])


def _idris_tests(root: Path, exe: Path) -> int:
    """Run the Idris model (`--fixture`, Fixture.idr) on the committed
    smoke fixture and diff its output against the committed expectation.

    WHY. The worked examples exercise the model modules; the Idris model path --
    parsing a lowered fixture, loading the network, running inputs and pumps,
    printing the trace -- runs only under `--fixture`, so without this a broken
    runner would ship green. The pair under formal/idris/tests/ is one real
    fixture (LGRA.5.9.6) lowered by the fixture lowering (private tooling) and
    the output the model produced for it; a change in either is a change to
    review, not to absorb. ABSENT PAIR IS NOT A PASS: the runner exists, so its
    smoke must.

    EVERY PAIR, not only `smoke`: each `<name>.lowered` under the directory is
    run and diffed against its `<name>.expected`. A `.lowered` with no
    `.expected` fails rather than being skipped.
    """
    sample = root / "tests" / "smoke.lowered"
    expected = root / "tests" / "smoke.expected"
    if not sample.is_file() or not expected.is_file():
        print("idris gate: Idris test pair missing under formal/idris/tests/ "
              "-- the runner exists, so its smoke must -> FAIL", file=sys.stderr)
        return 1
    for sample in sorted((root / "tests").glob("*.lowered")):
        expected = sample.with_suffix(".expected")
        if not expected.is_file():
            print(f"idris gate: {sample.name} has no {expected.name} -> FAIL", file=sys.stderr)
            return 1
        print(f"\n== Idris test: {sample.name} ==")
        run = subprocess.run([str(exe.resolve()), "--fixture", str(sample.resolve())],
                             cwd=str(root), capture_output=True, text=True)
        if run.returncode != 0:
            sys.stdout.write(run.stdout)
            sys.stderr.write(run.stderr)
            print(f"idris gate: Idris test {sample.name} FAILED (exit {run.returncode})", file=sys.stderr)
            return 1
        want = expected.read_text(encoding="utf-8").splitlines()
        got = run.stdout.splitlines()
        if got != want:
            import difflib
            sys.stdout.write("\n".join(difflib.unified_diff(want, got, expected.name, "fixture output", lineterm="")) + "\n")
            print(f"idris gate: Idris test output differs from {expected.name} -> FAIL", file=sys.stderr)
            return 1
        print(f"   {len(got)} line(s) as expected")
    return 0


def _idris_refusals(root: Path, exe: Path) -> int:
    """Run the runner on each committed input it must REFUSE
    (formal/idris/tests/refused/*.lowered) and hold it to exit 2 and exactly
    the refusal line in the paired `.expected`.

    WHY. Fixture.idr refuses an input whose records cannot mean anything the
    model runs -- a clock read on a shape it does not re-time, a call site
    naming a response kind no `answer` record declares -- and a refusal that
    stopped firing would let such an input run to a wrong answer the engine
    comparison reports as libds's disagreement. The pairs here are the
    runner's negative fixtures ([STYL.5.10.5]): each
    is fed to it on every run and must be refused as written. AT LEAST ONE
    PAIR, or FAIL: a runner with refusals and no fixture of one is a check
    nothing has seen fail. A `.lowered` with no `.expected` fails rather than
    being skipped.
    """
    pairs = sorted((root / "tests" / "refused").glob("*.lowered"))
    if not pairs:
        print("idris gate: no refused pair under formal/idris/tests/refused/ -- the runner's "
              "refusals have no negative fixture -> FAIL", file=sys.stderr)
        return 1
    for sample in pairs:
        expected = sample.with_suffix(".expected")
        if not expected.is_file():
            print(f"idris gate: refused/{sample.name} has no {expected.name} -> FAIL", file=sys.stderr)
            return 1
        print(f"\n== fixture refusal: {sample.name} ==")
        run = subprocess.run([str(exe.resolve()), "--fixture", str(sample.resolve())],
                             cwd=str(root), capture_output=True, text=True)
        if run.returncode != 2:
            sys.stdout.write(run.stdout)
            sys.stderr.write(run.stderr)
            print(f"idris gate: refused/{sample.name} exited {run.returncode}, not the refusal's 2 -> FAIL",
                  file=sys.stderr)
            return 1
        want = expected.read_text(encoding="utf-8").splitlines()
        got = run.stdout.splitlines()
        if got != want:
            import difflib
            sys.stdout.write("\n".join(difflib.unified_diff(want, got, expected.name, "fixture output", lineterm="")) + "\n")
            print(f"idris gate: refused/{sample.name} was refused with other words than {expected.name} -> FAIL",
                  file=sys.stderr)
            return 1
        print("   refused as expected")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
